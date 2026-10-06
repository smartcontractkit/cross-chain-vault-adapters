const NATIVE_TX: Record<number, string> = {
  11155111: 'https://sepolia.etherscan.io/tx/',
  421614: 'https://sepolia.arbiscan.io/tx/',
  97: 'https://testnet.bscscan.com/tx/',
}

export function nativeTxUrl(chainId: number, txHash: string): string {
  const base = NATIVE_TX[chainId]
  if (!base) return txHash
  return `${base}${txHash}`
}

export function ccipMessageUrl(messageId: string): string {
  return `https://ccip.chain.link/msg/${messageId}`
}

export function ccipTxUrl(txHash: string): string {
  return `https://ccip.chain.link/tx/${txHash}`
}

/** LayerZero Scan (testnet) — source tx shows full cross-chain path. */
export function layerZeroTxUrl(txHash: string): string {
  return `https://testnet.layerzeroscan.com/tx/${txHash}`
}

/** LayerZero Scan message lookup by guid. */
export function layerZeroGuidUrl(guid: string): string {
  return `https://testnet.layerzeroscan.com/message/guid/${guid}`
}

export function crossChainLinks(
  channel: 'ccip' | 'layerzero',
  txHash: string,
  messageId: string,
): { crossChainTx: string; crossChainMsg: string } {
  if (channel === 'ccip') {
    return { crossChainTx: ccipTxUrl(txHash), crossChainMsg: ccipMessageUrl(messageId) }
  }
  return { crossChainTx: layerZeroTxUrl(txHash), crossChainMsg: layerZeroGuidUrl(messageId) }
}
