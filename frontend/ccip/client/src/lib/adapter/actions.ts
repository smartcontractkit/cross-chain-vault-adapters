import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { ADAPTER_ABI } from "./abi";
import type { CCIPChain } from "@/config/ccip.config";

function viemChainFor(c: CCIPChain) {
  return {
    id: c.id,
    name: c.name,
    nativeCurrency: c.nativeCurrency,
    rpcUrls: { default: { http: [c.rpcUrl] } },
    blockExplorers: { default: { name: "Explorer", url: c.explorerUrl } },
  };
}

export async function estimateRefundFee(
  client: PublicClient,
  adapter: Address,
  messageId: Hex,
): Promise<bigint> {
  return (await client.readContract({
    address: adapter,
    abi: ADAPTER_ABI,
    functionName: "estimateRefundFee",
    args: [messageId],
  })) as bigint;
}

/**
 * Permissionless cross-chain refund. Pads msg.value above the estimate (the contract
 * re-quotes each leg and reverts InsufficientRecoveryFee if short). Runs on the HUB chain.
 */
export async function refundFailedMessage(opts: {
  hubChain: CCIPChain;
  adapter: Address;
  messageId: Hex;
  account: Address;
  value: bigint;
}): Promise<{ txHash: Hex }> {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  const chain = viemChainFor(opts.hubChain);
  const publicClient = createPublicClient({ chain, transport: http(opts.hubChain.rpcUrl) });
  const walletClient = createWalletClient({
    chain,
    transport: custom((window as any).ethereum),
    account: opts.account,
  });
  const hash = await walletClient.writeContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "refundFailedMessage",
    args: [opts.messageId],
    value: opts.value,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return { txHash: hash };
}

/** Local recovery by the encoded localRefundAddress. No CCIP fee. Runs on the HUB chain. */
export async function recoverFailedMessageLocally(opts: {
  hubChain: CCIPChain;
  adapter: Address;
  messageId: Hex;
  account: Address;
}): Promise<{ txHash: Hex }> {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  const chain = viemChainFor(opts.hubChain);
  const publicClient = createPublicClient({ chain, transport: http(opts.hubChain.rpcUrl) });
  const walletClient = createWalletClient({
    chain,
    transport: custom((window as any).ethereum),
    account: opts.account,
  });
  const hash = await walletClient.writeContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "recoverFailedMessageLocally",
    args: [opts.messageId],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return { txHash: hash };
}

export function padFee(estimate: bigint, pct = 20): bigint {
  return (estimate * BigInt(100 + pct)) / 100n;
}
