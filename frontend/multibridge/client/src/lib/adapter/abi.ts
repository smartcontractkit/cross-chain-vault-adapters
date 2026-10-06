import { parseAbi } from "viem";

/**
 * Human-readable ABI for `CrossChainVaultAdapter`, the synchronous ERC-4626 adapter built on
 * `MultiChannelBridgeAdapter` + `RouteRegistry`. Covers every read, user write, and event the vault
 * dashboard needs across all three rails (CCIP / LayerZero OFT / Stargate).
 *
 * Source of truth (repo root): src/multibridge/MultiChannelBridgeAdapter.sol,
 * src/multibridge/routing/RouteRegistry.sol and src/multibridge/examples/CrossChainVaultAdapter.sol.
 */
export const ADAPTER_ABI_HUMAN = [
  // structs (base Inbound + CCIP token amount)
  "struct EVMTokenAmount { address token; uint256 amount; }",
  "struct Inbound { uint8 channel; uint64 srcId; bytes32 sender; bytes32 guid; EVMTokenAmount[] tokens; bytes data; address lzOft; }",

  // --- identity + transport wiring ---
  "function typeAndVersion() view returns (string)",
  "function getRouter() view returns (address)",
  "function s_ccipRouter() view returns (address)",
  "function s_lzEndpoint() view returns (address)",

  // --- app: fixed vault + policy ---
  "function s_vault() view returns (address)",
  "function s_asset() view returns (address)",
  "function s_requireLzReturnPrefunded() view returns (bool)",

  // --- roles (AccessControl, non-enumerable) ---
  "function FEE_SETTER_ROLE() view returns (bytes32)",
  "function FEE_COLLECTOR_ROLE() view returns (bytes32)",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function getRoleAdmin(bytes32 role) view returns (bytes32)",

  // --- inbound allowlists ---
  "function s_ccipSourceAllowed(uint64 srcSelector) view returns (bool)",
  "function s_lzOftAllowed(uint32 srcEid, address oft) view returns (bool)",

  // --- outbound allowlists + SVM lanes ---
  "function s_ccipDestAllowed(uint64 dstSelector) view returns (bool)",
  "function s_lzDestAllowed(uint32 dstEid) view returns (bool)",
  "function s_stargateDestAllowed(uint32 dstEid) view returns (bool)",
  "function s_ccipSvm(uint64 selector) view returns (bool enabled, uint32 computeUnits, bool allowOutOfOrderExecution)",

  // --- routing registry ---
  "function s_route(address token, uint64 destination) view returns (bool enabled, uint8 rail, address endpoint, uint64 dstId)",
  "function s_oftForToken(address token) view returns (address)",
  "function s_dstGas(uint64 destination) view returns (uint128)",

  // --- fees ---
  "function s_inboundFees(address outboundToken, uint64 destination) view returns (uint256)",
  "function s_collectedFees(address token) view returns (uint256)",

  // --- failure / recovery ---
  "function isFailed(bytes32 guid) view returns (bool)",
  "function isRefunded(bytes32 guid) view returns (bool)",
  "function failedMessageHash(bytes32 guid) view returns (bytes32)",
  "function failedMessageHandler(bytes data) pure returns (address)",
  "function onlyLocalRefund(bytes data) pure returns (bool)",

  // --- outbound quote helpers (used to suggest recovery fees) ---
  "function quoteCcip(uint64 dstSelector, address receiver, address token, uint256 amount, bytes data, uint256 dstGasLimit, address feeToken) view returns (uint256)",
  "function quoteOft(uint32 dstEid, bytes32 to, address oft, uint256 amount, uint256 minAmount, bytes composeMsg, bytes extraOptions) view returns (uint256)",
  "function quoteStargate(uint32 dstEid, bytes32 to, address pool, uint256 amount, uint256 minAmountLD, bytes extraOptions) view returns (uint256)",
  "function lzReceiveOption(uint128 gas) pure returns (bytes)",

  // --- user / recovery writes ---
  // The adapter stores only a hash commitment per failed guid; callers pass the full Inbound,
  // reconstructed from the MessageFailed event's `message` field (verified on-chain).
  "function refundToSource(Inbound inbound) payable",
  "function retryFailedMessage(Inbound inbound) payable",
  "function refundLocal(Inbound inbound, address to)",
  "function withdrawCollectedFee(address token, address recipient, uint256 amount)",

  // --- events: base transport ---
  "event TokensReceived(uint8 indexed channel, uint64 indexed srcId, bytes32 indexed sender, bytes32 guid, uint256 tokenCount)",
  "event SentViaCcip(bytes32 indexed messageId, uint64 indexed dstSelector, address token, uint256 amount, uint256 fee)",
  "event SentViaOft(bytes32 indexed guid, uint32 indexed dstEid, address token, uint256 amount, uint256 fee)",
  "event SentViaStargate(bytes32 indexed guid, uint32 indexed dstEid, address token, uint256 amount, uint256 fee)",
  "event CcipSourceSet(uint64 indexed srcSelector, bool allowed)",
  "event LzOftSet(uint32 indexed srcEid, address indexed oft, bool allowed)",
  "event CcipDestSet(uint64 indexed dstSelector, bool allowed)",
  "event LzDestSet(uint32 indexed dstEid, bool allowed)",
  "event StargateDestSet(uint32 indexed dstEid, bool allowed)",
  "event CcipSvmConfigSet(uint64 indexed selector, bool enabled, uint32 computeUnits, bool allowOutOfOrderExecution)",
  "event NativeRecovered(address indexed to, uint256 amount)",
  "event MessageProcessed(bytes32 indexed guid)",
  "event MessageFailed(bytes32 indexed guid, uint8 indexed channel, bytes message, bytes reason)",
  "event MessageRecovered(bytes32 indexed guid, address indexed caller)",
  "event MessageRefunded(bytes32 indexed guid, address indexed to, bytes reason)",
  "event DeliveredValueRefunded(bytes32 indexed guid, address indexed to, uint256 amount)",

  // --- events: RouteRegistry ---
  "event OftForTokenSet(address indexed token, address indexed oft)",
  "event RouteSet(address indexed token, uint64 indexed destination, bool enabled, uint8 rail, address endpoint, uint64 dstId)",
  "event DestinationGasSet(uint64 indexed destination, uint128 gasLimit)",

  // --- events: app ---
  "event ReturnPrefundRequirementSet(bool required)",
  "event InboundFeeSet(address indexed outboundToken, uint64 indexed destination, uint256 fee)",
  "event InboundFeeCollected(bytes32 indexed guid, address indexed inboundToken, uint256 fee)",
  "event CollectedFeeWithdrawn(address indexed token, address indexed recipient, uint256 amount)",
  "event VaultDelivered(bytes32 indexed guid, bool isDeposit, address outToken, uint256 outAmount, uint64 destination, bytes32 recipient)",

  // --- events: AccessControl (role discovery) ---
  "event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)",
  "event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)",

  // --- custom errors (revert decoding) ---
  "error ZeroAddress()",
  "error NotCcipRouter(address caller)",
  "error NotLzEndpoint(address caller)",
  "error NotSelf(address caller)",
  "error UnauthorizedCcipSource(uint64 srcSelector)",
  "error UnauthorizedOft(uint32 srcEid, address oft)",
  "error CcipDestNotAllowed(uint64 dstSelector)",
  "error LzDestNotAllowed(uint32 dstEid)",
  "error StargateDestNotAllowed(uint32 dstEid)",
  "error InvalidSenderLength(uint256 length)",
  "error InsufficientNativeFee(uint256 required, uint256 available)",
  "error NativeTransferFailed(address to, uint256 amount)",
  "error MessageNotFailed(bytes32 guid)",
  "error InboundMismatch(bytes32 guid)",
  "error RetryReserveDrawn(uint256 shortfall)",
  "error NoHandler(bytes32 guid)",
  "error NotHandler(address caller, address handler)",
  "error RefundRouteNotConfigured(address token)",
  "error LocalRefundOnly(bytes32 guid)",
  "error CannotTransferAdminToSelf()",
  "error SvmComputeUnitsNotZero(uint32 computeUnits)",
  "error SvmLaneNotEnabled(uint64 selector)",
  "error OftNotConfigured(address token)",
  "error AssetOftMismatch(address oftToken, address token)",
  "error NonEvmLocalRecipient(bytes32 recipient)",
  "error NonEvmCcipRecipient(bytes32 recipient)",
  "error InvalidDstId(uint64 dstId)",
  "error ZeroRecipient()",
  "error MinAmountOutNotMet(uint256 amount, uint256 minAmountOut)",
  "error DestinationGasTooLarge(uint128 gasLimit)",
  "error LocalDestinationRequiresRoute()",
  "error UnexpectedTokenCount(uint256 count)",
  "error UnsupportedToken(address token)",
  "error ReturnFeeNotPrefunded(uint256 fee, uint256 delivered)",
  "error ReturnNotPrefunded()",
  "error InboundFeeExceedsAmount(uint256 amount, uint256 fee)",
  "error FeeWithdrawExceedsCollected(uint256 collected, uint256 requested)",
  "error EnforcedPause()",
  "error AccessControlUnauthorizedAccount(address account, bytes32 neededRole)",
  "error SafeERC20FailedOperation(address token)",
] as const;

