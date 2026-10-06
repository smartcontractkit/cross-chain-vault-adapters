export const ERC20_ABI = [
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)"
];

/**
 * Minimal human-readable ABI for the `CrossChainERC4626Adapter` surface used by the E2E scripts.
 * Signatures match the compiled ABI of `src/ccip/CrossChainERC4626Adapter.sol`. Custom errors are
 * included so ethers can decode revert reasons from failed recovery calls.
 */
export const ADAPTER_ABI = [
  // Failed-message state (enum ErrorCode { NONE, BASIC, RESOLVED })
  "function messageErrorCode(bytes32 messageId) view returns (uint8 errorCode)",
  // Cross-chain refund
  "function checkRefundEligibility(bytes32 messageId) view returns (bool canRefund, bytes32 originalSender, address token, uint256 tokenAmount, uint256 requiredFee)",
  "function estimateRefundFee(bytes32 messageId) view returns (uint256)",
  "function refundFailedMessage(bytes32 messageId) payable",
  // Local recovery
  "function checkLocalRecoveryEligibility(bytes32 messageId) view returns (bool canRecover, address localRefundAddress, address token, uint256 tokenAmount)",
  "function recoverFailedMessageLocally(bytes32 messageId)",
  // Events
  "event MessageSucceeded(bytes32 indexed messageId)",
  "event MessageFailed(bytes32 indexed messageId)",
  "event MessageRefunded(bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary)",
  "event MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress)",
  // Errors reachable from the recovery paths
  "error MessageNotFailed(bytes32 messageId)",
  "error NoLocalRefundAddress(bytes32 messageId)",
  "error UnauthorizedLocalRefund(address caller, address localRefundAddress)",
  "error NoRefundableTokenAmounts()",
  "error InsufficientRecoveryFee(uint256 requiredFee, uint256 providedFee)",
  "error InsufficientNativeBalance(uint256 requiredFee, uint256 availableBalance)",
  "error InvalidSenderAddressFormat()",
  "error InvalidEvmReturnExtraArgsFormat()",
  "error RefundFailed()"
];

/** `CrossChainERC4626Adapter.ErrorCode` values returned by `messageErrorCode(messageId)`. */
export const ADAPTER_ERROR_CODE = {
  NONE: 0,
  BASIC: 1,
  RESOLVED: 2
} as const;

/** Minimal IRouterClient surface for scripted `ccipSend` / quotes (matches CCIP Client.EVM2AnyMessage). */
export const CCIP_ROUTER_MIN_ABI = [
  "function ccipSend(uint64 destChainSelector, tuple(bytes receiver, bytes data, tuple(address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) payable returns (bytes32 messageId)",
  "function getFee(uint64 destChainSelector, tuple(bytes receiver, bytes data, tuple(address token, uint256 amount)[] tokenAmounts, address feeToken, bytes extraArgs) message) view returns (uint256 fee)"
] as const;
