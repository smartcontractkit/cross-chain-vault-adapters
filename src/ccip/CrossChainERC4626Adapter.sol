// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts@5.0.2/access/extensions/AccessControlEnumerable.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts@5.0.2/interfaces/IERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts@5.0.2/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/utils/SafeERC20.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";

/// @title CrossChainERC4626Adapter
/// @notice Chainlink CCIP adapter enabling cross-chain ERC-4626 vault interactions: users on any
/// supported source chain can deposit into and redeem from compatible vault contracts, with proceeds
/// either bridged back to the source chain or delivered to a local beneficiary.
///
/// Compatibility requirements:
/// - CCIP must be enabled for both the vault share token and the deposit asset.
/// - The target vault must comply with the standard ERC-4626 interface (synchronous, single-asset).
/// - Standard ERC-20 operation is assumed for both tokens; non-standard dynamics such as
///   fee-on-transfer, rebasing, or other exotic transfer semantics are not explicitly supported.
///
/// Deployment:
/// - If a target vault is compatible as-is, simply deploy this adapter via the Factory.
/// - If a custom implementation is required, clone and modify the provided repo. Common forking
///   changes include async deposit/redeem flows, multi-asset or bespoke vaults, non-ERC-4626
///   target contracts, custom payload encoding/dispatch, and custom source/sender/beneficiary
///   validation. When forking, preserve the safety rails: router validation in `ccipReceive`,
///   self-call isolation, failed-message persistence and recovery, and address conversion checks.
///
/// @custom:security-contact https://chain.link/security
contract CrossChainERC4626Adapter is IAny2EVMMessageReceiverV2, AccessControlEnumerable, ReentrancyGuard, ITypeAndVersion {
    ////////////////////////////////////////////////////////////////////////////
    // CORE TYPES
    // These types and helper directives define supported destination families,
    // failed-message states, and basic token-handling ergonomics.
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20 for IERC20;
    bytes32 public constant FEE_SETTER_ROLE = keccak256("FEE_SETTER_ROLE");
    bytes32 public constant FEE_COLLECTOR_ROLE = keccak256("FEE_COLLECTOR_ROLE");
    /// @inheritdoc ITypeAndVersion
    string public constant override typeAndVersion = "CrossChainERC4626Adapter 1.0.0";

    enum ChainType {
        NONE,
        EVM,
        SVM
    }

    /// @notice How outbound EVM return/refund messages encode `Client.EVM2AnyMessage.extraArgs`. LEGACY_EXTRA_ARGS_V2 is for CCIP V1, and GENERIC_EXTRA_ARGS_V3_BASIC is for CCIP V2.
    /// @dev Per `destinationChainSelector` (return lane). Stored `UNSET` cannot be written via `setEvmReturnLaneFormat`; on outbound encode, `UNSET` resolves to `LEGACY_EXTRA_ARGS_V2`.
    enum EvmReturnExtraArgsFormat {
        UNSET,
        LEGACY_EXTRA_ARGS_V2,
        GENERIC_EXTRA_ARGS_V3_BASIC
    }

    enum ErrorCode {
        NONE,
        BASIC,
        RESOLVED
    }

    /// @notice Inbound `message.data` for every configured source chain family (EVM and SVM).
    /// @dev `abi.encode` length must be exactly `CCIP_MESSAGE_PAYLOAD_LENGTH` (128 bytes). `deliveryAndRefund` packs delivery/refund options as `(uint160(localRefundAddress) << 1) | (returnToSourceChain ? 1 : 0)`; bits 161..255 are ignored on decode.
    /// @dev WARNING: if `localRefundAddress` (bits 1..160 of `deliveryAndRefund`) is left as `address(0)`, or if the payload is malformed so that it cannot be decoded into a valid 128-byte `Payload` at failure time, the stored `localRefundAddress` stays zero and `recoverFailedMessageLocally` is unavailable. Combined with a failed or unavailable cross-chain refund, this can leave inbound tokens PERMANENTLY STUCK in the adapter with no recovery path. Callers MUST validate the message—correct payload length, encoding, and a non-zero `localRefundAddress`—BEFORE initiating the cross-chain transaction; once funds are bridged a bad payload cannot be corrected.
    struct Payload {
        address target; // target contract to interact with
        bytes32 beneficiary; // recipient of proceeds from target contract interaction
        uint256 minimumOut; // Minimum acceptable output amount in base units produced by `_processTarget`. On deposit, output is vault shares; on redeem, underlying. Compared after the adapter flat `assetFees` skim on that path; when bit 0 of `deliveryAndRefund` is set (`returnToSourceChain`), the post-skim `outputAmount` must meet this bound before bridging. Does not model fee-on-transfer, rebasing, donation or inflation quirks, or other non-standard ERC-20 behavior—operators must not rely on it as slippage protection for those tokens without a forked implementation.
        uint256 deliveryAndRefund; // bit 0: returnToSourceChain; bits 1..160: localRefundAddress on this chain (address(0) disables local recovery)
    }

    /// @notice Refund-relevant fields from a failed inbound CCIP message.
    /// @dev Stored instead of the full `Client.Any2EVMMessage` so refund and fee-quote paths do not copy unused dynamic fields such as `message.data`. `localRefundAddress` is decoded from a valid 128-byte payload at failure time; otherwise it remains zero.
    struct FailedMessageRecord {
        uint64 sourceChainSelector;
        bytes sender;
        Client.EVMTokenAmount[] destTokenAmounts;
        address localRefundAddress;
    }

    uint256 public constant CCIP_MESSAGE_PAYLOAD_LENGTH = 128;

    ////////////////////////////////////////////////////////////////////////////
    // CORE STATE
    // This section tracks router configuration, enabled target contracts, failed message
    // records, fee configuration, and refund metadata.
    //
    // When forking:
    // - add customer-specific state here
    // - preserve the meaning of the existing state unless the related flows are
    //   intentionally redesigned
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Local Chainlink CCIP `IRouterClient` authorized to invoke `ccipReceive` (`onlyRouter`).
    /// @dev Immutable; configured once in the constructor as `ROUTER`. Get from CCIP Directory.
    address public immutable ROUTER;

    /// @notice CCIP V2 receiver CCV policy keyed by inbound `message.sourceChainSelector`.
    struct CCVConfig {
        address[] requiredCCVs;
        address[] optionalCCVs;
        uint8 optionalThreshold;
    }

    /// @notice When true, the deposit path (underlying to vault shares) may execute in `_processTarget`.
    bool public depositsEnabled;

    /// @notice When true, the redeem path (vault shares to underlying) may execute in `_processTarget`.
    bool public redeemsEnabled;

    /// @notice CCIP V2 CCV verifier lists and optional threshold per inbound source chain selector.
    mapping(uint64 sourceChainSelector => CCVConfig config) internal ccvConfigs;

    /// @notice CCIP V2 allowed inbound message finality.  Exposed through required `getCCVsAndFinalityConfig` function for CCIP V2 compatibility. See "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol"
    mapping(uint64 sourceChainSelector => bytes4 allowedFinalityConfig) public inboundFinality;

    /// @notice CCIP chain selector to remote chain family (EVM or SVM). `NONE` means the selector is not configured.
    /// Inbound: a nonzero type is required in `processMessage` for `message.sourceChainSelector` (`onlyValidChain`).
    /// Outbound: `sendToken` uses `chains[...]` for EVM vs SVM encoding when `encodingOverride == NONE`; if the effective family is still `NONE`, `_buildOutboundMessage` reverts `InvalidChain`—keep selectors configured for return legs; refunds use `refundChainFamilySnapshot` / sender inference when applicable.
    mapping(uint64 chainSelector => ChainType chainType) public chains;
    /// @notice Allowlist of addresses that may appear as the payload vault `target` (`Payload.target`; typically ERC-4626 vaults).
    mapping(address target => bool isEnabled) public enabledTargets;
    /// @notice Return-leg flat fee keyed by `(destinationChainSelector, bridgedOutputToken)`; amount is always in `IERC4626(vault).asset()` smallest units (deposit-return: key = vault share token; redeem-return: key = underlying).
    mapping(uint64 destinationChainSelector => mapping(address bridgedToken => uint256 fee)) public assetFees;
    /// @notice Accrued fee balance per asset, increased when fees are taken from users and decreased when withdrawn by `FEE_COLLECTOR_ROLE`.
    mapping(address asset => uint256 amount) public collectedFees;
    /// @notice Refund-relevant inbound fields stored only while `messageErrorCode[messageId] == BASIC` (set in `ccipReceive` on caught `processMessage` failure).
    mapping(bytes32 messageId => FailedMessageRecord record) internal failedMessageRecords;
    /// @notice Snapshot of the outbound encoding family when `processMessage` fails (set in `ccipReceive` catch).
    mapping(bytes32 messageId => ChainType) public refundChainFamilySnapshot;
    /// @notice Per-message processing outcome: `NONE` by default; `BASIC` after a caught failure in `processMessage` (refund paths available); `RESOLVED` after `refundFailedMessage` or `recoverFailedMessageLocally` records the message as handled.
    mapping(bytes32 messageId => ErrorCode errorCode) public messageErrorCode;
    /// @notice Outbound EVM `extraArgs` wire format per return `destinationChainSelector` (lane OnRamp capability).
    mapping(uint64 destinationChainSelector => EvmReturnExtraArgsFormat format) public evmReturnExtraArgsFormat;
    /// @notice When resolved format is `GENERIC_EXTRA_ARGS_V3_BASIC`, `requestedFinality` for `ExtraArgsCodec._getBasicEncodedExtraArgsV3` (with `gasLimit` 0).
    mapping(uint64 destinationChainSelector => mapping(address token => bytes4 requestedFinality))
        public evmReturnRequestedFinality;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    // These custom errors are part of the contract's operational surface and
    // should stay readable for both human operators and coding agents.
    ////////////////////////////////////////////////////////////////////////////

    error InvalidRouter(address router);
    error InvalidAdmin();
    error InvalidFeeSetter();
    error InvalidFeeCollector();
    error InvalidRecipient();
    error InvalidChain(uint64 chainSelector);
    error OnlySelf();
    error AmountIsZero();
    error InvalidEVMAddress(bytes32 beneficiary);
    error InvalidSenderAddressFormat();
    error InsufficientNativeBalance(uint256 requiredFee, uint256 availableBalance);
    error InsufficientRecoveryFee(uint256 requiredFee, uint256 providedFee);
    /// @dev Used by `withdrawFee` when `amount > collectedFees[asset]`. If accounting and the token balance diverge, `safeTransfer` can revert with the token implementation's error instead.
    error InsufficientFeeBalance(uint256 availableBalance, uint256 requestedAmount);
    error MessageNotFailed(bytes32 messageId);
    error InvalidTarget(address target);
    error InvalidTargetToken(address target, address token);
    error InvalidTokenCount(uint256 tokenCount);
    error InvalidPayloadLength(uint256 length, uint256 expected);
    error FeeConfigLengthMismatch();
    error InvalidEvmReturnExtraArgsFormat();
    error UnexpectedRequestedFinalityForLegacyFormat(bytes4 requestedFinalityForV3);
    error InvalidOptionalThreshold(uint8 optionalThreshold, uint256 optionalCCVCount);
    error OptionalCCVsRequirePositiveThreshold(uint256 optionalCCVCount);
    error DuplicateCCV(address ccv);
    error InvalidOptionalCCV();
    error DepositsDisabled();
    error RedeemsDisabled();
    error FeeExceedsAmount(uint256 amount, uint256 fee);
    error MinimumOutputNotMet(uint256 minimumOut, uint256 actualOut);
    error NoOutputReceived();
    error RefundFailed();
    error RecoverNativeFailed();
    error NoRefundableTokenAmounts();
    error NoLocalRefundAddress(bytes32 messageId);
    error UnauthorizedLocalRefund(address caller, address localRefundAddress);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    // These events expose outbound sends, inbound processing results, and manual
    // recovery operations for observability and operational tooling.
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Emitted after a successful outbound CCIP token send (`IRouterClient.ccipSend` via `sendToken`).
    /// @dev Carries the quoted native `fee`, destination selector, encoded beneficiary, and bridged `amount`.
    /// `chainType` is the effective wire family used for this send: return legs follow live `chains[destinationChainSelector]` (or would revert if unset); refund legs follow `refundChainFamilySnapshot` / `_refundOutboundEncodingFamily` (effective family, not necessarily live `chains[source]` after admin edits).
    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        ChainType indexed chainType,
        bytes32 beneficiary,
        address token,
        uint256 amount,
        uint256 fee
    );

    /// @notice Emitted when `processMessage` finishes successfully for `messageId`.
    event MessageSucceeded(bytes32 indexed messageId);

    /// @notice Emitted when `processMessage` reverts inside `ccipReceive` try/catch.
    event MessageFailed(bytes32 indexed messageId);

    /// @notice Emitted when `refundFailedMessage` returns stuck tokens to the normalized original sender on the source chain.
    event MessageRefunded(
        bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary
    );

    /// @notice Emitted when `recoverFailedMessageLocally` transfers inbound tokens to `localRefundAddress` on this chain.
    event MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress);

    /// @notice Emitted after `_processTarget` completes the ERC-4626 interaction (input/output tokens and amounts).
    event TargetProcessed(
        bytes32 indexed messageId,
        address indexed target,
        address indexed inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount
    );

    /// @notice Emitted when an admin updates whether a vault `target` is allowlisted.
    event TargetEnabled(address indexed target, bool enabled);
    /// @notice Emitted when an admin configures a CCIP chain selector as EVM, SVM, or none.
    event ChainTypeSet(uint64 indexed chainSelector, ChainType chainType);

    /// @notice Emitted when global deposit/redeem toggles change via `setProcessingEnabled`.
    event ProcessingEnabledSet(bool depositsEnabled, bool redeemsEnabled);
    /// @notice Emitted when the flat protocol fee for a destination/bridged-token pair is updated via `setAssetFee` / `setAssetFees`.
    /// @dev `bridgedToken` is the token bridged back on that leg (vault share on deposit-return, underlying on redeem-return); `fee` is always in vault underlying smallest units.
    event AssetFeeSet(uint64 indexed destinationChainSelector, address indexed bridgedToken, uint256 fee);
    /// @notice Emitted after `setCCVsConfig` updates CCIP V2 CCV lists and optional threshold for `sourceChainSelector`.
    event CCVsConfigSet(
        uint64 indexed sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold
    );

    /// @notice Emitted when an admin configures inbound advertised finality policy for messages from `sourceChainSelector`.
    /// @param sourceChainSelector Remote chain whose inbound messages carry this advertised `allowedFinalityConfig`.
    /// @param allowedFinalityConfig Bitmask surfaced by `getCCVsAndFinalityConfig` for that source (see Chainlink `FinalityCodec`).
    event InboundFinalitySet(uint64 indexed sourceChainSelector, bytes4 allowedFinalityConfig);

    /// @notice Emitted when an admin sets the outbound EVM return-leg `extraArgs` format for a destination lane.
    event EvmReturnLaneFormatSet(uint64 indexed destinationChainSelector, EvmReturnExtraArgsFormat format);

    /// @notice Emitted when an admin sets return-leg `requestedFinality` for `(destinationChainSelector, token)`.
    event EvmReturnRequestedFinalitySet(
        uint64 indexed destinationChainSelector, address indexed token, bytes4 requestedFinalityForV3
    );

    /// @notice Emitted when `withdrawFee` transfers accrued `collectedFees` to `recipient`.
    event FeeWithdrawn(address indexed asset, address indexed recipient, uint256 amount);

    /// @notice Emitted when `recoverNative` pays native balance to `recipient`.
    event NativeRecovered(address indexed recipient, uint256 amount);

    /// @notice Emitted on the local settlement branch when output tokens are delivered to an on-chain beneficiary.
    event LocalTokenDelivered(
        bytes32 indexed messageId, address indexed token, address indexed beneficiary, uint256 amount
    );

    ////////////////////////////////////////////////////////////////////////////
    // ACCESS AND SAFETY MODIFIERS
    // These modifiers are part of the contract's defensive rails.
    // In most downstream implementations, these should be preserved as-is.
    ////////////////////////////////////////////////////////////////////////////

    modifier onlyRouter() {
        if (msg.sender != ROUTER) revert InvalidRouter(msg.sender);
        _;
    }

    modifier onlyValidChain(uint64 chainSelector) {
        if (chains[chainSelector] == ChainType.NONE) revert InvalidChain(chainSelector);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    ////////////////////////////////////////////////////////////////////////////
    // CONSTRUCTION AND INTERFACE SUPPORT
    // This section wires in the router dependency and exposes standard interface
    // discovery used by external integrations.
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Deploy the adapter with its router and initial operator roles.
    /// @param router_ CCIP router allowed to deliver inbound messages.
    /// @param defaultAdmin Address that receives the default admin role.
    /// @param feeSetter Address allowed to configure per-asset fees.
    /// @param feeCollector Address allowed to withdraw collected fees.
    constructor(address router_, address defaultAdmin, address feeSetter, address feeCollector) {
        if (router_ == address(0)) revert InvalidRouter(address(0));
        if (defaultAdmin == address(0)) revert InvalidAdmin();
        if (feeSetter == address(0)) revert InvalidFeeSetter();
        if (feeCollector == address(0)) revert InvalidFeeCollector();
        ROUTER = router_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(FEE_SETTER_ROLE, defaultAdmin);
        _grantRole(FEE_COLLECTOR_ROLE, defaultAdmin);
        if (feeSetter != defaultAdmin) _grantRole(FEE_SETTER_ROLE, feeSetter);
        if (feeCollector != defaultAdmin) _grantRole(FEE_COLLECTOR_ROLE, feeCollector);
    }

    /// @notice Accept native gas tokens used to pay outbound CCIP fees.
    receive() external payable {}

    /// @notice ERC-165 introspection for CCIP receiver interfaces, `IAccessControlEnumerable`, and the `IERC165` chain.
    /// @dev Delegates to `super` so enumerable access control (and thus `IERC165`) are reported correctly.
    /// @param interfaceId Interface selector to query.
    /// @return supported True when this contract or its parents support `interfaceId`.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlEnumerable)
        returns (bool supported)
    {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiverV2).interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////////
    // ADMIN CONFIGURATION
    // This section defines the operator-managed configuration surface.
    //
    // When forking:
    // - add additional config setters here
    // - add allowlists, routing rules, or policy parameters here
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Set V2 vs V3-basic `extraArgs` wire format for all EVM return/refund sends to `destinationChainSelector`.
    /// @dev `UNSET` is rejected; unset storage encodes as legacy V2. Use `setEvmReturnRequestedFinality` per bridged token when the lane is V3.
    /// @param destinationChainSelector CCIP chain selector for the outbound return/refund destination (inbound message `sourceChainSelector` when bridging back).
    /// @param format `LEGACY_EXTRA_ARGS_V2` or `GENERIC_EXTRA_ARGS_V3_BASIC`; `UNSET` reverts (`InvalidEvmReturnExtraArgsFormat`).
    function setEvmReturnLaneFormat(uint64 destinationChainSelector, EvmReturnExtraArgsFormat format)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (format == EvmReturnExtraArgsFormat.UNSET) revert InvalidEvmReturnExtraArgsFormat();
        evmReturnExtraArgsFormat[destinationChainSelector] = format;
        emit EvmReturnLaneFormatSet(destinationChainSelector, format);
    }

    /// @notice Set `requestedFinality` for return/refund sends bridging `token` back to `destinationChainSelector`.
    /// @dev Only meaningful when the lane format resolves to `GENERIC_EXTRA_ARGS_V3_BASIC`; legacy lanes ignore stored finality on encode.
    /// @param destinationChainSelector CCIP chain selector for the outbound return/refund destination (inbound message `sourceChainSelector` when bridging back).
    /// @param token Bridged ERC-20 on that return leg (vault share on deposit-return, underlying on redeem-return); must not be `address(0)`.
    /// @param requestedFinalityForV3 `requestedFinality` passed to `ExtraArgsCodec._getBasicEncodedExtraArgsV3` when the lane format is V3; use `bytes4(0)` on legacy lanes to clear stored finality.
    function setEvmReturnRequestedFinality(
        uint64 destinationChainSelector,
        address token,
        bytes4 requestedFinalityForV3
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert InvalidTarget(address(0));
        if (_resolvedEvmReturnFormat(destinationChainSelector) != EvmReturnExtraArgsFormat.GENERIC_EXTRA_ARGS_V3_BASIC) {
            if (requestedFinalityForV3 != bytes4(0)) {
                revert UnexpectedRequestedFinalityForLegacyFormat(requestedFinalityForV3);
            }
            delete evmReturnRequestedFinality[destinationChainSelector][token];
            emit EvmReturnRequestedFinalitySet(destinationChainSelector, token, bytes4(0));
            return;
        }
        FinalityCodec._validateRequestedFinality(requestedFinalityForV3);
        evmReturnRequestedFinality[destinationChainSelector][token] = requestedFinalityForV3;
        emit EvmReturnRequestedFinalitySet(destinationChainSelector, token, requestedFinalityForV3);
    }

    /// @notice Configure how a remote chain selector should be treated by the adapter.
    /// @param chainSelector CCIP chain selector to configure.
    /// @param chainType Whether that selector is EVM, SVM, or disabled.
    function setChainType(uint64 chainSelector, ChainType chainType) external onlyRole(DEFAULT_ADMIN_ROLE) {
        chains[chainSelector] = chainType;
        emit ChainTypeSet(chainSelector, chainType);
    }

    /// @notice Enable or disable an ERC-4626 target vault (`Payload.target`).
    /// @dev Only enable vaults backed by ordinary ERC-20 underlyings and standard ERC-20 share tokens (no fee-on-transfer, no rebasing).
    /// This adapter assumes transfer amounts match balance deltas when skimming `assetFees` into `collectedFees`; FoT/deflation breaks that
    /// accounting and `minimumOut` does not compensate—it gates nominal share/underlying outputs from preview/deposit redeem paths only.
    /// @param target Vault address that may be called during message processing.
    /// @param enabled Whether the target is allowed.
    function setTargetEnabled(address target, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) revert InvalidTarget(target);
        enabledTargets[target] = enabled;
        emit TargetEnabled(target, enabled);
    }

    /// @notice Toggle whether deposit and redeem flows are allowed.
    /// @param depositsEnabled_ Whether inbound asset deposits are allowed.
    /// @param redeemsEnabled_ Whether inbound share redemptions are allowed.
    function setProcessingEnabled(bool depositsEnabled_, bool redeemsEnabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        depositsEnabled = depositsEnabled_;
        redeemsEnabled = redeemsEnabled_;
        emit ProcessingEnabledSet(depositsEnabled_, redeemsEnabled_);
    }

    /// @notice Set the return-leg flat fee for a bridged output token on `destinationChainSelector`.
    /// @dev Fees may be staged before `setChainType` enables the selector. `fee` is always in the vault underlying's smallest units; collection skims underlying on both paths.
    /// @param destinationChainSelector CCIP selector for the chain where the outbound return send is priced (the inbound message's source).
    /// @param bridgedToken Token bridged back on that leg (vault share on deposit-return, underlying on redeem-return).
    /// @param fee Amount in `IERC4626(vault).asset()` smallest units; applied only when `returnToSourceChain` is true.
    function setAssetFee(uint64 destinationChainSelector, address bridgedToken, uint256 fee)
        external
        onlyRole(FEE_SETTER_ROLE)
    {
        if (bridgedToken == address(0)) revert InvalidTarget(address(0));
        assetFees[destinationChainSelector][bridgedToken] = fee;
        emit AssetFeeSet(destinationChainSelector, bridgedToken, fee);
    }

    /// @notice Batch-set return-leg fees; each index `i` mirrors one `setAssetFee` call with the same validations.
    /// @param destinationChainSelectors Outbound CCIP selector per row (fees may be staged before the selector is enabled in `chains`).
    /// @param bridgedTokens Bridged output token per row (`address(0)` is rejected).
    /// @param fees Fee amount per row (vault underlying smallest units).
    function setAssetFees(
        uint64[] calldata destinationChainSelectors,
        address[] calldata bridgedTokens,
        uint256[] calldata fees
    ) external onlyRole(FEE_SETTER_ROLE) {
        uint256 n = destinationChainSelectors.length;
        if (n != bridgedTokens.length || n != fees.length) revert FeeConfigLengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            address bridgedToken = bridgedTokens[i];
            if (bridgedToken == address(0)) revert InvalidTarget(address(0));
            uint64 selector = destinationChainSelectors[i];
            assetFees[selector][bridgedToken] = fees[i];
            emit AssetFeeSet(selector, bridgedToken, fees[i]);
        }
    }

    /// @notice Store CCIP V2 CCV verifier lists for `sourceChainSelector`, surfaced by `getCCVsAndFinalityConfig`. Only use if CCIP V2 activated.
    /// @param sourceChainSelector Inbound `message.sourceChainSelector` whose receiver CCV policy is being configured.
    /// @param requiredCCVs CCVs that must always attest.
    /// @param optionalCCVs CCVs that may attest.
    /// @param optionalThreshold_ Minimum number of optional CCVs that must pass verification (must not exceed `optionalCCVs.length`; must be positive when `optionalCCVs` is non-empty).
    function setCCVsConfig(
        uint64 sourceChainSelector,
        address[] calldata requiredCCVs,
        address[] calldata optionalCCVs,
        uint8 optionalThreshold_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (optionalCCVs.length > 0 && optionalThreshold_ == 0) {
            revert OptionalCCVsRequirePositiveThreshold(optionalCCVs.length);
        }
        if (optionalThreshold_ > optionalCCVs.length) {
            revert InvalidOptionalThreshold(optionalThreshold_, optionalCCVs.length);
        }
        _requireUniqueCCVs(requiredCCVs, optionalCCVs);
        CCVConfig storage config = ccvConfigs[sourceChainSelector];
        config.requiredCCVs = requiredCCVs;
        config.optionalCCVs = optionalCCVs;
        config.optionalThreshold = optionalThreshold_;

        emit CCVsConfigSet(sourceChainSelector, requiredCCVs, optionalCCVs, optionalThreshold_);
    }

    /// @notice Configure `inboundFinality[sourceChainSelector]`: advertised `allowedFinalityConfig` for inbound messages originating on `sourceChainSelector`. Only use if CCIP V2 activated.
    /// @param sourceChainSelector Remote chain delivering CCIP messages to this adapter (`message.sourceChainSelector`).
    /// @param allowedFinalityConfig Finality bitmask for that inbound direction (Chainlink `FinalityCodec`).
    function setInboundFinality(uint64 sourceChainSelector, bytes4 allowedFinalityConfig)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        inboundFinality[sourceChainSelector] = allowedFinalityConfig;
        emit InboundFinalitySet(sourceChainSelector, allowedFinalityConfig);
    }

    /// @notice Withdraw accumulated fees for an asset (tracked in `collectedFees`).
    /// @dev Reverts `InsufficientFeeBalance` when `amount > collectedFees[asset]`. The transfer uses `safeTransfer`; if the contract holds less of `asset` than `amount` while accounting still allows the withdrawal, expect a revert from the ERC-20 (not `InsufficientFeeBalance`).
    /// @param asset Asset token to withdraw.
    /// @param recipient Recipient of the withdrawn fees.
    /// @param amount Amount of fees to withdraw.
    function withdrawFee(address asset, address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(FEE_COLLECTOR_ROLE)
    {
        if (recipient == address(0)) revert InvalidRecipient();
        if (amount == 0) revert AmountIsZero();
        uint256 collected = collectedFees[asset];
        if (amount > collected) revert InsufficientFeeBalance(collected, amount);

        unchecked {
            collectedFees[asset] = collected - amount;
        }
        IERC20(asset).safeTransfer(recipient, amount);
        emit FeeWithdrawn(asset, recipient, amount);
    }

    /// @notice Recover the contract's native token balance.
    /// @param recipient Recipient of the recovered native balance.
    function recoverNative(address recipient) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert InvalidRecipient();
        uint256 balance = address(this).balance;
        if (balance == 0) revert AmountIsZero();
        (bool success,) = recipient.call{value: balance}("");
        if (!success) revert RecoverNativeFailed();
        emit NativeRecovered(recipient, balance);
    }

    /// @notice Return the stored refund-relevant fields for a failed message, including `destTokenAmounts`.
    /// @dev Written when `messageErrorCode[messageId] == BASIC`; otherwise fields may be zeroed or stale. Omits unused CCIP envelope fields (`messageId`, `data`).
    /// @param messageId Identifier of the failed inbound message.
    /// @return record Minimal snapshot: `sourceChainSelector`, `sender`, `destTokenAmounts`, and `localRefundAddress`.
    function getFailedMessageRecord(bytes32 messageId) external view returns (FailedMessageRecord memory record) {
        return failedMessageRecords[messageId];
    }

    ////////////////////////////////////////////////////////////////////////////
    // INBOUND MESSAGE FLOW
    // This is the main extension surface for customer-specific behavior.
    //
    // The default pattern is:
    // - accept a router-delivered message (only the router is validated here; source-chain allowlisting is in `processMessage`)
    // - isolate processing in a self-call
    // - persist failed messages for cross-chain refund or local recovery
    //
    // In most integrations, `ccipReceive` should stay defensive: processing failures must not revert the
    // router call, while `processMessage` is the function that evolves (including `onlyValidChain` on the inbound source).
    ////////////////////////////////////////////////////////////////////////////

    /// @notice CCIP router entrypoint. Reverts only if the caller is not the router. Processing failures (including invalid source chain in `processMessage`) are caught so delivered tokens are not stranded solely because `processMessage` reverted.
    function ccipReceive(Client.Any2EVMMessage calldata message) external onlyRouter {
        try this.processMessage(message) {
            emit MessageSucceeded(message.messageId);
        } catch {
            messageErrorCode[message.messageId] = ErrorCode.BASIC;
            _storeFailedMessageRecord(message.messageId, message);
            ChainType snap = chains[message.sourceChainSelector];
            if (snap == ChainType.NONE) {
                snap = _inferChainFamilyFromSender(message.sender);
            }
            refundChainFamilySnapshot[message.messageId] = snap;
            emit MessageFailed(message.messageId);
        }
    }

    /// @notice External self-call target so try/catch can isolate message-processing failures.
    /// @dev Implements the default inbound business logic for this reference deployment; change it by editing this function (or its helpers) in a fork—not by overriding a `virtual` hook from a subclass of an unmodified parent.
    /// Decodes `message.data` with `abi.decode(message.data, (Payload))` — exactly `CCIP_MESSAGE_PAYLOAD_LENGTH` bytes for every configured source family (EVM and SVM); encoders use the same ABI as integration tests and E2E tooling.
    /// Applies `onlyValidChain(message.sourceChainSelector)` so disabled inbound source chains revert here (not in `ccipReceive`).
    /// Reverts here are intentionally caught by `ccipReceive`, after which the
    /// message is marked as failed and can later be recovered via cross-chain refund
    /// or, when encoded in the payload, local transfer to `localRefundAddress`.
    /// Decoded `minimumOut` enforces a floor on output units after `_processTarget` and the adapter fee skim (shares on deposit, underlying on redeem); when `returnToSourceChain` is true, bridging uses that post-check amount. It does not capture fee-on-transfer dynamics, rebasing, or other exotic ERC-20 behavior—see field docs on `Payload`.
    /// @param message Inbound CCIP message being processed.
    function processMessage(Client.Any2EVMMessage calldata message)
        external
        onlySelf
        onlyValidChain(message.sourceChainSelector)
    {
        if (message.destTokenAmounts.length != 1) revert InvalidTokenCount(message.destTokenAmounts.length);

        if (message.data.length != CCIP_MESSAGE_PAYLOAD_LENGTH) {
            revert InvalidPayloadLength(message.data.length, CCIP_MESSAGE_PAYLOAD_LENGTH);
        }
        Payload memory payload = abi.decode(message.data, (Payload));
        if (!enabledTargets[payload.target]) revert InvalidTarget(payload.target);

        (bool returnToSourceChain,) = _unpackDeliveryAndRefund(payload.deliveryAndRefund);

        address inputToken = message.destTokenAmounts[0].token;
        uint256 inputAmount = message.destTokenAmounts[0].amount;
        if (inputAmount == 0) revert AmountIsZero();

        (address outputToken, uint256 outputAmount) = _processTarget(
            payload.target,
            inputToken,
            inputAmount,
            payload.minimumOut,
            returnToSourceChain,
            message.sourceChainSelector
        );

        emit TargetProcessed(message.messageId, payload.target, inputToken, outputToken, inputAmount, outputAmount);

        if (returnToSourceChain) {
            sendToken(message.sourceChainSelector, payload.beneficiary, outputToken, outputAmount, ChainType.NONE);
        } else {
            address localBeneficiary = _bytes32ToAddress(payload.beneficiary);
            IERC20(outputToken).safeTransfer(localBeneficiary, outputAmount);
            emit LocalTokenDelivered(message.messageId, outputToken, localBeneficiary, outputAmount);
        }
    }

    /// @dev Default target processor assumes enabled targets follow ERC-4626. In a fork, replace or rewrite this routine for async vaults, multi-asset vaults, or bespoke interfaces—there is no `virtual` hook to override in-place on the shipped bytecode.
    /// @param target Target vault selected by the inbound payload.
    /// @param inputToken Token delivered to the adapter by CCIP.
    /// @param inputAmount Amount of the delivered token.
    /// @param minimumOut Minimum output units of `outputToken` expected from the vault interaction after `_processTarget` applies the configured flat protocol fee: vault shares when depositing underlying, underlying when redeeming shares. When the payload sets `returnToSourceChain`, this check runs on the executed local output immediately before bridging that amount. Does not model fee-on-transfer, rebasing, or other non-standard ERC-20 behavior—operators must not rely on it for those tokens.
    /// @param applyAssetFee When true (return-to-source), charge `assetFees[assetFeeDestinationChainSelector][bridgedOutputToken]` (fee in underlying units); when false (local delivery), skip asset fees.
    /// @param assetFeeDestinationChainSelector Outbound chain selector used to look up the fee schedule when `applyAssetFee` is true (execution uses the inbound message's `sourceChainSelector`).
    /// @return outputToken Token produced by the vault action.
    /// @return outputAmount Amount of outputToken produced.
    function _processTarget(
        address target,
        address inputToken,
        uint256 inputAmount,
        uint256 minimumOut,
        bool applyAssetFee,
        uint64 assetFeeDestinationChainSelector
    ) private returns (address outputToken, uint256 outputAmount) {
        address assetToken = IERC4626(target).asset();

        uint256 fee;
        if (applyAssetFee) {
            address bridgedToken = inputToken == assetToken ? target : assetToken;
            fee = assetFees[assetFeeDestinationChainSelector][bridgedToken];
        }

        if (inputToken == assetToken) {
            if (!depositsEnabled) revert DepositsDisabled();

            uint256 depositAmount = inputAmount;
            if (fee > 0) {
                if (inputAmount <= fee) revert FeeExceedsAmount(inputAmount, fee);
                unchecked {
                    depositAmount = inputAmount - fee;
                }
                collectedFees[inputToken] += fee;
            }

            IERC20(inputToken).safeIncreaseAllowance(target, depositAmount);
            outputAmount = IERC4626(target).deposit(depositAmount, address(this));
            outputToken = target;
        } else if (inputToken == target) {
            if (!redeemsEnabled) revert RedeemsDisabled();

            uint256 redeemedAssets = IERC4626(target).redeem(inputAmount, address(this), address(this));
            outputToken = assetToken;
            outputAmount = redeemedAssets;
            if (fee > 0) {
                if (redeemedAssets <= fee) revert FeeExceedsAmount(redeemedAssets, fee);
                unchecked {
                    outputAmount = redeemedAssets - fee;
                }
                collectedFees[assetToken] += fee;
            }
        } else {
            revert InvalidTargetToken(target, inputToken);
        }

        if (outputAmount == 0) revert NoOutputReceived();
        if (outputAmount < minimumOut) revert MinimumOutputNotMet(minimumOut, outputAmount);
    }

    /// @notice Preview net output for an inbound token transfer to `vaultTarget`, using the same deposit/redeem routing and
    /// `assetFees` behavior as `processMessage` (via `IERC4626.previewDeposit` / `previewRedeem`).
    /// @dev `assetFeeDestinationChainSelector` must match inbound `message.sourceChainSelector` and be configured in `chains` (same rule as `processMessage`'s `onlyValidChain`), regardless of `returnToSourceChain`. Fees apply only when `returnToSourceChain` is true.
    /// For UIs: returns `0` when `amount == 0`, when the flat fee consumes the deposit or redeem output, or when the
    /// vault preview is zero—instead of reverting like `processMessage` would for those cases. Calls to `previewDeposit` /
    /// `previewRedeem` on the vault are not wrapped: if the vault reverts, this call reverts too (unlike the `0` cases above).
    /// @param token Inbound token: the vault underlying for a deposit path, or the vault share token (`vaultTarget`) for redeem.
    /// @param vaultTarget Allowlisted ERC-4626 vault (`Payload.target`).
    /// @param amount Inbound amount in `token` units.
    /// @param returnToSourceChain Whether the simulated flow bridges output back (fee applies) or delivers locally (no asset fee).
    /// @param assetFeeDestinationChainSelector Inbound source chain selector (`message.sourceChainSelector`); must be configured in `chains`. Also keys `assetFees` when `returnToSourceChain` is true.
    /// @return received Net amount received after fees: vault shares on deposit, underlying on redeem; `0` if the trade is not viable.
    function preview(
        address token,
        address vaultTarget,
        uint256 amount,
        bool returnToSourceChain,
        uint64 assetFeeDestinationChainSelector
    ) external view returns (uint256 received) {
        if (!enabledTargets[vaultTarget]) revert InvalidTarget(vaultTarget);
        if (amount == 0) return 0;

        if (chains[assetFeeDestinationChainSelector] == ChainType.NONE) {
            revert InvalidChain(assetFeeDestinationChainSelector);
        }

        address assetToken = IERC4626(vaultTarget).asset();

        uint256 fee;
        if (returnToSourceChain) {
            address bridgedToken = token == assetToken ? vaultTarget : assetToken;
            fee = assetFees[assetFeeDestinationChainSelector][bridgedToken];
        }

        if (token == assetToken) {
            if (!depositsEnabled) revert DepositsDisabled();

            uint256 depositAmount = amount;
            if (fee > 0) {
                if (amount <= fee) return 0;
                depositAmount = amount - fee;
            }

            received = IERC4626(vaultTarget).previewDeposit(depositAmount);
            return received;
        }

        if (token == vaultTarget) {
            if (!redeemsEnabled) revert RedeemsDisabled();

            uint256 redeemedAssets = IERC4626(vaultTarget).previewRedeem(amount);
            received = redeemedAssets;
            if (fee > 0) {
                if (redeemedAssets <= fee) return 0;
                received = redeemedAssets - fee;
            }
            return received;
        }

        revert InvalidTargetToken(vaultTarget, token);
    }

    ////////////////////////////////////////////////////////////////////////////
    // FAILED MESSAGE RECOVERY
    // This section handles failed inbound messages: cross-chain refund to the original
    // sender on the source chain, or local recovery to `localRefundAddress` on this chain.
    //
    // Any address can trigger the cross-chain refund path because the recipient is derived
    // deterministically from stored message data rather than caller input. Local recovery
    // requires `msg.sender == localRefundAddress`.
    //
    // `message.sender` must be the CCIP wire shape (32-byte `abi.encode` of the remote sender); see `_normalizeToBytes32`.
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Refund a failed message: bridge each `destTokenAmounts` entry with non-zero amount back to the original `message.sender` on the source chain.
    /// @dev Zero-amount entries are skipped. At least one non-zero amount is required or the call reverts `NoRefundableTokenAmounts`. Requires `messageErrorCode[messageId] == BASIC` and `msg.value >=` the sum of native fees actually paid across all non-zero legs (each leg re-quotes `getFee` at send time; see `_estimateRefundFee` for a pre-execution estimate only—callers should pad `msg.value`). Sets `messageErrorCode` to `RESOLVED` and deletes `failedMessageRecords` / `refundChainFamilySnapshot` before outbound `sendToken` loops so a full success clears stored state; any revert after that (e.g. insufficient native for fees) rolls back the whole transaction. Refunds excess `msg.value` using that actual sum and emits `MessageRefunded`.
    /// Refund routing normalizes `message.sender` with `_normalizeToBytes32`, which accepts only 32-byte CCIP sender encodings; any other width reverts `InvalidSenderAddressFormat` here (and likewise in `estimateRefundFee`). `checkRefundEligibility` returns `canRefund == false` for unsupported widths instead of reverting.
    /// @param messageId Identifier of the failed inbound message.
    function refundFailedMessage(bytes32 messageId) external payable nonReentrant {
        if (messageErrorCode[messageId] != ErrorCode.BASIC) revert MessageNotFailed(messageId);
        FailedMessageRecord memory record = failedMessageRecords[messageId];
        if (!_anyPositiveDestAmount(record.destTokenAmounts)) revert NoRefundableTokenAmounts();
        bytes32 originalSender = _normalizeToBytes32(record.sender);
        ChainType refundEnc = _refundOutboundEncodingFamily(messageId, record);

        messageErrorCode[messageId] = ErrorCode.RESOLVED;
        delete failedMessageRecords[messageId];
        delete refundChainFamilySnapshot[messageId];

        uint256 totalPaidFee;
        for (uint256 i = 0; i < record.destTokenAmounts.length; ++i) {
            uint256 amt = record.destTokenAmounts[i].amount;
            if (amt == 0) continue;
            (, uint256 paidFee) = sendToken(
                record.sourceChainSelector,
                originalSender,
                record.destTokenAmounts[i].token,
                amt,
                refundEnc
            );
            totalPaidFee += paidFee;
        }

        if (msg.value < totalPaidFee) revert InsufficientRecoveryFee(totalPaidFee, msg.value);

        _refundExcess(msg.sender, totalPaidFee);
        emit MessageRefunded(messageId, record.sourceChainSelector, originalSender);
    }

    /// @notice Return refund metadata for a failed message without sending anything.
    /// @dev Returns `canRefund == false` when the message is not in `BASIC` state, when `record.sender` is not
    /// exactly 32 bytes, or when no `destTokenAmounts` entry has a positive amount—these mirror conditions that
    /// would revert on `refundFailedMessage` / `estimateRefundFee` (`MessageNotFailed`, `InvalidSenderAddressFormat`,
    /// `NoRefundableTokenAmounts`).
    /// After those early-outs, this function calls `_estimateRefundFee`, which invokes `IRouterClient(ROUTER).getFee`
    /// once per non-zero refund leg. That router call is outside the early-outs and **can revert** under ordinary
    /// operational conditions, for example when the local router does not support the destination lane, when the
    /// configured outbound `extraArgs` format is incompatible with the destination on-ramp, when stored
    /// `requestedFinalityForV3` fails on-ramp validation, or when the returned token has no pool on the destination
    /// lane. Integrators should treat any such revert as a transient "not refundable right now" state rather than a
    /// hard programmatic error (same handling as `canRefund == false`).
    /// @param messageId Identifier of the failed inbound message.
    /// @return canRefund Whether the message is currently refundable (when the call completes without reverting).
    /// @return originalSender Normalized sender on the source chain that would receive refund transfers.
    /// @return token First `destTokenAmounts` entry with non-zero amount when any exist (fee quotes and sends skip zero legs).
    /// @return tokenAmount Amount for `token`.
    /// @return requiredFee Sum of view-estimated native fees for each non-zero leg (one `getFee` per such entry). Actual fees at `refundFailedMessage` execution may differ; pad `msg.value` when refunding.
    function checkRefundEligibility(bytes32 messageId)
        external
        view
        returns (bool canRefund, bytes32 originalSender, address token, uint256 tokenAmount, uint256 requiredFee)
    {
        if (messageErrorCode[messageId] != ErrorCode.BASIC) return (false, bytes32(0), address(0), 0, 0);

        FailedMessageRecord memory record = failedMessageRecords[messageId];
        if (record.sender.length != 32) return (false, bytes32(0), address(0), 0, 0);
        if (!_anyPositiveDestAmount(record.destTokenAmounts)) return (false, bytes32(0), address(0), 0, 0);

        canRefund = true;
        originalSender = _normalizeToBytes32(record.sender);

        requiredFee = _estimateRefundFee(messageId, record, originalSender);
        for (uint256 i = 0; i < record.destTokenAmounts.length; ++i) {
            if (record.destTokenAmounts[i].amount > 0) {
                token = record.destTokenAmounts[i].token;
                tokenAmount = record.destTokenAmounts[i].amount;
                break;
            }
        }
    }

    /// @notice Quote a lower-bound-style estimate of the total native fee to refund a failed message (one `getFee` per `destTokenAmounts` entry with current router state).
    /// @dev Not a cap on what `refundFailedMessage` may spend: each send re-quotes fees. Integrators should pad `msg.value` beyond this value. Uses `_normalizeToBytes32(message.sender)`; unsupported sender lengths revert `InvalidSenderAddressFormat` (same rule as `refundFailedMessage`).
    /// @param messageId Identifier of the failed inbound message.
    /// @return fee Estimated total native fee for all refund sends.
    function estimateRefundFee(bytes32 messageId) external view returns (uint256) {
        if (messageErrorCode[messageId] != ErrorCode.BASIC) revert MessageNotFailed(messageId);
        FailedMessageRecord memory record = failedMessageRecords[messageId];
        if (!_anyPositiveDestAmount(record.destTokenAmounts)) revert NoRefundableTokenAmounts();
        return _estimateRefundFee(messageId, record, _normalizeToBytes32(record.sender));
    }

    /// @notice Recover a failed message locally on this chain by transferring inbound `destTokenAmounts` to the payload `localRefundAddress`.
    /// @dev Zero-amount entries are skipped. At least one non-zero amount is required or the call reverts `NoRefundableTokenAmounts`. Reverts `MessageNotFailed`, `NoLocalRefundAddress`, `UnauthorizedLocalRefund`, or `NoRefundableTokenAmounts` when preconditions are not met. Requires `messageErrorCode[messageId] == BASIC`, a non-zero stored `localRefundAddress`, and `msg.sender == localRefundAddress`. Does not require native fee. Sets `messageErrorCode` to `RESOLVED` and deletes stored failure state before transfers; any revert after that (e.g. token transfer failure) rolls back the whole transaction. Cross-chain `refundFailedMessage` remains available while the message is `BASIC`; whichever path succeeds first resolves the message.
    /// @param messageId Identifier of the failed inbound message.
    function recoverFailedMessageLocally(bytes32 messageId) external nonReentrant {
        if (messageErrorCode[messageId] != ErrorCode.BASIC) revert MessageNotFailed(messageId);

        FailedMessageRecord memory record = failedMessageRecords[messageId];
        address recipient = record.localRefundAddress;
        if (recipient == address(0)) revert NoLocalRefundAddress(messageId);
        if (msg.sender != recipient) revert UnauthorizedLocalRefund(msg.sender, recipient);
        if (!_anyPositiveDestAmount(record.destTokenAmounts)) revert NoRefundableTokenAmounts();

        messageErrorCode[messageId] = ErrorCode.RESOLVED;
        delete failedMessageRecords[messageId];
        delete refundChainFamilySnapshot[messageId];

        for (uint256 i = 0; i < record.destTokenAmounts.length; ++i) {
            uint256 amt = record.destTokenAmounts[i].amount;
            if (amt == 0) continue;
            IERC20(record.destTokenAmounts[i].token).safeTransfer(recipient, amt);
        }

        emit MessageRecoveredLocally(messageId, recipient);
    }

    /// @notice Return local recovery metadata for a failed message without transferring anything.
    /// @dev Returns `canRecover == false` when the message is not in `BASIC` state, when `record.localRefundAddress` is zero, or when no `destTokenAmounts` entry has a positive amount—these mirror conditions that would revert on `recoverFailedMessageLocally` (`MessageNotFailed`, `NoLocalRefundAddress`, `NoRefundableTokenAmounts`; caller authorization is not checked here). Never reverts. Reports the first non-zero `destTokenAmounts` entry in `token` / `tokenAmount`, matching `checkRefundEligibility`.
    /// @param messageId Identifier of the failed inbound message.
    /// @return canRecover Whether the message supports local recovery by the stored `localRefundAddress`.
    /// @return localRefundAddress EVM address that may call `recoverFailedMessageLocally`.
    /// @return token First `destTokenAmounts` entry with non-zero amount when any exist.
    /// @return tokenAmount Amount for `token`.
    function checkLocalRecoveryEligibility(bytes32 messageId)
        external
        view
        returns (bool canRecover, address localRefundAddress, address token, uint256 tokenAmount)
    {
        if (messageErrorCode[messageId] != ErrorCode.BASIC) return (false, address(0), address(0), 0);

        FailedMessageRecord memory record = failedMessageRecords[messageId];
        if (record.localRefundAddress == address(0)) return (false, address(0), address(0), 0);
        if (!_anyPositiveDestAmount(record.destTokenAmounts)) return (false, address(0), address(0), 0);

        canRecover = true;
        localRefundAddress = record.localRefundAddress;

        for (uint256 i = 0; i < record.destTokenAmounts.length; ++i) {
            if (record.destTokenAmounts[i].amount > 0) {
                token = record.destTokenAmounts[i].token;
                tokenAmount = record.destTokenAmounts[i].amount;
                break;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // OUTBOUND MESSAGE FLOW
    // This section constructs and sends outbound CCIP token messages after
    // inbound processing or failed-message refunds decide what to return.
    //
    // `sendToken` does not use `onlyValidChain`; it resolves EVM vs SVM from `chains[...]` when `encodingOverride == NONE`
    // and reverts `InvalidChain` if the effective outbound family is still `NONE`. Refunds pass an explicit override from
    // `_refundOutboundEncodingFamily` so Solana wire shape is preserved if `chains[source]` is retyped after the snapshot.
    //
    // When forking:
    // - extend message construction with custom payload data
    // - add pre-send accounting or validation
    // - keep fee estimation and router invocation semantics intact unless
    //   intentionally changing transport behavior
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Send one token over CCIP; outbound wire shape uses `encodingOverride` when it is not `NONE`, otherwise `chains[destinationChainSelector]`.
    /// @dev Reverts `InvalidChain(destinationChainSelector)` when the effective family is `NONE` (unset selector and no override). Return legs from `processMessage` pass `encodingOverride == NONE` only after `onlyValidChain`, so `chains[...]` is normally set. `refundFailedMessage` passes `_refundOutboundEncodingFamily(...)`.
    /// @param encodingOverride `NONE` → use live `chains[destinationChainSelector]`; otherwise use this family for `receiver` / `extraArgs` only.
    /// @return messageId Identifier of the outbound CCIP message.
    /// @return feePaid Native amount forwarded to the router on `ccipSend` for this leg (matches `getFee` quote used for that send).
    function sendToken(
        uint64 destinationChainSelector,
        bytes32 beneficiary,
        address token,
        uint256 amount,
        ChainType encodingOverride
    ) internal returns (bytes32 messageId, uint256 feePaid) {
        if (amount == 0) revert AmountIsZero();

        ChainType outboundFamily = encodingOverride == ChainType.NONE
            ? chains[destinationChainSelector]
            : encodingOverride;

        Client.EVM2AnyMessage memory message =
            _buildOutboundMessage(destinationChainSelector, beneficiary, token, amount, outboundFamily);
        uint256 fee = IRouterClient(ROUTER).getFee(destinationChainSelector, message);
        if (address(this).balance < fee) revert InsufficientNativeBalance(fee, address(this).balance);

        IERC20(token).safeIncreaseAllowance(ROUTER, amount);

        messageId = IRouterClient(ROUTER).ccipSend{value: fee}(destinationChainSelector, message);
        feePaid = fee;

        emit MessageSent(messageId, destinationChainSelector, outboundFamily, beneficiary, token, amount, fee);
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL UTILITIES
    // These helpers support the core transport flow and should remain small,
    // explicit, and easy for downstream agents to reason about.
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Normalize CCIP `message.sender` bytes for refund routing: requires exactly 32 bytes and loads them as `bytes32(input)` (single word load). CCIP OnRamp encodes EVM senders with `abi.encode`, producing 32-byte left-padded addresses; any other length reverts `InvalidSenderAddressFormat`. Used consistently by `refundFailedMessage`, `estimateRefundFee`, and `checkRefundEligibility` (which pre-checks the length to avoid reverts).
    /// @param input Encoded sender bytes from an inbound CCIP message.
    /// @return Normalized sender bytes32 value.
    function _normalizeToBytes32(bytes memory input) private pure returns (bytes32) {
        if (input.length != 32) revert InvalidSenderAddressFormat();
        return bytes32(input);
    }

    /// @dev Build the outbound CCIP message used for returns and refunds. Outbound `extraArgs` are never taken from
    /// untrusted message data; see `evmReturnExtraArgsFormat` and `_buildReturnLegExtraArgs`.
    /// @param destinationChainSelector Chain selector to send to.
    /// @param beneficiary Encoded destination beneficiary.
    /// @param token Token being bridged.
    /// @param amount Amount of token being bridged.
    /// @param outboundFamily EVM vs SVM encoding for `receiver` and `extraArgs` (`SVM` uses Solana layouts; otherwise EVM).
    /// @return message Outbound CCIP message ready for fee quoting and send.
    function _buildOutboundMessage(
        uint64 destinationChainSelector,
        bytes32 beneficiary,
        address token,
        uint256 amount,
        ChainType outboundFamily
    ) private view returns (Client.EVM2AnyMessage memory message) {
        if (outboundFamily == ChainType.NONE) revert InvalidChain(destinationChainSelector);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
        bytes memory extraArgs = _buildReturnLegExtraArgs(destinationChainSelector, token, beneficiary, outboundFamily);

        bytes memory encodedReceiver;
        if (outboundFamily == ChainType.SVM) {
            encodedReceiver = abi.encode(address(0));
        } else {
            _requireValidEvmBeneficiary(beneficiary);
            encodedReceiver = abi.encode(beneficiary);
        }

        return Client.EVM2AnyMessage({
            receiver: encodedReceiver,
            data: "",
            tokenAmounts: tokenAmounts,
            extraArgs: extraArgs,
            feeToken: address(0)
        });
    }

    /// @dev Infer EVM vs SVM from untrusted `message.sender` bytes when `chains[selector]` is unset at failure time.
    /// CCIP delivers 32-byte senders. Values with only the low 160 bits set are treated as canonical EVM padding; otherwise 32-byte is treated as SVM. Any other length yields `NONE` (refund/quote paths then revert `InvalidChain` unless configuration is fixed).
    function _inferChainFamilyFromSender(bytes memory sender) private pure returns (ChainType) {
        if (sender.length != 32) return ChainType.NONE;
        bytes32 word = bytes32(sender);
        if (uint256(word) <= type(uint160).max) {
            return ChainType.EVM;
        }
        return ChainType.SVM;
    }

    /// @dev Snapshot from failure time; if still `NONE`, use live `chains`; if still `NONE`, re-infer from stored `sender` (legacy empty snapshot support).
    function _refundOutboundEncodingFamily(bytes32 messageId, FailedMessageRecord memory record)
        private
        view
        returns (ChainType enc)
    {
        enc = refundChainFamilySnapshot[messageId];
        if (enc == ChainType.NONE) {
            enc = chains[record.sourceChainSelector];
            if (enc == ChainType.NONE) {
                enc = _inferChainFamilyFromSender(record.sender);
            }
        }
    }

    /// @dev Sum of `getFee` quotes for each refund leg using current router `sendCount`. If the router increases its quote after each outbound send, this can underestimate the sum of fees actually paid in one `refundFailedMessage` transaction (each `sendToken` re-quotes). Callers should pad `msg.value` beyond this estimate.
    /// @param messageId Failed inbound message identifier (for encoding-family snapshot lookup).
    /// @param record Stored refund-relevant fields.
    /// @param originalSender Normalized sender that should receive the refund.
    /// @return fee View-estimated total native fee for the refund send(s).
    function _estimateRefundFee(bytes32 messageId, FailedMessageRecord memory record, bytes32 originalSender)
        private
        view
        returns (uint256 fee)
    {
        ChainType enc = _refundOutboundEncodingFamily(messageId, record);
        for (uint256 i = 0; i < record.destTokenAmounts.length; ++i) {
            uint256 amt = record.destTokenAmounts[i].amount;
            if (amt == 0) continue;
            Client.EVM2AnyMessage memory outboundMessage = _buildOutboundMessage(
                record.sourceChainSelector,
                originalSender,
                record.destTokenAmounts[i].token,
                amt,
                enc
            );
            fee += IRouterClient(ROUTER).getFee(record.sourceChainSelector, outboundMessage);
        }
    }

    /// @dev True if any `destTokenAmounts[i].amount` is non-zero (refund fee and sends ignore zero entries).
    function _anyPositiveDestAmount(Client.EVMTokenAmount[] memory destTokenAmounts) private pure returns (bool) {
        for (uint256 i = 0; i < destTokenAmounts.length; ++i) {
            if (destTokenAmounts[i].amount > 0) return true;
        }
        return false;
    }

    /// @dev Persist only refund-relevant inbound fields; omit `messageId` and `data`.
    function _storeFailedMessageRecord(bytes32 messageId, Client.Any2EVMMessage calldata message) private {
        FailedMessageRecord storage record = failedMessageRecords[messageId];
        record.sourceChainSelector = message.sourceChainSelector;
        record.sender = message.sender;
        record.destTokenAmounts = message.destTokenAmounts;

        if (message.data.length == CCIP_MESSAGE_PAYLOAD_LENGTH) {
            Payload memory payload = abi.decode(message.data, (Payload));
            (, address localRefundAddress) = _unpackDeliveryAndRefund(payload.deliveryAndRefund);
            record.localRefundAddress = localRefundAddress;
        }
    }

    /// @dev Unpack `deliveryAndRefund`: bit 0 is `returnToSourceChain`; bits 1..160 are `localRefundAddress`. Bits 161..255 are ignored and not validated.
    function _unpackDeliveryAndRefund(uint256 deliveryAndRefund)
        private
        pure
        returns (bool returnToSourceChain, address localRefundAddress)
    {
        returnToSourceChain = (deliveryAndRefund & 1) != 0;
        localRefundAddress = address(uint160(deliveryAndRefund >> 1));
    }

    /// @dev Unstored / `UNSET` enum in `evmReturnExtraArgsFormat` encodes as `LEGACY_EXTRA_ARGS_V2` on the wire.
    function _resolvedEvmReturnFormat(uint64 destinationChainSelector)
        private
        view
        returns (EvmReturnExtraArgsFormat fmt)
    {
        fmt = evmReturnExtraArgsFormat[destinationChainSelector];
        if (fmt == EvmReturnExtraArgsFormat.UNSET) {
            return EvmReturnExtraArgsFormat.LEGACY_EXTRA_ARGS_V2;
        }
    }

    /// @dev Build trusted `extraArgs` for return/refund outbound sends (tokens-only on EVM: `gasLimit` 0 in V3 basic).
    /// @param destinationChainSelector Destination chain for the outbound send.
    /// @param token ERC-20 bridged on this leg (selects `evmReturnRequestedFinality` when lane is V3).
    /// @param beneficiary Encoded destination beneficiary (SVM token receiver).
    /// @param outboundFamily EVM vs SVM branch for Solana `extraArgs` vs EVM formats.
    /// @return extraArgs Encoded extra args for `Client.EVM2AnyMessage`.
    function _buildReturnLegExtraArgs(
        uint64 destinationChainSelector,
        address token,
        bytes32 beneficiary,
        ChainType outboundFamily
    ) private view returns (bytes memory extraArgs) {
        if (outboundFamily == ChainType.SVM) {
            return Client._svmArgsToBytes(
                Client.SVMExtraArgsV1({
                    computeUnits: 0,
                    accountIsWritableBitmap: 0,
                    allowOutOfOrderExecution: true,
                    tokenReceiver: beneficiary,
                    accounts: new bytes32[](0)
                })
            );
        }

        EvmReturnExtraArgsFormat fmt = _resolvedEvmReturnFormat(destinationChainSelector);
        if (fmt == EvmReturnExtraArgsFormat.GENERIC_EXTRA_ARGS_V3_BASIC) {
            bytes4 fin = evmReturnRequestedFinality[destinationChainSelector][token];
            return ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, fin);
        }

        return Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}));
    }

    /// @dev Reverts `DuplicateCCV` if the same address appears twice in `requiredCCVs`, twice in `optionalCCVs`, or in both lists. Reverts `InvalidOptionalCCV` for `address(0)` in `optionalCCVs` (zero is a valid placeholder only in `requiredCCVs`).
    function _requireUniqueCCVs(address[] calldata requiredCCVs, address[] calldata optionalCCVs) private pure {
        for (uint256 i = 0; i < requiredCCVs.length; ++i) {
            for (uint256 j = i + 1; j < requiredCCVs.length; ++j) {
                if (requiredCCVs[i] == requiredCCVs[j]) revert DuplicateCCV(requiredCCVs[i]);
            }
            for (uint256 k = 0; k < optionalCCVs.length; ++k) {
                if (requiredCCVs[i] == optionalCCVs[k]) revert DuplicateCCV(requiredCCVs[i]);
            }
        }
        for (uint256 i = 0; i < optionalCCVs.length; ++i) {
            if (optionalCCVs[i] == address(0)) revert InvalidOptionalCCV();
            for (uint256 j = i + 1; j < optionalCCVs.length; ++j) {
                if (optionalCCVs[i] == optionalCCVs[j]) revert DuplicateCCV(optionalCCVs[i]);
            }
        }
    }

    /// @dev Refund unused native value back to the caller.
    /// @param refundRecipient Recipient of any excess native value.
    /// @param amountUsed Amount of msg.value consumed by the refund flow.
    function _refundExcess(address refundRecipient, uint256 amountUsed) private {
        if (msg.value > amountUsed) {
            uint256 excess = msg.value - amountUsed;
            (bool success,) = refundRecipient.call{value: excess}("");
            if (!success) revert RefundFailed();
        }
    }

    /// @dev Reverts unless `beneficiary` is a canonical right-aligned EVM address in bytes32 form (upper 96 bits zero).
    /// @param beneficiary Beneficiary slot from an inbound payload or outbound beneficiary encoding.
    function _requireValidEvmBeneficiary(bytes32 beneficiary) private pure {
        if (beneficiary >> 160 != 0) revert InvalidEVMAddress(beneficiary);
    }

    /// @dev Convert an EVM beneficiary encoded as bytes32 into an address.
    /// @param input Encoded beneficiary bytes32 value.
    /// @return Decoded EVM address.
    function _bytes32ToAddress(bytes32 input) private pure returns (address) {
        _requireValidEvmBeneficiary(input);
        return address(uint160(uint256(input)));
    }

    /// @notice Return the configured CCV list and inbound advertised finality for `sourceChainSelector`.
    /// @dev `allowedFinalityConfig` is `inboundFinality[sourceChainSelector]` (defaults `bytes4(0)`). Second argument is unused (interface parity with `IAny2EVMMessageReceiverV2`). `virtual` satisfies the interface.
    /// @param sourceChainSelector Inbound `message.sourceChainSelector`; selects `ccvConfigs[sourceChainSelector]` and `inboundFinality[sourceChainSelector]`.
    /// @return requiredCCVs CCVs that must always pass verification for this source.
    /// @return optionalCCVs Optional CCVs for this source; at least `optionalThreshold` must pass when used.
    /// @return optionalThreshold Minimum optional CCVs that must pass verification for this source.
    /// @return allowedFinalityConfig `inboundFinality[sourceChainSelector]`.
    function getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes calldata)
        external
        view
        virtual
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        )
    {
        CCVConfig storage config = ccvConfigs[sourceChainSelector];
        requiredCCVs = config.requiredCCVs;
        optionalCCVs = config.optionalCCVs;
        optionalThreshold = config.optionalThreshold;
        allowedFinalityConfig = inboundFinality[sourceChainSelector];
    }
}
