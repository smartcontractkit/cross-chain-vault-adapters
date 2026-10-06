// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IAny2EVMMessageReceiver } from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import { IRouterClient } from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import { Client } from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { IOFT, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

import { IStargate } from "./stargate/IStargate.sol";
import { AdapterRoles } from "./AdapterRoles.sol";

/**
 * @title MultiChannelBridgeAdapter
 * @notice Minimal base contract that can RECEIVE and SEND tokens over both Chainlink CCIP and
 *         LayerZero V2 OFT. On receipt from either channel it normalises the delivery into a single
 *         {Inbound} struct (channel, source, sender, tokens, arbitrary data) and hands it to the
 *         {_handleReceive} hook. Applications inherit this base and implement {_handleReceive} to
 *         take the delivered tokens and do whatever they want (e.g. deposit into a vault and bridge
 *         the result onward). It also exposes internal {_sendViaCcip} / {_sendViaOft} helpers so
 *         inheritors can emit tokens back out over either channel.
 *
 * @dev Scope: TRANSPORT ONLY. This base intentionally contains no application logic, no token
 *      accounting beyond what the channels require, and no failure-recovery state machine — those
 *      belong to the inheriting application. Design notes:
 *
 *      - Authentication: inbound CCIP is gated by the configured router (`onlyCcipRouter`) plus a
 *        source-chain-selector allowlist (the sender is NOT authenticated — any sender on an allowed
 *        source chain is accepted); inbound LayerZero compose is gated by the configured endpoint
 *        (`onlyLzEndpoint`) plus a `(srcEid, oft)` allowlist enforced at the `lzCompose` boundary.
 *        Spoofed callers revert. The tokens have already been credited to this contract by the channel
 *        before the hook runs.
 *      - Failure handling: the inbound hook runs inside an isolated `try/catch` self-call. If the
 *        inheritor's `_handleReceive` reverts, the base CATCHES it and captures the delivery as a
 *        recoverable failed message — the channel still sees success and the tokens stay with this
 *        contract, matching the committed amounts; it never bricks the transfer. Recovery is then via
 *        {refundToSource} / {retryFailedMessage} / {refundLocal}; inheritors do NOT add their own try/catch.
 *      - Fees: both channels are paid in native gas from this contract's balance (fund via
 *        `receive()`); CCIP additionally supports an ERC-20 fee token. Quote helpers are provided.
 *      - Token hygiene: {SafeERC20.forceApprove} is used for every approval (USDT-class tokens
 *        reject non-zero->non-zero `approve` and omit boolean returns). No decimals are assumed.
 *
 *      Non-EVM destinations: CCIP `receiver` is `abi.encode(address)` (EVM destinations); the OFT
 *      `to` is a raw `bytes32` peer (EVM or non-EVM). Inbound CCIP/OFT senders are normalised to
 *      `bytes32` (32-byte wire encoding).
 */
