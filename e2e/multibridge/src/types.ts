/** Result of an originate tx on CCIP or LayerZero. */
export interface OriginateResult {
  txHash: `0x${string}`
  /** CCIP messageId or LayerZero guid — use as GUID when calling recover. */
  messageId: `0x${string}`
}
