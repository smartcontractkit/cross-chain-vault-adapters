import { parseAbi } from "viem";

/**
 * Human-readable ABI for CrossChainERC4626Adapter, covering every read, user write,
 * and event the vault dashboard needs. Parsed into a viem ABI object below.
 *
 * Source of truth (repo root): src/ccip/CrossChainERC4626Adapter.sol (CrossChainERC4626Adapter 1.0.0).
 * See docs/ccip/cross-chain-erc4626-adapter-contract-reference.md.
 */
export const ADAPTER_ABI_HUMAN = [
  // --- type/version + immutable + scalars ---
  "function typeAndVersion() view returns (string)",
  "function ROUTER() view returns (address)",
  "function depositsEnabled() view returns (bool)",
  "function redeemsEnabled() view returns (bool)",
  "function CCIP_MESSAGE_PAYLOAD_LENGTH() view returns (uint256)",
  "function FEE_SETTER_ROLE() view returns (bytes32)",
  "function FEE_COLLECTOR_ROLE() view returns (bytes32)",

  // --- mapping getters ---
  "function chains(uint64) view returns (uint8)",
  "function enabledTargets(address) view returns (bool)",
  "function assetFees(uint64, address) view returns (uint256)",
  "function collectedFees(address) view returns (uint256)",
  "function messageErrorCode(bytes32) view returns (uint8)",
  "function refundChainFamilySnapshot(bytes32) view returns (uint8)",
  "function inboundFinality(uint64) view returns (bytes4)",
  "function evmReturnExtraArgsFormat(uint64) view returns (uint8)",
  "function evmReturnRequestedFinality(uint64, address) view returns (bytes4)",

  // --- access control (enumerable) ---
  "function hasRole(bytes32, address) view returns (bool)",
  "function getRoleAdmin(bytes32) view returns (bytes32)",
  "function getRoleMemberCount(bytes32) view returns (uint256)",
  "function getRoleMember(bytes32, uint256) view returns (address)",

  // --- view helpers ---
  "function preview(address token, address vaultTarget, uint256 amount, bool returnToSourceChain, uint64 assetFeeDestinationChainSelector) view returns (uint256 received)",
  "function getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes) view returns (address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold, bytes4 allowedFinalityConfig)",
  "function getFailedMessageRecord(bytes32 messageId) view returns ((uint64 sourceChainSelector, bytes sender, (address token, uint256 amount)[] destTokenAmounts, address localRefundAddress) record)",
  "function checkRefundEligibility(bytes32 messageId) view returns (bool canRefund, bytes32 originalSender, address token, uint256 tokenAmount, uint256 requiredFee)",
  "function estimateRefundFee(bytes32 messageId) view returns (uint256)",
  "function checkLocalRecoveryEligibility(bytes32 messageId) view returns (bool canRecover, address localRefundAddress, address token, uint256 tokenAmount)",

  // --- user writes ---
  "function refundFailedMessage(bytes32 messageId) payable",
  "function recoverFailedMessageLocally(bytes32 messageId)",

  // --- events (discovery + activity) ---
  "event TargetEnabled(address indexed target, bool enabled)",
  "event ChainTypeSet(uint64 indexed chainSelector, uint8 chainType)",
  "event ProcessingEnabledSet(bool depositsEnabled, bool redeemsEnabled)",
  "event AssetFeeSet(uint64 indexed destinationChainSelector, address indexed bridgedToken, uint256 fee)",
  "event CCVsConfigSet(uint64 indexed sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold)",
  "event InboundFinalitySet(uint64 indexed sourceChainSelector, bytes4 allowedFinalityConfig)",
  "event EvmReturnLaneFormatSet(uint64 indexed destinationChainSelector, uint8 format)",
  "event EvmReturnRequestedFinalitySet(uint64 indexed destinationChainSelector, address indexed token, bytes4 requestedFinalityForV3)",
  "event FeeWithdrawn(address indexed asset, address indexed recipient, uint256 amount)",
  "event NativeRecovered(address indexed recipient, uint256 amount)",
  "event MessageSucceeded(bytes32 indexed messageId)",
  "event MessageFailed(bytes32 indexed messageId)",
  "event MessageRefunded(bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary)",
  "event MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress)",
  "event TargetProcessed(bytes32 indexed messageId, address indexed target, address indexed inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount)",
  "event MessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, uint8 indexed chainType, bytes32 beneficiary, address token, uint256 amount, uint256 fee)",
  "event LocalTokenDelivered(bytes32 indexed messageId, address indexed token, address indexed beneficiary, uint256 amount)",

  // --- custom errors (for revert decoding) ---
  "error InvalidRouter(address router)",
  "error InvalidChain(uint64 chainSelector)",
  "error AmountIsZero()",
  "error InvalidEVMAddress(bytes32 beneficiary)",
  "error InvalidSenderAddressFormat()",
  "error InsufficientNativeBalance(uint256 requiredFee, uint256 availableBalance)",
  "error InsufficientRecoveryFee(uint256 requiredFee, uint256 providedFee)",
  "error InsufficientFeeBalance(uint256 availableBalance, uint256 requestedAmount)",
  "error MessageNotFailed(bytes32 messageId)",
  "error InvalidTarget(address target)",
  "error InvalidTargetToken(address target, address token)",
  "error InvalidTokenCount(uint256 tokenCount)",
  "error InvalidPayloadLength(uint256 length, uint256 expected)",
  "error FeeConfigLengthMismatch()",
  "error DepositsDisabled()",
  "error RedeemsDisabled()",
  "error FeeExceedsAmount(uint256 amount, uint256 fee)",
  "error MinimumOutputNotMet(uint256 minimumOut, uint256 actualOut)",
  "error NoOutputReceived()",
  "error RefundFailed()",
  "error RecoverNativeFailed()",
  "error NoRefundableTokenAmounts()",
  "error NoLocalRefundAddress(bytes32 messageId)",
  "error UnauthorizedLocalRefund(address caller, address localRefundAddress)",
] as const;

export const ADAPTER_ABI = parseAbi(ADAPTER_ABI_HUMAN);

export const ERC4626_ABI = parseAbi([
  "function asset() view returns (address)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function previewDeposit(uint256 assets) view returns (uint256)",
  "function previewRedeem(uint256 shares) view returns (uint256)",
]);

export const ERC20_ABI = parseAbi([
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
]);

// Role identifiers
export const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ChainType enum (chains(uint64) -> uint8)
export type ChainType = "NONE" | "EVM" | "SVM";
export const CHAIN_TYPE: Record<number, ChainType> = { 0: "NONE", 1: "EVM", 2: "SVM" };

// ErrorCode enum (messageErrorCode(bytes32) -> uint8)
export type ErrorCode = "NONE" | "BASIC" | "RESOLVED";
export const ERROR_CODE: Record<number, ErrorCode> = { 0: "NONE", 1: "BASIC", 2: "RESOLVED" };

// EvmReturnExtraArgsFormat enum
export type ReturnFormat = "UNSET" | "LEGACY_V2" | "GENERIC_V3_BASIC";
export const RETURN_FORMAT: Record<number, ReturnFormat> = {
  0: "UNSET",
  1: "LEGACY_V2",
  2: "GENERIC_V3_BASIC",
};

/**
 * Accepted `typeAndVersion()` value: `CrossChainERC4626Adapter <semver>`. Anchored so the factory
 * (`CrossChainERC4626AdapterFactory ...`) is rejected.
 */
export const SUPPORTED_TYPE_AND_VERSION = /^CrossChainERC4626Adapter \d+\.\d+\.\d+/;