export const ADAPTER_ABI = parseAbi(ADAPTER_ABI_HUMAN);

/**
 * LayerZero V2 OFT surface used to originate an OFT or Stargate send from a spoke. Stargate pools are
 * `IStargate is IOFT`, so `quoteSend` / `send` / `token` / `approvalRequired` work for both rails
 * (this app sends in instant "taxi" mode with an empty `oftCmd`). Mirrors `e2e/multibridge/src/abi.ts`.
 */
export const OFT_ABI = parseAbi([
  "struct SendParam { uint32 dstEid; bytes32 to; uint256 amountLD; uint256 minAmountLD; bytes extraOptions; bytes composeMsg; bytes oftCmd; }",
  "struct MessagingFee { uint256 nativeFee; uint256 lzTokenFee; }",
  "struct MessagingReceipt { bytes32 guid; uint64 nonce; MessagingFee fee; }",
  "struct OFTReceipt { uint256 amountSentLD; uint256 amountReceivedLD; }",
  "function token() view returns (address)",
  "function approvalRequired() view returns (bool)",
  "function quoteSend(SendParam sendParam, bool payInLzToken) view returns (MessagingFee)",
  "function send(SendParam sendParam, MessagingFee fee, address refundAddress) payable returns (MessagingReceipt, OFTReceipt)",
  "event OFTSent(bytes32 indexed guid, uint32 dstEid, address from, uint256 amountSentLD, uint256 amountReceivedLD)",
]);

