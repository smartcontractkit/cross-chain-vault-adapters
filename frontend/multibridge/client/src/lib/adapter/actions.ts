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
import type { DecodedInbound } from "./state";
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

function clients(hubChain: CCIPChain, account: Address) {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  const chain = viemChainFor(hubChain);
  const publicClient = createPublicClient({ chain, transport: http(hubChain.rpcUrl) });
  const walletClient = createWalletClient({ chain, transport: custom((window as any).ethereum), account });
  return { publicClient, walletClient };
}

/**
 * Every recovery entrypoint takes the full captured `Inbound` (reconstructed from the adapter's
 * `MessageFailed` event); the adapter verifies it against its stored hash commitment.
 */

/**
 * Permissionless bounce-to-source of a failed message's tokens. The caller funds the bounce fee via
 * `msg.value` (`value`); the contract re-quotes each leg and refunds any surplus. Reverts with
 * `LocalRefundOnly` when the message opted into handler-only recovery. Runs on the HUB chain.
 */
export async function refundToSource(opts: {
  hubChain: CCIPChain;
  adapter: Address;
  inbound: DecodedInbound;
  account: Address;
  value: bigint;
}): Promise<{ txHash: Hex }> {
  const { publicClient, walletClient } = clients(opts.hubChain, opts.account);
  const hash = await walletClient.writeContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "refundToSource",
    args: [opts.inbound],
    value: opts.value,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return { txHash: hash };
}

/**
 * Handler-only retry: re-run `_handleReceive` for a captured failure (e.g. after a transient shortfall
 * clears). Caller funds the outbound leg via `value`; surplus refunded. Reverts (message stays FAILED)
 * if reprocessing still fails. Runs on the HUB chain.
 */
export async function retryFailedMessage(opts: {
  hubChain: CCIPChain;
  adapter: Address;
  inbound: DecodedInbound;
  account: Address;
  value: bigint;
}): Promise<{ txHash: Hex }> {
  const { publicClient, walletClient } = clients(opts.hubChain, opts.account);
  const hash = await walletClient.writeContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "retryFailedMessage",
    args: [opts.inbound],
    value: opts.value,
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return { txHash: hash };
}

/**
 * Handler-only local finalize: send a failed message's held tokens to a local address. No CCIP/LZ fee.
 * Runs on the HUB chain.
 */
export async function refundLocal(opts: {
  hubChain: CCIPChain;
  adapter: Address;
  inbound: DecodedInbound;
  to: Address;
  account: Address;
}): Promise<{ txHash: Hex }> {
  const { publicClient, walletClient } = clients(opts.hubChain, opts.account);
  const hash = await walletClient.writeContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "refundLocal",
    args: [opts.inbound, opts.to],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return { txHash: hash };
}

/** Pad an estimate by a percentage (surplus is refunded by the contract). */
export function padFee(estimate: bigint, pct = 50): bigint {
  return (estimate * BigInt(100 + pct)) / 100n;
}

/**
 * Best-effort suggested `msg.value` for a `refundToSource` bounce, mirroring the on-chain bounce:
 *  - CCIP source → `quoteCcip(srcSelector, sender, token, amount, "0x", 0, 0x0)`.
 *  - LayerZero source → `quoteOft(uint32(srcEid), sender, lzOft, amount, 0, "0x", lzReceiveOption(200000))`.
 * SVM-source CCIP bounces have no quote view — returns null (caller pads a heuristic). The contract
 * refunds any surplus, so over-funding is safe.
 */
export async function suggestRefundToSourceFee(opts: {
  hubClient: PublicClient;
  adapter: Address;
  channel: "CCIP" | "LayerZero";
  srcId: bigint; // CCIP selector or LZ eid
  sender: Hex; // 32-byte sender word
  token: Address;
  amount: bigint;
  lzOft?: Address;
  isSvm?: boolean;
}): Promise<bigint | null> {
  try {
    if (opts.channel === "CCIP") {
      if (opts.isSvm) return null; // no quoteCcipSvm view
      const receiver = (`0x${opts.sender.slice(-40)}`) as Address;
      const fee = (await opts.hubClient.readContract({
        address: opts.adapter,
        abi: ADAPTER_ABI,
        functionName: "quoteCcip",
        args: [opts.srcId, receiver, opts.token, opts.amount, "0x", 0n, "0x0000000000000000000000000000000000000000"],
      })) as bigint;
      return padFee(fee);
    }
    if (!opts.lzOft) return null;
    const option = (await opts.hubClient.readContract({
      address: opts.adapter,
      abi: ADAPTER_ABI,
      functionName: "lzReceiveOption",
      args: [200_000n],
    })) as Hex;
    const fee = (await opts.hubClient.readContract({
      address: opts.adapter,
      abi: ADAPTER_ABI,
      functionName: "quoteOft",
      args: [Number(opts.srcId), opts.sender, opts.lzOft, opts.amount, 0n, "0x", option],
    })) as bigint;
    return padFee(fee);
  } catch {
    return null;
  }
}