abstract contract MultiChannelBridgeAdapter is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IAny2EVMMessageReceiver,
    IOAppComposer,
    ITypeAndVersion
{
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    /// @dev See {AdapterRoles}; exposed for off-chain scripts and factories.
    bytes32 public constant FEE_SETTER_ROLE = AdapterRoles.FEE_SETTER;
    bytes32 public constant FEE_COLLECTOR_ROLE = AdapterRoles.FEE_COLLECTOR;

    /// @dev Destination `lzReceive` gas granted when bouncing a LayerZero token transfer back to source
    ///      (a plain token credit, no compose) in {refundToSource}.
    uint128 internal constant REFUND_LZ_RECEIVE_GAS = 200_000;

    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Which interop channel a delivery arrived on / will leave on.
    enum Channel {
        CCIP,
        LayerZero
    }

    /// @notice Normalised inbound delivery handed to {_handleReceive}.
    /// @param channel The channel the delivery arrived on.
    /// @param srcId   Source identifier: CCIP `sourceChainSelector` (uint64) or LayerZero `srcEid`
    ///                (uint32, widened) — interpret by `channel`.
    /// @param sender  Normalised source sender: CCIP `sender` word, or the OFT compose `composeFrom`.
    /// @param guid    Channel-unique id: CCIP `messageId` or LayerZero `guid`.
    /// @param tokens  Tokens (local addresses + amounts) credited to this contract by the channel.
    ///                LayerZero composes always carry exactly one; CCIP may carry one or more.
    /// @param data    Arbitrary application payload (CCIP `message.data` / the OFT compose payload).
    /// @param lzOft   LayerZero compose `_from` OFT app address; zero for CCIP deliveries. Used for
    ///                inbound auth and for bounce-back routing on {refundToSource}.
    struct Inbound {
        Channel channel;
        uint64 srcId;
        bytes32 sender;
        bytes32 guid;
        Client.EVMTokenAmount[] tokens;
        bytes data;
        address lzOft;
    }

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Chainlink CCIP router authorised to deliver inbound messages and execute sends.
    ///         Set once in {__MultiChannelBridgeAdapter_init} (storage, not immutable, for clones).
    address public s_ccipRouter;
    /// @notice LayerZero EndpointV2 authorised to deliver inbound compose messages.
    address public s_lzEndpoint;

    /// @notice Inbound CCIP allowlist: sourceChainSelector => allowed. Any sender on an enabled chain is
    ///         accepted (CCIP delivers via the router; `message.sender` is recorded on the {Inbound} for
    ///         refund routing, not authenticated here).
    mapping(uint64 srcSelector => bool allowed) public s_ccipSourceAllowed;
    /// @notice Inbound LayerZero allowlist: srcEid => OFT app => allowed.
    mapping(uint32 srcEid => mapping(address oft => bool allowed)) public s_lzOftAllowed;
    /// @notice Outbound CCIP destination selector allowlist.
    mapping(uint64 dstSelector => bool allowed) public s_ccipDestAllowed;
    /// @notice Outbound LayerZero destination eid allowlist.
    mapping(uint32 dstEid => bool allowed) public s_lzDestAllowed;
    /// @notice Outbound Stargate destination eid allowlist. Distinct from {s_lzDestAllowed}: Stargate is
    ///         LayerZero-based and shares the EID space, but a Stargate send routes through a pooled
    ///         liquidity contract (not a plain OFT), so the operator gates the two rails separately.
    mapping(uint32 dstEid => bool allowed) public s_stargateDestAllowed;

    /// @notice Per-CCIP-chain Solana-VM (SVM) marker + execution params. When `enabled`, that chain
    ///         selector is a Solana lane: CCIP messages are encoded for SVM (empty `receiver`,
    ///         `SVMExtraArgsV1` carrying the 32-byte `tokenReceiver`) instead of EVM `abi.encode(address)`.
    ///         Keyed by selector, so it governs BOTH outbound sends and the inbound refund bounce.
    /// @param enabled                  Whether this CCIP selector is a Solana (SVM) chain.
    /// @param computeUnits             SVM compute-unit budget (0 for a pure token transfer / no receiver).
    /// @param allowOutOfOrderExecution Out-of-order execution flag. ALWAYS `true` — SVM lanes require it
    ///                                 (the FeeQuoter rejects `false`), so it is forced on and not operator-settable.
    struct CcipSvmConfig {
        bool enabled;
        uint32 computeUnits;
        bool allowOutOfOrderExecution;
    }
    /// @notice SVM config per CCIP chain selector (see {CcipSvmConfig}).
    mapping(uint64 selector => CcipSvmConfig config) public s_ccipSvm;

    /// @notice Default error-management state: a FIXED-SIZE hash commitment (`keccak256(abi.encode(
    ///         inbound))`) over each captured failed inbound, keyed by channel-unique `guid` (CCIP
    ///         messageId / LayerZero guid). Non-zero means the message is captured and unresolved;
    ///         cleared on successful retry or recovery. Storing only the commitment bounds the
    ///         failure-capture cost regardless of payload size; the full encoding is emitted in
    ///         {MessageFailed} and recovery callers supply the reconstructed {Inbound}, verified against
    ///         this hash. Tokens the channel delivered remain held by this contract, matching the
    ///         committed amounts.
    mapping(bytes32 guid => bytes32 inboundHash) internal s_failedInboundHash;

    /// @notice Marks a failed message finalized as REFUNDED — its tokens bounced back to source via
    ///         {refundToSource} or sent locally via {refundLocal}. Terminal: a refunded message can no
    ///         longer be retried or refunded.
    mapping(bytes32 guid => bool refunded) internal s_refunded;

    /*//////////////////////////////////////////////////////////////
                              EVENTS / ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tokens were received inbound over `channel` and credited to this contract, before
    ///         {_handleReceive} runs (`guid` is the channel-unique id; `tokenCount` the number credited).
    event TokensReceived(Channel indexed channel, uint64 indexed srcId, bytes32 indexed sender, bytes32 guid, uint256 tokenCount);
    /// @notice One token (`amount`) was sent outbound over CCIP to `dstSelector` for `fee` (native units).
    event SentViaCcip(bytes32 indexed messageId, uint64 indexed dstSelector, address token, uint256 amount, uint256 fee);
    /// @notice One token (`amount`) was sent outbound over a LayerZero OFT to `dstEid` for `fee`.
    event SentViaOft(bytes32 indexed guid, uint32 indexed dstEid, address token, uint256 amount, uint256 fee);
    /// @notice One token (`amount`) was sent outbound over a Stargate pool to `dstEid` for `fee`.
    event SentViaStargate(bytes32 indexed guid, uint32 indexed dstEid, address token, uint256 amount, uint256 fee);
    /// @notice The inbound CCIP `sourceChainSelector` allowlist entry was set to `allowed`.
    event CcipSourceSet(uint64 indexed srcSelector, bool allowed);
    /// @notice The inbound LayerZero `(srcEid, oft)` allowlist entry was set to `allowed`.
    event LzOftSet(uint32 indexed srcEid, address indexed oft, bool allowed);
    /// @notice The outbound CCIP destination `dstSelector` allowlist entry was set to `allowed`.
    event CcipDestSet(uint64 indexed dstSelector, bool allowed);
    /// @notice The outbound LayerZero destination `dstEid` allowlist entry was set to `allowed`.
    event LzDestSet(uint32 indexed dstEid, bool allowed);
    /// @notice The outbound Stargate destination `dstEid` allowlist entry was set to `allowed`.
    event StargateDestSet(uint32 indexed dstEid, bool allowed);
    /// @notice The CCIP Solana-VM (SVM) lane config for `selector` was updated.
    event CcipSvmConfigSet(uint64 indexed selector, bool enabled, uint32 computeUnits, bool allowOutOfOrderExecution);
    /// @notice Surplus native fee funding (the operator's own gas float) was recovered to `to`.
    event NativeRecovered(address indexed to, uint256 amount);
    /// @notice Inbound message processed successfully by {_handleReceive}.
    event MessageProcessed(bytes32 indexed guid);
    /// @notice Inbound processing reverted and was captured into the default error state. `message`
    ///         is the ABI-encoded {Inbound} (reconstruct it to call retry/recover); `reason` is the
    ///         caught revert data.
    event MessageFailed(bytes32 indexed guid, Channel indexed channel, bytes message, bytes reason);
    /// @notice A failed message was resolved by a successful retry (reprocessed to completion).
    event MessageRecovered(bytes32 indexed guid, address indexed caller);
    /// @notice A failed message was finalized as REFUNDED: its held tokens were returned to `to` — the
    ///         source sender after a retry failed again, or the recipient of an owner recovery.
    ///         `reason` is the latest caught revert data (empty for owner recovery).
    event MessageRefunded(bytes32 indexed guid, address indexed to, bytes reason);
    /// @notice Unused native value delivered with a message (e.g. a LayerZero compose `value` pre-paying
    ///         the return leg) was returned to the message's {failedMessageHandler} as native ETH
    ///         (best-effort). If the handler is unset, or the transfer fails, the surplus is left in the
    ///         contract's reserve instead (no event) — the refund recipient must be able to accept ETH.
    event DeliveredValueRefunded(bytes32 indexed guid, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotCcipRouter(address caller);
    error NotLzEndpoint(address caller);
    error UnauthorizedCcipSource(uint64 srcSelector);
    error UnauthorizedOft(uint32 srcEid, address oft);
    error CcipDestNotAllowed(uint64 dstSelector);
    error LzDestNotAllowed(uint32 dstEid);
    error StargateDestNotAllowed(uint32 dstEid);
    error InvalidSenderLength(uint256 length);
    error InsufficientNativeFee(uint256 required, uint256 available);
    error NativeTransferFailed(address to, uint256 amount);
    error NotSelf(address caller);
    error MessageNotFailed(bytes32 guid);
    error InboundMismatch(bytes32 guid);
    error RetryReserveDrawn(uint256 shortfall);
    error NoHandler(bytes32 guid);
    error NotHandler(address caller, address handler);
    error RefundRouteNotConfigured(address token);
    error LocalRefundOnly(bytes32 guid);
    error CannotTransferAdminToSelf();
    error SvmComputeUnitsNotZero(uint32 computeUnits);
    error SvmLaneNotEnabled(uint64 selector);

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyCcipRouter() {
        if (msg.sender != s_ccipRouter) revert NotCcipRouter(msg.sender);
        _;
    }

    modifier onlyLzEndpoint() {
        if (msg.sender != s_lzEndpoint) revert NotLzEndpoint(msg.sender);
        _;
    }

    /// @dev Restricts to internal `this.x()` self-calls, enabling try/catch isolation of the hook.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf(msg.sender);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes the transport base. Call exactly once from the inheriting app's
    ///      `initialize` (which carries the `initializer` modifier). The deployed implementation is
    ///      never initialized directly — apps call `_disableInitializers()` in their constructor and
    ///      are used only through clones, which initialize their own storage.
    /// @param ccipRouter Chainlink CCIP router on this chain.
    /// @param lzEndpoint LayerZero EndpointV2 on this chain.
    /// @param initialOwner Receives {DEFAULT_ADMIN_ROLE}, {FEE_SETTER_ROLE}, and {FEE_COLLECTOR_ROLE} at init.
    function __MultiChannelBridgeAdapter_init(address ccipRouter, address lzEndpoint, address initialOwner) internal onlyInitializing {
        if (ccipRouter == address(0) || lzEndpoint == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(FEE_SETTER_ROLE, initialOwner);
        _grantRole(FEE_COLLECTOR_ROLE, initialOwner);
        s_ccipRouter = ccipRouter;
        s_lzEndpoint = lzEndpoint;
    }

    /// @notice One-step admin hand-off: grants {DEFAULT_ADMIN_ROLE} to `account` and revokes it from the
    ///         caller. Optionally migrates the caller's fee roles in the same call: a non-zero
    ///         `feeSetter` / `feeCollector` is granted that role and the CALLER's matching role is revoked;
    ///         pass `address(0)` to leave that fee role untouched. Reverts if `account` is the zero address
    ///         or the caller itself (a self-transfer would revoke the sole admin and leave the clone with
    ///         no admin — permanent on a non-upgradeable clone).
    ///
    ///         WARNING — PARTIAL HANDOFF WITH ZERO ADDRESSES: passing `address(0)` for `feeSetter` /
    ///         `feeCollector` KEEPS the corresponding role where it currently sits — including on the
    ///         OUTGOING caller. `transferAdmin(newAdmin, address(0), address(0))` therefore leaves the old
    ///         administrator holding {FEE_SETTER_ROLE} and {FEE_COLLECTOR_ROLE}: it can still change fee
    ///         policy and withdraw collected fees until the new admin revokes those roles via
    ///         {AccessControl.revokeRole}. For a COMPLETE handoff, pass explicit non-zero replacement
    ///         addresses for both fee roles (as the production deployment scripts do).
    /// @param account The new admin (must not be `address(0)` or `msg.sender`).
    /// @param feeSetter New {FEE_SETTER_ROLE} holder; `address(0)` leaves the fee-setter role unchanged
    ///        (the caller RETAINS it if they currently hold it).
    /// @param feeCollector New {FEE_COLLECTOR_ROLE} holder; `address(0)` leaves the fee-collector role
    ///        unchanged (the caller RETAINS it if they currently hold it).
    function transferAdmin(address account, address feeSetter, address feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (account == msg.sender) revert CannotTransferAdminToSelf();

        _grantRole(DEFAULT_ADMIN_ROLE, account);
        _revokeRole(DEFAULT_ADMIN_ROLE, msg.sender);

        if (feeSetter != address(0)) {
            _grantRole(FEE_SETTER_ROLE, feeSetter);
            if (msg.sender != feeSetter) _revokeRole(FEE_SETTER_ROLE, msg.sender);
        }
        if (feeCollector != address(0)) {
            _grantRole(FEE_COLLECTOR_ROLE, feeCollector);
            if (msg.sender != feeCollector) _revokeRole(FEE_COLLECTOR_ROLE, msg.sender);
        }
    }

    /// @notice Accept native gas used to pay outbound CCIP/LayerZero fees.
    receive() external payable { }

    /*//////////////////////////////////////////////////////////////
                              INBOUND: CCIP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAny2EVMMessageReceiver
    /// @notice CCIP entrypoint. Only the configured router may call. Forwards the (already-credited)
    ///         tokens + data to {_handleInbound}; source-chain allowlisting is enforced inside
    ///         {processInbound} so a disallowed source is captured as a recoverable failure rather than
    ///         bricking the transfer at the router boundary.
    /// @param message The CCIP delivery (tokens already credited to this contract).
    function ccipReceive(Client.Any2EVMMessage calldata message) external virtual override onlyCcipRouter nonReentrant {
        bytes32 sender = _toBytes32(message.sender);

        Inbound memory inbound = Inbound({
            channel: Channel.CCIP,
            srcId: message.sourceChainSelector,
            sender: sender,
            guid: message.messageId,
            tokens: message.destTokenAmounts,
            data: message.data,
            lzOft: address(0)
        });
        emit TokensReceived(Channel.CCIP, message.sourceChainSelector, sender, message.messageId, inbound.tokens.length);
        _handleInbound(inbound);
    }

    /*//////////////////////////////////////////////////////////////
                          INBOUND: LAYERZERO COMPOSE
    //////////////////////////////////////////////////////////////*/

    /// @notice LayerZero OFT compose entrypoint (see IOAppComposer/ILayerZeroComposer). Only the
    ///         configured endpoint may call, and the `(srcEid, oft)` pair must be allowlisted — a
    ///         disallowed compose reverts here (it credits no tokens, so there is nothing to recover and
    ///         capturing it would create a permanently stuck entry). Decodes the OFT compose and forwards
    ///         the already-credited underlying token + payload to {_handleInbound}.
    /// @param _from The local OFT/pool that delivered the compose (inbound `lzOft`).
    /// @param _guid The LayerZero message guid.
    /// @param _message The OFT compose payload (amount, compose message, sender, …).
    /// @param _executor The LayerZero executor (unused).
    /// @param _extraData Opaque executor data (unused).
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    )
        external
        payable
        virtual
        override
        onlyLzEndpoint
        nonReentrant
    {
        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        // Authenticate the `(srcEid, oft)` at the boundary. A spoofed/disallowed compose (e.g. any OApp
        // calling `endpoint.sendCompose` on this contract) credits NO real tokens, so revert rather than
        // capture it — capturing would create an unrecoverable "phantom" failed-message entry. This also
        // avoids calling `IOFT(_from).token()` below on an unvalidated `_from`.
        if (!s_lzOftAllowed[srcEid][_from]) revert UnauthorizedOft(srcEid, _from);

        Client.EVMTokenAmount[] memory tokens = new Client.EVMTokenAmount[](1);
        tokens[0] = Client.EVMTokenAmount({ token: IOFT(_from).token(), amount: OFTComposeMsgCodec.amountLD(_message) });

        Inbound memory inbound = Inbound({
            channel: Channel.LayerZero,
            srcId: srcEid,
            sender: OFTComposeMsgCodec.composeFrom(_message),
            guid: _guid,
            tokens: tokens,
            data: OFTComposeMsgCodec.composeMsg(_message),
            lzOft: _from
        });
        emit TokensReceived(Channel.LayerZero, srcEid, inbound.sender, _guid, 1);
        _handleInbound(inbound);
    }

    /*//////////////////////////////////////////////////////////////
              INBOUND PROCESSING + GRACEFUL FAILURE CAPTURE (DEFAULT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Runs the application hook inside an isolated external self-call so a revert in
    ///      {_handleReceive} (or anything it calls) is CAUGHT rather than bricking the inbound
    ///      transfer. On failure the message is captured into the default error state — a one-slot
    ///      hash commitment over the full {Inbound} — and the tokens the channel delivered remain in
    ///      this contract, exactly matching the committed amounts (the reverted sub-call's state,
    ///      including any partial token moves the hook attempted, is rolled back). Resolution is then
    ///      driven by {refundToSource} (permissionless bounce-back) or, for a message that designates a
    ///      {failedMessageHandler}, that handler's {retryFailedMessage} / {refundLocal}.
    ///
    ///      Any native VALUE delivered alongside the message (e.g. a LayerZero compose `value` the
    ///      sender attached to pre-pay the outbound return leg) is forwarded to the hook; whatever is
    ///      unused (the full amount on failure, the surplus over the spent fee on success) is returned to
    ///      the message's {failedMessageHandler} as native ETH (best-effort), or left in the reserve when
    ///      no handler is set or the transfer fails. See {_refundDeliveredValueSurplus}.
    /// @param inbound The normalised inbound delivery.
    function _handleInbound(Inbound memory inbound) internal {
        // Reserve = the contract's prefunded native, excluding any value delivered with this message.
        uint256 reserveBefore = address(this).balance - msg.value;

        try this.processInbound{ value: msg.value }(inbound) {
            emit MessageProcessed(inbound.guid);
        } catch (bytes memory reason) {
            bytes memory encoded = abi.encode(inbound);
            // Store only the fixed-size commitment: the capture's storage cost is bounded regardless of
            // the payload/reason size. Recovery reconstructs the Inbound from the event below.
            s_failedInboundHash[inbound.guid] = keccak256(encoded);
            emit MessageFailed(inbound.guid, inbound.channel, encoded, reason);
        }

        // Return UNUSED transport-delivered native: on success the surplus over the return-leg fee the
        // hook spent; on failure the full delivered amount (the reverted hook spent nothing). Only when
        // native was delivered (a LayerZero compose `value`); value-less CCIP deliveries leave
        // `reserveBefore == balance` and may legitimately draw the reserve. The surplus is returned to
        // the message's {failedMessageHandler} as native ETH (best-effort); with no handler, or if the
        // send fails, it is left in the reserve.
        _refundDeliveredValueSurplus(inbound, reserveBefore);
    }

    /// @dev Returns unused LZ compose `value` to the message's {failedMessageHandler} as a best-effort
    ///      NATIVE transfer. Must not revert — the inbound token delivery must remain recoverable even if
    ///      the refund fails. If no handler is designated, or the transfer fails, the surplus is simply
    ///      left in the contract's reserve (it becomes operator float). The handler must be able to
    ///      accept ETH; a contract handler that rejects ETH forfeits the surplus to the reserve.
    /// @param inbound The normalised inbound delivery (for guid + handler resolution).
    /// @param reserveBefore The contract native balance excluding `msg.value` from this delivery.
    function _refundDeliveredValueSurplus(Inbound memory inbound, uint256 reserveBefore) internal {
        if (msg.value == 0 || address(this).balance <= reserveBefore) return;

        address handler = _resolveHandler(inbound.data);
        if (handler == address(0)) return; // no refund target -> leave the surplus in the reserve

        uint256 leftover = address(this).balance - reserveBefore;
        // Best-effort native send; a failure (e.g. a handler that rejects ETH) leaves the surplus in the reserve.
        (bool sent,) = handler.call{ value: leftover }("");
        if (sent) emit DeliveredValueRefunded(inbound.guid, handler, leftover);
    }

    /// @notice Self-call target that runs the application hook; `external` only so {_handleInbound}
    ///         can isolate it in try/catch. Not callable by anyone but this contract. `payable` so the
    ///         transport-delivered native is visible to {_handleReceive} (which may spend it on the
    ///         outbound return leg and refund the surplus). The CCIP source-chain-selector allowlist is
    ///         enforced here, so a disallowed CCIP source is captured as a recoverable failure (its tokens
    ///         are real); the LayerZero `(srcEid, oft)` allowlist is enforced earlier at the {lzCompose}
    ///         boundary (a disallowed compose carries no tokens and reverts instead of being captured).
    /// @param inbound The normalised inbound delivery.
    function processInbound(Inbound calldata inbound) external payable onlySelf whenNotPaused {
        if (inbound.channel == Channel.CCIP && !s_ccipSourceAllowed[inbound.srcId]) {
            revert UnauthorizedCcipSource(inbound.srcId);
        }
        if (inbound.channel == Channel.LayerZero && !s_lzOftAllowed[uint32(inbound.srcId)][inbound.lzOft]) {
            revert UnauthorizedOft(uint32(inbound.srcId), inbound.lzOft);
        }
        _handleReceive(inbound);
    }

    /// @notice Implemented by the inheriting application. Receives the normalised inbound delivery
    ///         (tokens already held by this contract + the arbitrary `data`) and does whatever the
    ///         application needs — e.g. interact with a vault and bridge the result onward via
    ///         {_sendViaCcip} / {_sendViaOft}. MAY revert: a revert is captured as a recoverable
    ///         failed message (see {_handleInbound}) and never bricks the transfer.
    /// @param inbound The normalised inbound delivery.
    function _handleReceive(Inbound calldata inbound) internal virtual;

    /*//////////////////////////////////////////////////////////////
                          FAILED-MESSAGE RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Adapter hook: decode the designated FAILED-MESSAGE HANDLER from an inbound `data` payload. A
    ///         well-formed application message embeds a handler address — the party allowed to
    ///         {retryFailedMessage} or {refundLocal} a failure. The default returns `address(0)`: a
    ///         message that carries no handler (or a malformed/dataless token transfer) can only be
    ///         bounced back to source via the permissionless {refundToSource}.
    /// @dev Declared `external` so the base can isolate a malformed-payload decode revert in
    ///      `try/catch` (see {_resolveHandler}). Apps override it to parse their own message format.
    /// @param data The inbound application payload.
    /// @return handler The handler address, or `address(0)` for none.
    function failedMessageHandler(
        bytes calldata data
    )
        external
        view
        virtual
        returns (address)
    {
        return address(0);
    }

    /// @notice Adapter hook: whether the inbound `data` payload OPTED IN to local-only recovery. When
    ///         true AND the message designates a {failedMessageHandler}, the permissionless
    ///         {refundToSource} is blocked, so only the handler can resolve the failure (via
    ///         {retryFailedMessage} / {refundLocal}) — this prevents a third party from preempting the
    ///         handler with an unwanted cross-chain bounce. Default `false` (permissionless bounce
    ///         allowed). NO-FREEZE INVARIANT: the flag only gates {refundToSource} when a handler is also
    ///         present, so a handler-less or malformed payload can never be frozen.
    /// @dev Declared `external` so the base can isolate a malformed-payload decode revert in `try/catch`
    ///      (see {_resolveOnlyLocalRefund}). Apps override it to parse their own message format.
    /// @param data The inbound application payload.
    /// @return Whether the message requires handler-only (local) recovery.
    function onlyLocalRefund(
        bytes calldata data
    )
        external
        view
        virtual
        returns (bool)
    {
        return false;
    }

    /// @notice PERMISSIONLESS resolution: bounce a failed message's tokens back to the source sender on
    ///         the SOURCE chain, over the same channel they arrived on. Intended for malformed/dataless
    ///         token transfers that can never execute — anyone (e.g. a keeper bot) can clear them. The
    ///         caller funds the bounce fee via `msg.value` (surplus returned); it does not draw the
    ///         prefunded reserve, which is reserved for the original double-hop delivery.
    /// @dev The caller supplies the full captured {Inbound} (reconstruct it from the {MessageFailed}
    ///      event's `message` field: `abi.decode(message, (Inbound))`); it is verified against the stored
    ///      hash commitment. If the message opted into local-only recovery ({onlyLocalRefund}) AND
    ///      designates a handler, this is BLOCKED ({LocalRefundOnly}) — the handler must use
    ///      {retryFailedMessage}/{refundLocal}. NO-FREEZE: a handler-less message stays permissionlessly
    ///      refundable regardless of the flag.
    /// @param inbound The captured failed delivery (must hash-match the stored commitment).
    function refundToSource(Inbound calldata inbound) external payable nonReentrant {
        _takeFailedInbound(inbound);
        // Block the permissionless bounce only when the sender opted into local-only recovery AND a
        // handler exists to perform it — otherwise a handler-less message could be permanently frozen.
        if (_resolveOnlyLocalRefund(inbound.data) && _resolveHandler(inbound.data) != address(0)) {
            revert LocalRefundOnly(inbound.guid);
        }
        s_refunded[inbound.guid] = true;

        uint256 reserveBefore = address(this).balance - msg.value;
        _bridgeBackToSource(inbound);
        if (address(this).balance < reserveBefore) revert RetryReserveDrawn(reserveBefore - address(this).balance);

        emit MessageRefunded(inbound.guid, address(uint160(uint256(inbound.sender))), "");
        _returnSurplus(reserveBefore);
    }

    /// @notice HANDLER-ONLY resolution: re-run {_handleReceive} with the original delivery (e.g. after
    ///         the failure cause — a transient gas/liquidity shortfall — clears). The caller funds any
    ///         outbound fee via `msg.value` (surplus returned); the prefunded reserve is never drawn.
    ///         If reprocessing still reverts, this reverts too and the message stays FAILED, so the
    ///         handler can instead {refundLocal} or {refundToSource}.
    /// @param inbound The captured failed delivery (reconstruct from {MessageFailed}; hash-verified).
    function retryFailedMessage(Inbound calldata inbound) external payable nonReentrant {
        _takeFailedInbound(inbound);
        _requireHandler(inbound);

        uint256 reserveBefore = address(this).balance - msg.value;
        this.processInbound{ value: msg.value }(inbound); // reverts on failure -> whole tx reverts, message stays FAILED
        if (address(this).balance < reserveBefore) revert RetryReserveDrawn(reserveBefore - address(this).balance);

        emit MessageRecovered(inbound.guid, msg.sender);
        _returnSurplus(reserveBefore);
    }

    /// @notice HANDLER-ONLY resolution: finalize a failed message by sending its held tokens to a local
    ///         address of the handler's choosing (e.g. for something permanently wrong with the route).
    /// @param inbound The captured failed delivery (reconstruct from {MessageFailed}; hash-verified).
    /// @param to   Local recipient of the refunded tokens.
    function refundLocal(Inbound calldata inbound, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _takeFailedInbound(inbound);
        _requireHandler(inbound);
        s_refunded[inbound.guid] = true;
        _refundTokens(inbound, to);
        emit MessageRefunded(inbound.guid, to, "");
    }

    /// @notice Whether `guid` currently has an unresolved captured failure (retryable / refundable).
    /// @param guid The channel-unique message id.
    /// @return True if the message is captured and unresolved.
    function isFailed(bytes32 guid) external view returns (bool) {
        return s_failedInboundHash[guid] != bytes32(0);
    }

    /// @notice Whether `guid` was finalized as REFUNDED (tokens returned; terminal).
    /// @param guid The channel-unique message id.
    /// @return True if the message was refunded.
    function isRefunded(bytes32 guid) external view returns (bool) {
        return s_refunded[guid];
    }

    /// @notice Hash commitment for a captured failed message (`bytes32(0)` if not failed). This is the
    ///         exact value the stored capture consists of; reconstruct the full {Inbound} from the
    ///         {MessageFailed} event's `message` field (`abi.decode(message, (Inbound))`) — it hashes to
    ///         this commitment.
    /// @param guid The channel-unique message id.
    /// @return `keccak256(abi.encode(inbound))` for the stored failure, or zero.
    function failedMessageHash(bytes32 guid) external view returns (bytes32) {
        return s_failedInboundHash[guid];
    }

    /// @dev Bounces each held token back to the source sender on the source chain, over the inbound
    ///      channel. The destination is an already-verified inbound source, so the outbound allowlist is
    ///      bypassed. For LayerZero the per-token OFT is resolved via {_oftFor} (apps that accept LZ
    ///      inbound must override it). Override this whole hook for fully custom bounce routing.
    /// @param inbound The original captured delivery to bounce.
    function _bridgeBackToSource(Inbound memory inbound) internal virtual {
        bytes32 senderWord = inbound.sender;
        uint256 n = inbound.tokens.length;
        for (uint256 i; i < n; ++i) {
            address token = inbound.tokens[i].token;
            uint256 amount = inbound.tokens[i].amount;
            if (inbound.channel == Channel.CCIP) {
                if (s_ccipSvm[inbound.srcId].enabled) {
                    // Bounce back to a Solana source: keep the full 32-byte sender as the token receiver.
                    _ccipSendSvm(inbound.srcId, senderWord, token, amount);
                } else {
                    _ccipSend(inbound.srcId, address(uint160(uint256(senderWord))), token, amount, "", 0, address(0));
                }
            } else {
                address oft = inbound.lzOft != address(0) ? inbound.lzOft : _oftFor(token);
                if (oft == address(0)) revert RefundRouteNotConfigured(token);
                _oftSend(uint32(inbound.srcId), senderWord, oft, amount, 0, "", lzReceiveOption(REFUND_LZ_RECEIVE_GAS));
            }
        }
    }

    /// @dev Adapter hook: the OFT that bridges `token`, used to bounce a LayerZero inbound back to source.
    ///      Default none; apps that accept LayerZero inbound override it (e.g. from their token=>OFT map).
    /// @param token The token to resolve an OFT for.
    /// @return oft The LayerZero OFT that bridges `token`, or `address(0)` if unset.
    function _oftFor(
        address token
    )
        internal
        view
        virtual
        returns (address)
    {
        return address(0);
    }

    /// @dev Authenticates `msg.sender` as the message's {failedMessageHandler}. Reverts {NoHandler} if
    ///      the (validated) payload designates none, or {NotHandler} if the caller is someone else.
    /// @param inbound The stored failed delivery.
    function _requireHandler(Inbound memory inbound) internal view {
        address handler = _resolveHandler(inbound.data);
        if (handler == address(0)) revert NoHandler(inbound.guid);
        if (msg.sender != handler) revert NotHandler(msg.sender, handler);
    }

    /// @dev Revert-safe extraction of the handler from a payload: a malformed payload that reverts the
    ///      app's {failedMessageHandler} decode yields `address(0)` (no handler).
    /// @param data The inbound application payload.
    /// @return handler The designated handler, or `address(0)` if decode fails or none is set.
    function _resolveHandler(bytes memory data) internal view returns (address handler) {
        try this.failedMessageHandler(data) returns (address h) {
            handler = h;
        } catch {
            handler = address(0);
        }
    }

    /// @dev Revert-safe extraction of the local-only-recovery flag: a malformed payload that reverts the
    ///      app's {onlyLocalRefund} decode yields `false` (permissionless bounce allowed).
    /// @param data The inbound application payload.
    /// @return localOnly Whether the message opted into handler-only recovery.
    function _resolveOnlyLocalRefund(bytes memory data) internal view returns (bool localOnly) {
        try this.onlyLocalRefund(data) returns (bool v) {
            localOnly = v;
        } catch {
            localOnly = false;
        }
    }

    /// @dev Returns any native the caller over-supplied for a recovery, restoring the reserve baseline.
    /// @param reserveBefore The contract native balance before the recovery caller attached `msg.value`.
    function _returnSurplus(uint256 reserveBefore) internal {
        uint256 surplus = address(this).balance - reserveBefore;
        if (surplus > 0) {
            (bool ok,) = msg.sender.call{ value: surplus }("");
            if (!ok) revert NativeTransferFailed(msg.sender, surplus);
        }
    }

    /// @dev Verifies the caller-supplied `inbound` against the stored hash commitment for its guid and
    ///      clears the commitment. Reverts {MessageNotFailed} if nothing is captured for the guid and
    ///      {InboundMismatch} if the reconstruction does not hash to the commitment. On recovery tx
    ///      revert the delete rolls back and the message stays failed.
    /// @param inbound The caller-reconstructed captured delivery (from the {MessageFailed} event).
    function _takeFailedInbound(Inbound calldata inbound) internal {
        bytes32 stored = s_failedInboundHash[inbound.guid];
        if (stored == bytes32(0)) revert MessageNotFailed(inbound.guid);
        if (keccak256(abi.encode(inbound)) != stored) revert InboundMismatch(inbound.guid);
        delete s_failedInboundHash[inbound.guid];
    }

    /// @dev Transfers each committed token amount to `to`.
    /// @param inbound The stored failed delivery.
    /// @param to The local recipient of the refunded tokens.
    function _refundTokens(Inbound memory inbound, address to) internal {
        uint256 n = inbound.tokens.length;
        for (uint256 i; i < n; ++i) {
            IERC20(inbound.tokens[i].token).safeTransfer(to, inbound.tokens[i].amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                OUTBOUND
    //////////////////////////////////////////////////////////////*/

    /// @notice Sends one token to an EVM receiver over CCIP. Fee is paid in native from this
    ///         contract's balance, or in `feeToken` (ERC-20) if non-zero.
    /// @param dstSelector  Destination CCIP chain selector (must be allowlisted).
    /// @param receiver     Destination EVM recipient.
    /// @param token        Token to bridge (held by this contract).
    /// @param amount       Amount in the token's own decimals.
    /// @param data         Arbitrary payload delivered to the destination receiver.
    /// @param dstGasLimit  Gas for any destination receiver hook (0 for plain wallet/pool delivery).
    /// @param feeToken     CCIP fee token; `address(0)` = native.
    /// @return messageId   CCIP message id.
    /// @return fee         Fee paid (in `feeToken` units; native if `feeToken == address(0)`).
    function _sendViaCcip(
        uint64 dstSelector,
        address receiver,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 dstGasLimit,
        address feeToken
    )
        internal
        returns (bytes32 messageId, uint256 fee)
    {
        if (!s_ccipDestAllowed[dstSelector]) revert CcipDestNotAllowed(dstSelector);
        return _ccipSend(dstSelector, receiver, token, amount, data, dstGasLimit, feeToken);
    }

    /// @dev CCIP single-token send WITHOUT the outbound destination allowlist check. Backs
    ///      {_sendViaCcip} (which adds the check) and the refund-to-source bounce (whose destination is
    ///      an already-verified inbound source, so the outbound allowlist does not apply). Do not wire
    ///      this to untrusted input. Supports `feeToken == token` (e.g. bridging LINK while paying the
    ///      CCIP fee in LINK) by granting a single combined `amount + fee` allowance.
    /// @param dstSelector Destination CCIP chain selector.
    /// @param receiver Destination EVM recipient.
    /// @param token Token to bridge (held by this contract).
    /// @param amount Amount in the token's own decimals.
    /// @param data Arbitrary payload for the destination receiver.
    /// @param dstGasLimit Gas for any destination receiver hook.
    /// @param feeToken CCIP fee token (`address(0)` = native).
    /// @return messageId CCIP message id.
    /// @return fee Fee paid (in `feeToken` units; native if `feeToken == address(0)`).
    function _ccipSend(
        uint64 dstSelector,
        address receiver,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 dstGasLimit,
        address feeToken
    )
        internal
        returns (bytes32 messageId, uint256 fee)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: amount });
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), data: data, tokenAmounts: tokenAmounts, feeToken: feeToken, extraArgs: _buildCcipExtraArgs(dstSelector, dstGasLimit)
        });

        IRouterClient router = IRouterClient(s_ccipRouter);
        fee = router.getFee(dstSelector, message);

        if (feeToken == address(0)) {
            IERC20(token).forceApprove(address(router), amount);
            if (address(this).balance < fee) revert InsufficientNativeFee(fee, address(this).balance);
            // Destination is the immutable, configured CCIP router; value is its quoted fee.
            // slither-disable-next-line arbitrary-send-eth
            messageId = router.ccipSend{ value: fee }(dstSelector, message);
        } else if (feeToken == token) {
            // Same-token fee: one combined allowance — separate approvals would overwrite each other
            // (forceApprove sets an absolute allowance), leaving too little for the router to pull both
            // the fee and the bridged amount.
            IERC20(token).forceApprove(address(router), amount + fee);
            messageId = router.ccipSend(dstSelector, message);
        } else {
            IERC20(token).forceApprove(address(router), amount);
            IERC20(feeToken).forceApprove(address(router), fee);
            messageId = router.ccipSend(dstSelector, message);
            IERC20(feeToken).forceApprove(address(router), 0);
        }
        IERC20(token).forceApprove(address(router), 0);
        emit SentViaCcip(messageId, dstSelector, token, amount, fee);
    }

    /// @notice Sends one token over CCIP to a Solana (SVM) chain. Solana addresses are 32 bytes, so the
    ///         recipient is the full `tokenReceiver` word and the message uses `SVMExtraArgsV1` with an
    ///         empty `receiver` (token-only transfer, no destination program). Native fee only.
    /// @param dstSelector  Destination CCIP chain selector (must be allowlisted AND marked SVM).
    /// @param tokenReceiver The recipient's Solana WALLET address (the token-account owner), 32 bytes.
    ///        MUST NOT be an associated token account (ATA): the Solana offramp derives the recipient's
    ///        ATA from this wallet address automatically, so an ATA here derives a token account owned
    ///        by the ATA's own (off-curve) public key and the bridged tokens are permanently locked.
    /// @param token        Token to bridge (held by this contract; needs a CCIP pool on Solana).
    /// @param amount       Amount in the token's own decimals.
    /// @return messageId   CCIP message id.
    /// @return fee         Native fee paid.
    function _sendViaCcipSvm(uint64 dstSelector, bytes32 tokenReceiver, address token, uint256 amount) internal returns (bytes32 messageId, uint256 fee) {
        if (!s_ccipDestAllowed[dstSelector]) revert CcipDestNotAllowed(dstSelector);
        // The natspec contract ("allowlisted AND marked SVM") is enforced: sending SVM-encoded args to a
        // selector whose SVM config is not enabled would revert in fee quoting/sending with an opaque
        // error — fail with an explicit one instead.
        if (!s_ccipSvm[dstSelector].enabled) revert SvmLaneNotEnabled(dstSelector);
        return _ccipSendSvm(dstSelector, tokenReceiver, token, amount);
    }

    /// @dev CCIP-to-SVM single-token send WITHOUT the outbound destination allowlist check. Backs
    ///      {_sendViaCcipSvm} (which adds the check) and the refund-to-source bounce to a Solana source
    ///      (a verified inbound origin). Reads SVM params from {s_ccipSvm}. Do not wire to untrusted input.
    /// @param selector Destination CCIP chain selector (Solana lane).
    /// @param tokenReceiver The recipient's Solana WALLET address (token-account owner; NEVER an ATA —
    ///        see {_sendViaCcipSvm}).
    /// @param token Token to bridge (held by this contract).
    /// @param amount Amount in the token's own decimals.
    /// @return messageId CCIP message id.
    /// @return fee Native fee paid.
    function _ccipSendSvm(uint64 selector, bytes32 tokenReceiver, address token, uint256 amount) internal returns (bytes32 messageId, uint256 fee) {
        CcipSvmConfig memory cfg = s_ccipSvm[selector];
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: amount });
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            // Token-only transfer to Solana: no destination program (so `accounts` empty). CCIP's
            // FeeQuoter requires the SVM receiver to be EXACTLY 32 bytes and expects a token-only
            // transfer to encode it as the 32-byte zero word — empty bytes revert in `getFee`.
            receiver: abi.encode(bytes32(0)),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: Client._svmArgsToBytes(
                Client.SVMExtraArgsV1({
                    computeUnits: cfg.computeUnits,
                    accountIsWritableBitmap: 0,
                    allowOutOfOrderExecution: cfg.allowOutOfOrderExecution,
                    tokenReceiver: tokenReceiver,
                    accounts: new bytes32[](0)
                })
            )
        });

        IRouterClient router = IRouterClient(s_ccipRouter);
        fee = router.getFee(selector, message);
        if (address(this).balance < fee) revert InsufficientNativeFee(fee, address(this).balance);
        IERC20(token).forceApprove(address(router), amount);
        // Destination is the immutable, configured CCIP router; value is its quoted fee.
        // slither-disable-next-line arbitrary-send-eth
        messageId = router.ccipSend{ value: fee }(selector, message);
        IERC20(token).forceApprove(address(router), 0);
        emit SentViaCcip(messageId, selector, token, amount, fee);
    }

    /// @notice Sends one token over a LayerZero OFT. Native fee is paid from this contract's balance.
    /// @param dstEid       Destination LayerZero endpoint id (must be allowlisted).
    /// @param to           Destination recipient (peer-encoded bytes32).
    /// @param oft          OFT/OFTAdapter that bridges the token (`IOFT(oft).token()` is the asset).
    /// @param amount       Amount in local decimals.
    /// @param minAmount    Minimum amount the recipient must receive (OFT enforces; 0 to skip).
    /// @param composeMsg   Optional onward compose payload (empty for a plain transfer).
    /// @param extraOptions LayerZero executor options (see {lzReceiveOption} for the common case).
    /// @return guid        LayerZero message guid.
    /// @return fee         Native fee paid.
    function _sendViaOft(
        uint32 dstEid,
        bytes32 to,
        address oft,
        uint256 amount,
        uint256 minAmount,
        bytes memory composeMsg,
        bytes memory extraOptions
    )
        internal
        returns (bytes32 guid, uint256 fee)
    {
        if (!s_lzDestAllowed[dstEid]) revert LzDestNotAllowed(dstEid);
        return _oftSend(dstEid, to, oft, amount, minAmount, composeMsg, extraOptions);
    }

    /// @dev OFT single-token send WITHOUT the outbound destination allowlist check. Backs {_sendViaOft}
    ///      (which adds the check) and the refund-to-source bounce (destination is a verified inbound
    ///      source). Do not wire this to untrusted input.
    /// @param dstEid Destination LayerZero endpoint id.
    /// @param to Destination recipient (peer-encoded bytes32).
    /// @param oft OFT/OFTAdapter that bridges the token.
    /// @param amount Amount in local decimals.
    /// @param minAmount Minimum amount the recipient must receive (0 to skip).
    /// @param composeMsg Optional onward compose payload (empty for a plain transfer).
    /// @param extraOptions LayerZero executor options.
    /// @return guid LayerZero message guid.
    /// @return fee Native fee paid.
    function _oftSend(
        uint32 dstEid,
        bytes32 to,
        address oft,
        uint256 amount,
        uint256 minAmount,
        bytes memory composeMsg,
        bytes memory extraOptions
    )
        internal
        returns (bytes32 guid, uint256 fee)
    {
        SendParam memory sendParam =
            SendParam({ dstEid: dstEid, to: to, amountLD: amount, minAmountLD: minAmount, extraOptions: extraOptions, composeMsg: composeMsg, oftCmd: "" });

        MessagingFee memory msgFee = IOFT(oft).quoteSend(sendParam, false);
        if (address(this).balance < msgFee.nativeFee) revert InsufficientNativeFee(msgFee.nativeFee, address(this).balance);

        address token = IOFT(oft).token();
        bool needsApproval = IOFT(oft).approvalRequired();
        if (needsApproval) IERC20(token).forceApprove(oft, amount);
        // Destination is the inheritor-configured OFT for this token; value is its quoted native fee.
        // slither-disable-next-line arbitrary-send-eth
        (MessagingReceipt memory receipt,) = IOFT(oft).send{ value: msgFee.nativeFee }(sendParam, msgFee, address(this));
        if (needsApproval) IERC20(token).forceApprove(oft, 0);

        guid = receipt.guid;
        fee = msgFee.nativeFee;
        emit SentViaOft(guid, dstEid, token, amount, fee);
    }

    /// @notice Sends one token over a Stargate V2 pool (canonical, native token out), the third rail
    ///         alongside CCIP and plain OFT. Stargate is LayerZero-based and `IStargate is IOFT`, so this
    ///         mirrors {_sendViaOft} but routes through Stargate's pooled-liquidity `sendToken` in instant
    ///         "taxi" mode (empty `oftCmd`). The pool charges an LP fee, so the recipient receives less
    ///         than `amount`; `minAmountLD` floors that. Native fee is paid from this contract's balance.
    /// @param dstEid       Destination LayerZero endpoint id (must be Stargate-allowlisted).
    /// @param to           Destination recipient (peer-encoded bytes32).
    /// @param pool         Stargate pool/OFT for the token (`IStargate(pool).token()` is the asset; must
    ///                     be an ERC-20 pool — native-ETH Stargate pools are not supported by this path).
    /// @param amount       Amount to send in local decimals.
    /// @param minAmountLD  Minimum the recipient must receive after the LP fee (Stargate enforces).
    /// @param extraOptions LayerZero executor options (see {lzReceiveOption}).
    /// @return guid        LayerZero message guid.
    /// @return fee         Native fee paid.
    function _sendViaStargate(
        uint32 dstEid,
        bytes32 to,
        address pool,
        uint256 amount,
        uint256 minAmountLD,
        bytes memory extraOptions
    )
        internal
        returns (bytes32 guid, uint256 fee)
    {
        if (!s_stargateDestAllowed[dstEid]) revert StargateDestNotAllowed(dstEid);

        SendParam memory sendParam =
            SendParam({ dstEid: dstEid, to: to, amountLD: amount, minAmountLD: minAmountLD, extraOptions: extraOptions, composeMsg: "", oftCmd: "" });

        MessagingFee memory msgFee = IStargate(pool).quoteSend(sendParam, false);
        if (address(this).balance < msgFee.nativeFee) revert InsufficientNativeFee(msgFee.nativeFee, address(this).balance);

        address token = IStargate(pool).token();
        bool needsApproval = IStargate(pool).approvalRequired();
        if (needsApproval) IERC20(token).forceApprove(pool, amount);
        // Destination is the inheritor-configured Stargate pool for this token; value is its quoted fee.
        // The bus `Ticket` (third return) is ignored: taxi mode delivers inline.
        // slither-disable-next-line arbitrary-send-eth
        (MessagingReceipt memory receipt,,) = IStargate(pool).sendToken{ value: msgFee.nativeFee }(sendParam, msgFee, address(this));
        if (needsApproval) IERC20(token).forceApprove(pool, 0);

        guid = receipt.guid;
        fee = msgFee.nativeFee;
        emit SentViaStargate(guid, dstEid, token, amount, fee);
    }

    /*//////////////////////////////////////////////////////////////
                                  QUOTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Quotes the fee for a CCIP single-token send (mirrors {_sendViaCcip} message build).
    /// @param dstSelector Destination CCIP chain selector.
    /// @param receiver    Destination EVM recipient.
    /// @param token       Token to bridge.
    /// @param amount      Amount in the token's own decimals.
    /// @param data        Arbitrary payload for the destination receiver.
    /// @param dstGasLimit Gas for any destination receiver hook.
    /// @param feeToken    CCIP fee token (`address(0)` = native).
    /// @return fee        Fee in `feeToken` units (native if `feeToken == address(0)`).
    function quoteCcip(
        uint64 dstSelector,
        address receiver,
        address token,
        uint256 amount,
        bytes memory data,
        uint256 dstGasLimit,
        address feeToken
    )
        external
        view
        returns (uint256 fee)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({ token: token, amount: amount });
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver), data: data, tokenAmounts: tokenAmounts, feeToken: feeToken, extraArgs: _buildCcipExtraArgs(dstSelector, dstGasLimit)
        });
        return IRouterClient(s_ccipRouter).getFee(dstSelector, message);
    }

    /// @notice Quotes the native fee for a LayerZero OFT send.
    /// @param dstEid       Destination LayerZero endpoint id.
    /// @param to           Destination recipient (peer-encoded bytes32).
    /// @param oft          OFT/OFTAdapter that bridges the token.
    /// @param amount       Amount in local decimals.
    /// @param minAmount    Minimum the recipient must receive (0 to skip).
    /// @param composeMsg   Optional onward compose payload.
    /// @param extraOptions LayerZero executor options.
    /// @return nativeFee   Native fee for the send.
    function quoteOft(
        uint32 dstEid,
        bytes32 to,
        address oft,
        uint256 amount,
        uint256 minAmount,
        bytes memory composeMsg,
        bytes memory extraOptions
    )
        external
        view
        returns (uint256 nativeFee)
    {
        SendParam memory sendParam =
            SendParam({ dstEid: dstEid, to: to, amountLD: amount, minAmountLD: minAmount, extraOptions: extraOptions, composeMsg: composeMsg, oftCmd: "" });
        return IOFT(oft).quoteSend(sendParam, false).nativeFee;
    }

    /// @notice Quotes the native fee for a Stargate taxi send (mirrors {_sendViaStargate} param build).
    /// @param dstEid       Destination LayerZero endpoint id.
    /// @param to           Destination recipient (peer-encoded bytes32).
    /// @param pool         Stargate pool for the token.
    /// @param amount       Amount in local decimals.
    /// @param minAmountLD  Minimum the recipient must receive after the LP fee.
    /// @param extraOptions LayerZero executor options.
    /// @return nativeFee   Native fee for the send.
    function quoteStargate(
        uint32 dstEid,
        bytes32 to,
        address pool,
        uint256 amount,
        uint256 minAmountLD,
        bytes memory extraOptions
    )
        external
        view
        returns (uint256 nativeFee)
    {
        SendParam memory sendParam =
            SendParam({ dstEid: dstEid, to: to, amountLD: amount, minAmountLD: minAmountLD, extraOptions: extraOptions, composeMsg: "", oftCmd: "" });
        return IStargate(pool).quoteSend(sendParam, false).nativeFee;
    }

    /// @notice Convenience builder for the common LayerZero option: a single `lzReceive` gas grant.
    /// @param gas Destination `lzReceive` gas.
    /// @return The encoded executor options.
    function lzReceiveOption(uint128 gas) public pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(gas, 0);
    }

    /// @notice Builds the CCIP `extraArgs` for an outbound send. The single seam that distinguishes
    ///         CCIP generations: the default here is the current production `GenericExtraArgsV2`
    ///         (gas limit + out-of-order). A "v2 / CCV+finality" variant overrides this to encode the
    ///         CCV / configurable-finality args for its lanes. The first argument is the outbound
    ///         CCIP destination chain selector (unused by the default; an override may vary args per
    ///         destination).
    /// @param dstSelector Destination CCIP chain selector (unused in the default V2 encoding).
    /// @param dstGasLimit The destination execution gas limit.
    /// @return extraArgs The encoded CCIP `extraArgs`.
    function _buildCcipExtraArgs(uint64 dstSelector, uint256 dstGasLimit) internal view virtual returns (bytes memory) {
        return Client._argsToBytes(Client.GenericExtraArgsV2({ gasLimit: dstGasLimit, allowOutOfOrderExecution: true }));
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Allowlist (or remove) an inbound CCIP `sourceChainSelector`. Any sender on an enabled chain
    ///         may deliver via the CCIP router.
    /// @param srcSelector The source CCIP chain selector.
    /// @param allowed     Whether to allow inbound from this chain.
    function setCcipSource(uint64 srcSelector, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_ccipSourceAllowed[srcSelector] = allowed;
        emit CcipSourceSet(srcSelector, allowed);
    }

    /// @notice Allowlist (or remove) an inbound LayerZero `(srcEid, oft)`.
    /// @param srcEid  The source LayerZero endpoint id.
    /// @param oft     The local OFT/pool delivering the inbound compose.
    /// @param allowed Whether to allow this `(srcEid, oft)` inbound.
    function setLzOft(uint32 srcEid, address oft, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oft == address(0)) revert ZeroAddress();
        s_lzOftAllowed[srcEid][oft] = allowed;
        emit LzOftSet(srcEid, oft, allowed);
    }

    /// @notice Allowlist (or remove) an outbound CCIP destination selector.
    /// @param dstSelector The destination CCIP chain selector.
    /// @param allowed     Whether to permit outbound sends to it.
    function setCcipDestination(uint64 dstSelector, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_ccipDestAllowed[dstSelector] = allowed;
        emit CcipDestSet(dstSelector, allowed);
    }

    /// @notice Allowlist (or remove) an outbound LayerZero destination eid.
    /// @param dstEid  The destination LayerZero endpoint id.
    /// @param allowed Whether to permit outbound sends to it.
    function setLzDestination(uint32 dstEid, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_lzDestAllowed[dstEid] = allowed;
        emit LzDestSet(dstEid, allowed);
    }

    /// @notice Allowlist (or remove) an outbound Stargate destination eid.
    /// @param dstEid  The destination LayerZero endpoint id (Stargate shares the EID space).
    /// @param allowed Whether to permit outbound Stargate sends to it.
    function setStargateDestination(uint32 dstEid, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_stargateDestAllowed[dstEid] = allowed;
        emit StargateDestSet(dstEid, allowed);
    }

    /// @notice Mark (or clear) a CCIP chain `selector` as a Solana (SVM) lane and set its execution
    ///         params. Governs both outbound CCIP-to-Solana sends and the inbound bounce to a Solana
    ///         source. The selector must still be allowlisted via {setCcipDestination} (outbound) /
    ///         {setCcipSource} (inbound) — this only switches the message encoding to SVM.
    /// @param selector                 The CCIP chain selector for the Solana chain.
    /// @param enabled                  Whether this selector is a Solana (SVM) lane.
    /// @param computeUnits             SVM compute-unit budget. MUST be 0: this adapter only performs
    ///                                 token-only SVM transfers (zero-word `receiver`, no destination
    ///                                 program), and the CCIP FeeQuoter rejects a non-zero compute-unit
    ///                                 budget when the receiver is the zero address.
    function setCcipSvmConfig(uint64 selector, bool enabled, uint32 computeUnits) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Token-only lanes require computeUnits == 0 (see param doc); reject at set time so the lane
        // cannot be configured into a state where every send/refund reverts inside CCIP fee quoting.
        if (enabled && computeUnits != 0) revert SvmComputeUnitsNotZero(computeUnits);
        // `allowOutOfOrderExecution` is forced true: SVM lanes require it and the FeeQuoter rejects false,
        // so it is never operator-settable (a false value would silently brick the lane).
        s_ccipSvm[selector] = CcipSvmConfig({ enabled: enabled, computeUnits: computeUnits, allowOutOfOrderExecution: true });
        emit CcipSvmConfigSet(selector, enabled, computeUnits, true);
    }

    /// @notice Pause inbound processing (emergency circuit breaker). While paused, {processInbound}
    ///         reverts, so new inbound deliveries are CAPTURED as recoverable failed messages (fail-safe)
    ///         instead of executing, and {retryFailedMessage} is blocked, so no permissionless path can
    ///         move tokens outbound over a route while paused. REFUNDS ALWAYS WORK: {refundToSource} /
    ///         {refundLocal} stay available while
    ///         paused so captured funds remain retrievable. Note the refund paths intentionally still
    ///         move tokens (back to the source sender / a handler-chosen local address); halting a
    ///         compromised ROUTE additionally requires disabling it or its destination allowlist entry.
    ///         Admin only.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Resume inbound processing. Admin only.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Recover native from the contract's reserve (the operator's gas float). This float includes
    ///         any LayerZero compose `value` that was delivered but not refunded — e.g. a message with no
    ///         {failedMessageHandler}, or one whose best-effort native refund failed (see
    ///         {_refundDeliveredValueSurplus}); such unrefunded prepay is treated as operator float by
    ///         design. Owner only. User / failed-message ERC-20 tokens are NEVER owner-recoverable.
    /// @param to     Recipient of the recovered native.
    /// @param amount Amount of native to recover.
    function recoverNative(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert NativeTransferFailed(to, amount);
        emit NativeRecovered(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              INTROSPECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice ERC-165 introspection (includes {IAccessControl} and CCIP receiver).
    /// @param interfaceId The ERC-165 interface id to query.
    /// @return supported Whether this contract implements `interfaceId`.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns the configured CCIP router (compatibility with CCIP tooling expectations).
    /// @return router The Chainlink CCIP router address.
    function getRouter() external view returns (address) {
        return s_ccipRouter;
    }

    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure virtual returns (string memory) {
        return "MultiChannelBridgeAdapter 1.0.0";
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Normalises a 32-byte CCIP `sender` (EVM `abi.encode(address)` or 32-byte non-EVM) to bytes32.
    /// @param b The ABI-encoded sender bytes (must be exactly 32 bytes).
    /// @return word The normalised 32-byte sender word.
    function _toBytes32(bytes memory b) internal pure returns (bytes32 word) {
        if (b.length != 32) revert InvalidSenderLength(b.length);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            word := mload(add(b, 32))
        }
    }
}