/** Alias — the Stargate rail uses the same IOFT surface (`send`/`quoteSend`). */
export const STARGATE_ABI = OFT_ABI;

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

/** OZ AccessControl default admin role id. */
export const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

/** MultiChannelBridgeAdapter.Channel enum (uint8): inbound/failed message channel. */
export type Channel = "CCIP" | "LayerZero";
export const CHANNEL: Record<number, Channel> = { 0: "CCIP", 1: "LayerZero" };

/** RouteRegistry.Rail enum (uint8): outbound delivery rail on the hub. */
export type RailName = "LZ_OFT" | "CCIP" | "STARGATE" | "CCIP_SVM" | "LOCAL";
export const RAIL: Record<number, RailName> = {
  0: "LZ_OFT",
  1: "CCIP",
  2: "STARGATE",
  3: "CCIP_SVM",
  4: "LOCAL",
};

/**
 * Accepted `typeAndVersion()` value: `CrossChainVaultAdapter <semver>`. Anchored so the factory
 * (`CrossChainVaultAdapterFactory ...`) and other adapter kinds are rejected.
 */
export const SUPPORTED_TYPE_AND_VERSION = /^CrossChainVaultAdapter \d+\.\d+\.\d+/;
export const SUPPORTED_ADAPTER_TYPES = ["CrossChainVaultAdapter"] as const;
