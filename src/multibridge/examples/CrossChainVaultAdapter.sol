// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { MultiChannelBridgeAdapter } from "../MultiChannelBridgeAdapter.sol";
import { RouteRegistry } from "../routing/RouteRegistry.sol";

/**
 * @title CrossChainVaultAdapter
 * @notice Example **synchronous** ERC-4626 cross-chain app on {MultiChannelBridgeAdapter} +
 *         {RouteRegistry}. It accepts a single fixed vault's asset OR share token inbound over any rail,
 *         performs the matching vault action (asset in => deposit; share in => redeem) **in the same
 *         transaction**, and delivers the produced token to the destination + rail the user picked via the
 *         shared {RouteRegistry} (LayerZero OFT / CCIP / Stargate / CCIP-SVM / same-chain LOCAL).
 *
 *         The inbound {VaultMessage} is kept DELIBERATELY SMALL (important for size-constrained origins
 *         such as Solana): `minAmountOut`, a single `destination` route key, `recipient`,
 *         `failedMessageHandler`, and the `onlyLocalRefund` flag. Outbound gas is NOT in the message — it is operator config
 *         ({setDestinationGas}, default {DEFAULT_DST_GAS}). CCIP inbound return-leg funding uses
 *         destination-keyed inbound-token fees ({setInboundFee}); LayerZero inbound may prefund native.
 *
 * @dev Synchronous: the vault action and the outbound delivery happen in one transaction. Any failure —
 *      malformed message, unsupported token, slippage breach, or an outbound-leg revert — reverts the
 *      whole `_handleReceive`, so the vault action rolls back and the base captures the INBOUND token as a
 *      recoverable failed message (no operator involvement: permissionless `refundToSource`, or the
 *      message's `failedMessageHandler` may `retryFailedMessage` / `refundLocal`). Slippage is the user's
 *      per-transaction `minAmountOut`, enforced END-TO-END on the DELIVERED amount by {RouteRegistry}
 *      (measured for LOCAL/CCIP; the bridge's `minAmountLD` for OFT/Stargate); the produced amount is
 *      measured by balance delta (the ERC-4626 return value is not trusted). No decimals are assumed.
 */
contract CrossChainVaultAdapter is RouteRegistry {
    using SafeERC20 for IERC20;

    /// @notice Minimal, channel-agnostic application message carried in the inbound `data`.
    /// @param minAmountOut Slippage floor on the vault output (shares on deposit, assets on redeem).
    /// @param destination Outbound destination route key. When a {Route} is registered for
    ///        `(producedToken, destination)` it is authoritative (any rail, incl. `LOCAL` same-chain at
    ///        the `LOCAL_DESTINATION` = 0 sentinel). With no route it falls back to the legacy default: a
    ///        LayerZero EID if `<= type(uint32).max`, else a CCIP chain selector. Allowlisted per rail.
    /// @param recipient Beneficiary of the produced token (EVM address in the low 20 bytes for a CCIP/LOCAL
    ///        destination; peer bytes32 for a LayerZero/Stargate/SVM destination).
    /// @param failedMessageHandler Hub-side delegate: may `retryFailedMessage` / `refundLocal` on failure,
    ///        and receives any unused LZ return-leg prefund as native ETH (best-effort; must accept ETH).
    ///        `address(0)` => recovery is permissionless `refundToSource` only, and any unused prefund is
    ///        left in the adapter's native reserve.
    /// @param onlyLocalRefund Opt-in: when true AND a `failedMessageHandler` is set, the permissionless
    ///        `refundToSource` is blocked so ONLY the handler can recover the failure (via
    ///        `retryFailedMessage` / `refundLocal`) — preventing a third party from forcing an unwanted
    ///        bounce back to source. Ignored when `failedMessageHandler` is `address(0)` (no-freeze).
    struct VaultMessage {
        uint256 minAmountOut;
        uint64 destination;
        bytes32 recipient;
        address failedMessageHandler;
        bool onlyLocalRefund;
    }

    /// @notice The fixed ERC-4626 vault this app serves (set once in {initialize}).
    IERC4626 public s_vault;
    /// @notice The vault's underlying asset (its share token is the vault address itself).
    address public s_asset;

    /// @notice If true, a LayerZero-originated message MUST pre-pay its outbound return-leg fee via the
    ///         delivered compose `value` (the operator's reserve is never spent on LZ returns). CCIP
    ///         origins cannot deliver native, so they are unaffected and use the reserve.
    bool public s_requireLzReturnPrefunded;

    /// @notice Flat inbound-token fee for CCIP-originated messages that bridge the produced token to
    ///         `(outboundToken, destination)`. Fee is skimmed from the inbound token before the vault
    ///         action (asset on deposit, shares on redeem). Zero disables collection for that pair.
    ///         LayerZero inbound uses native prefund instead; LOCAL delivery skips the fee.
    mapping(address outboundToken => mapping(uint64 destination => uint256 fee)) public s_inboundFees;
    /// @notice Accrued inbound fees per token, withdrawable via {withdrawCollectedFee} by {FEE_COLLECTOR_ROLE}.
    mapping(address token => uint256 amount) public s_collectedFees;

    /// @notice The LayerZero return-leg prefund requirement was set to `required`.
    event ReturnPrefundRequirementSet(bool required);
    /// @notice Inbound fee for `(outboundToken, destination)` was set to `fee` (inbound token units).
    event InboundFeeSet(address indexed outboundToken, uint64 indexed destination, uint256 fee);
    /// @notice Inbound fee was skimmed during CCIP processing.
    event InboundFeeCollected(bytes32 indexed guid, address indexed inboundToken, uint256 fee);
    /// @notice Accrued fees were withdrawn to `recipient`.
    event CollectedFeeWithdrawn(address indexed token, address indexed recipient, uint256 amount);
    /// @notice A deposit/redeem produced `outAmount` of `outToken` and delivered it to `recipient` at
    ///         `destination` (`isDeposit` distinguishes the two flows).
    event VaultDelivered(bytes32 indexed guid, bool isDeposit, address outToken, uint256 outAmount, uint64 destination, bytes32 recipient);

    error UnexpectedTokenCount(uint256 count);
    error UnsupportedToken(address token);
    error ReturnFeeNotPrefunded(uint256 fee, uint256 delivered);
    error ReturnNotPrefunded();
    error InboundFeeExceedsAmount(uint256 amount, uint256 fee);
    error FeeWithdrawExceedsCollected(uint256 collected, uint256 requested);

    /// @notice Locks the implementation so it can only be used via clones (which initialize their
    ///         own storage). The published implementation itself can never be initialized.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes a clone. Callable once. The factory calls this atomically on a fresh clone.
    /// @param ccipRouter Chainlink CCIP router on this chain.
    /// @param lzEndpoint LayerZero EndpointV2 on this chain.
    /// @param initialOwner Receives {DEFAULT_ADMIN_ROLE}, {FEE_SETTER_ROLE}, and {FEE_COLLECTOR_ROLE} at init.
    /// @param vault The ERC-4626 vault to serve.
    function initialize(address ccipRouter, address lzEndpoint, address initialOwner, address vault) external initializer {
        if (vault == address(0)) revert ZeroAddress();
        __MultiChannelBridgeAdapter_init(ccipRouter, lzEndpoint, initialOwner);
        s_vault = IERC4626(vault);
        s_asset = IERC4626(vault).asset();
    }

    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure virtual override returns (string memory) {
        return "CrossChainVaultAdapter 1.0.0";
    }

    /// @inheritdoc MultiChannelBridgeAdapter
    /// @dev The handler is the `failedMessageHandler` field of the {VaultMessage}. A malformed payload
    ///      reverts the decode and is treated as "no handler" by the base (bounce-to-source only).
    /// @param data The inbound application payload (`VaultMessage` ABI-encoded).
    /// @return handler The designated failed-message handler, or `address(0)` if decode fails upstream.
    function failedMessageHandler(bytes calldata data) external pure virtual override returns (address) {
        return abi.decode(data, (VaultMessage)).failedMessageHandler;
    }

    /// @inheritdoc MultiChannelBridgeAdapter
    /// @dev Reads the `onlyLocalRefund` opt-in from the {VaultMessage}. A malformed payload reverts the
    ///      decode and is treated as `false` (permissionless bounce allowed) by the base.
    /// @param data The inbound application payload (`VaultMessage` ABI-encoded).
    /// @return Whether the message requires handler-only (local) recovery.
    function onlyLocalRefund(bytes calldata data) external pure virtual override returns (bool) {
        return abi.decode(data, (VaultMessage)).onlyLocalRefund;
    }

    /// @notice Operator toggles whether LayerZero-originated messages must pre-pay their return-leg fee
    ///         (via the delivered compose `value`). When on, an LZ message with no value is rejected
    ///         (captured for recovery); the reserve is never spent on LZ returns. CCIP origins are
    ///         unaffected (they cannot deliver native and always use the reserve).
    /// @param required Whether to require the pre-payment.
    function setRequireLzReturnPrefunded(bool required) external onlyRole(FEE_SETTER_ROLE) {
        s_requireLzReturnPrefunded = required;
        emit ReturnPrefundRequirementSet(required);
    }

    /// @notice Sets the flat inbound-token fee charged on CCIP-originated messages that bridge
    ///         `outboundToken` to `destination`. `fee` is in inbound token smallest units: underlying
    ///         asset on deposit (inbound asset → outbound shares), vault shares on redeem (inbound
    ///         shares → outbound asset). Zero clears the fee. LayerZero inbound is unaffected.
    /// @param outboundToken The produced token that will leave over a bridge leg (vault share on deposit,
    ///        underlying asset on redeem).
    /// @param destination The user-facing route key from the inbound {VaultMessage}.
    /// @param fee Flat fee skimmed from the inbound token before the vault action.
    function setInboundFee(address outboundToken, uint64 destination, uint256 fee) external onlyRole(FEE_SETTER_ROLE) {
        s_inboundFees[outboundToken][destination] = fee;
        emit InboundFeeSet(outboundToken, destination, fee);
    }

    /// @notice Withdraws accrued inbound fees tracked in {s_collectedFees}.
    /// @param token The fee token to withdraw.
    /// @param recipient Recipient of the withdrawn fees.
    /// @param amount Amount to withdraw.
    function withdrawCollectedFee(address token, address recipient, uint256 amount) external onlyRole(FEE_COLLECTOR_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        uint256 collected = s_collectedFees[token];
        if (amount > collected) revert FeeWithdrawExceedsCollected(collected, amount);
        unchecked {
            s_collectedFees[token] = collected - amount;
        }
        IERC20(token).safeTransfer(recipient, amount);
        emit CollectedFeeWithdrawn(token, recipient, amount);
    }

    // slither reentrancy detectors flag the balance-delta measurement + post-delivery `fee` check, but the
    // entire inbound path is non-reentrant: it runs only via the base's `ccipReceive` / `lzCompose` (both
    // `nonReentrant`) through the `onlySelf` `processInbound` self-call, so no external party can re-enter.
    // slither-disable-start reentrancy-balance,reentrancy-no-eth,reentrancy-events,reentrancy-benign

    /// @inheritdoc MultiChannelBridgeAdapter
    /// @dev Synchronously routes the inbound token through the matching vault action and delivers the
    ///      produced token to `message.destination`. Any failure reverts and is captured by the base for
    ///      no-operator recovery (the vault action rolls back atomically).
    function _handleReceive(Inbound calldata inbound) internal override {
        if (inbound.tokens.length != 1) revert UnexpectedTokenCount(inbound.tokens.length);

        VaultMessage memory message = abi.decode(inbound.data, (VaultMessage)); // malformed -> base captures
        address inToken = inbound.tokens[0].token;
        uint256 inAmount = inbound.tokens[0].amount;

        bool isDeposit = inToken == s_asset;
        if (!isDeposit && inToken != address(s_vault)) revert UnsupportedToken(inToken); // -> base captures

        address outToken = isDeposit ? address(s_vault) : s_asset;
        uint256 netInAmount = _skimInboundFee(inbound, inToken, outToken, message.destination, inAmount);

        uint256 outAmount = isDeposit ? _deposit(netInAmount) : _redeem(netInAmount);
        // `minAmountOut` is enforced END-TO-END on the DELIVERED amount by _deliver/_routeOut — a measured
        // check for LOCAL/CCIP and the bridge's `minAmountLD` for OFT/Stargate. A breach reverts and the
        // base captures the inbound token for recovery. (Enforcing on the measured/delivered amount rather
        // than a pre-action `preview*` also closes the sync-vs-measured gap.)
        (uint256 fee, bool bridged) =
            _deliver(inbound.guid, isDeposit, outToken, outAmount, message.minAmountOut, message.destination, message.recipient);

        // Native-fee policy for the outbound return leg:
        //  - If the message delivered native (a LayerZero compose `value`), it MUST cover the fee — the
        //    reserve is left untouched and the base returns any surplus to the sender. (LOCAL delivery has
        //    fee 0, so any delivered value is fully returned.)
        //  - Otherwise the reserve funds the return, unless prefunding is required for LZ origins. A LOCAL
        //    (no-bridge) delivery has no return leg, so the prefund requirement does not apply to it.
        if (msg.value > 0) {
            if (fee > msg.value) revert ReturnFeeNotPrefunded(fee, msg.value);
        } else if (bridged && s_requireLzReturnPrefunded && inbound.channel == Channel.LayerZero) {
            revert ReturnNotPrefunded();
        }
    }

    // slither-disable-end reentrancy-balance,reentrancy-no-eth,reentrancy-events,reentrancy-benign

    /// @dev Deposits `amount` of the asset into the vault, measuring minted shares by balance delta. The
    ///      produced token is always the vault share (`address(s_vault)`), known by the caller.
    /// @param amount The asset amount.
    /// @return outAmount The shares minted to this contract.
    function _deposit(uint256 amount) internal returns (uint256 outAmount) {
        IERC20(s_asset).forceApprove(address(s_vault), amount);
        uint256 balanceBefore = s_vault.balanceOf(address(this));
        s_vault.deposit(amount, address(this));
        IERC20(s_asset).forceApprove(address(s_vault), 0); // reset the allowance (matches the base send convention)
        outAmount = s_vault.balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Redeems `amount` shares from the vault, measuring assets received by balance delta. The
    ///      produced token is always the underlying asset (`s_asset`), known by the caller. No approval is
    ///      needed: the adapter is both `owner` and caller of `redeem`.
    /// @param amount The share amount.
    /// @return outAmount The assets received by this contract.
    function _redeem(uint256 amount) internal returns (uint256 outAmount) {
        uint256 balanceBefore = IERC20(s_asset).balanceOf(address(this));
        s_vault.redeem(amount, address(this), address(this));
        outAmount = IERC20(s_asset).balanceOf(address(this)) - balanceBefore;
    }

    /// @dev Delivers the produced token via the {RouteRegistry} and emits {VaultDelivered}.
    /// @param guid The inbound message id (for the event).
    /// @param isDeposit Whether this was a deposit (for the event).
    /// @param token The produced token to deliver.
    /// @param amount The produced amount.
    /// @param minAmountOut The user's end-to-end floor on the delivered amount (see {RouteRegistry._routeOut}).
    /// @param destination The destination route key (`0`/LOCAL = same-chain).
    /// @param recipient The beneficiary.
    /// @return fee The native fee paid for the outbound send (0 for a LOCAL delivery).
    /// @return bridged Whether the delivery left this chain over a rail (false for LOCAL same-chain).
    function _deliver(
        bytes32 guid,
        bool isDeposit,
        address token,
        uint256 amount,
        uint256 minAmountOut,
        uint64 destination,
        bytes32 recipient
    )
        internal
        returns (uint256 fee, bool bridged)
    {
        (fee, bridged) = _routeOut(token, amount, minAmountOut, destination, recipient);
        emit VaultDelivered(guid, isDeposit, token, amount, destination, recipient);
    }

    /// @dev Skims a configured inbound-token fee on CCIP-originated bridged deliveries.
    /// @param inbound The normalised inbound delivery.
    /// @param inboundToken The token delivered inbound (asset or vault shares).
    /// @param outboundToken The produced token that will leave over a bridge leg.
    /// @param destination The user-facing outbound route key.
    /// @param amount The gross inbound token amount before skim.
    /// @return netAmount The inbound amount after fee skim (unchanged when fee is zero or N/A).
    function _skimInboundFee(
        Inbound calldata inbound,
        address inboundToken,
        address outboundToken,
        uint64 destination,
        uint256 amount
    )
        internal
        returns (uint256 netAmount)
    {
        if (inbound.channel != Channel.CCIP) return amount;
        Route storage route = s_route[outboundToken][destination];
        // Locality matches {_routeOut}'s semantics exactly: a delivery is LOCAL (fee-exempt) only via an
        // explicitly enabled Rail.LOCAL route. An unset route at the `0` sentinel is NOT treated as
        // local — {_routeOut} rejects it (LocalDestinationRequiresRoute) rather than delivering locally.
        bool isLocal = route.enabled && route.rail == Rail.LOCAL;
        if (isLocal) return amount;

        uint256 fee = s_inboundFees[outboundToken][destination];
        if (fee == 0) return amount;
        if (amount <= fee) revert InboundFeeExceedsAmount(amount, fee);

        netAmount = amount - fee; // safe: `amount > fee` enforced by the check above
        s_collectedFees[inboundToken] += fee;
        emit InboundFeeCollected(inbound.guid, inboundToken, fee);
    }
}
