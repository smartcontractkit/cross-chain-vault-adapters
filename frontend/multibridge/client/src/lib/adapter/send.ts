import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  getAddress,
  pad,
  decodeEventLog,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { EVMChain, SolanaChain } from "@chainlink/ccip-sdk";
import { fromViemClient, viemWallet } from "@chainlink/ccip-sdk/viem";
import { Options } from "@layerzerolabs/lz-v2-utilities";
import { ADAPTER_ABI, ERC20_ABI, ERC4626_ABI, OFT_ABI } from "./abi";
import type { SourceChainInfo } from "./networks";
import type { CCIPChain } from "@/config/ccip.config";

/** The rail a message originates on (source → hub). Orthogonal to the return-leg `destination`. */
export type Rail = "ccip" | "oft" | "stargate";

export type VaultAction = "deposit" | "redeem";

// Default gas budgets (mirror the scenarios in config/multibridge/sepolia.json).
export const DEFAULT_CCIP_INBOUND_GAS = 500_000; // CCIP grants this to ccipReceive on the hub
export const DEFAULT_LZ_COMPOSE_GAS = 500_000n; // hub lzCompose (deposit/redeem + deliver)
export const DEFAULT_LZ_RECEIVE_GAS = 80_000n; // hub OFT credit (lzReceive)

function viemChainFor(c: {
  id: number;
  name: string;
  nativeCurrency: any;
  rpcUrl: string;
  explorerUrl: string;
}) {
  return {
    id: c.id,
    name: c.name,
    nativeCurrency: c.nativeCurrency,
    rpcUrls: { default: { http: [c.rpcUrl] } },
    blockExplorers: { default: { name: "Explorer", url: c.explorerUrl } },
  };
}

function sourceVChain(source: SourceChainInfo) {
  return viemChainFor({
    id: source.evmChainId!,
    name: source.label,
    nativeCurrency: source.nativeCurrency,
    rpcUrl: source.rpcUrl!,
    explorerUrl: source.explorerUrl,
  });
}

export interface SendResult {
  txHash: string;
  /** CCIP messageId or LayerZero guid — the hub `Inbound.guid`, and the recovery/tracking key. */
  messageId: string;
}

/* -------------------------------------------------------------------------- */
/*                              Preview + token meta                          */
/* -------------------------------------------------------------------------- */

/**
 * Preview the vault output on the hub for a delivered amount. The adapter has no `preview()` — it uses
 * the vault's own ERC-4626 `previewDeposit`/`previewRedeem`. `amount` is in HUB delivered-token units
 * (asset for a deposit, share for a redeem). Returns 0 on a non-viable trade.
 */
export async function previewVaultOutput(opts: {
  hubClient: PublicClient;
  vault: Address;
  isDeposit: boolean;
  amount: bigint;
}): Promise<bigint> {
  if (opts.amount === 0n) return 0n;
  return (await opts.hubClient.readContract({
    address: opts.vault,
    abi: ERC4626_ABI,
    functionName: opts.isDeposit ? "previewDeposit" : "previewRedeem",
    args: [opts.amount],
  })) as bigint;
}

export function applySlippage(amount: bigint, slippageBps: number): bigint {
  return (amount * BigInt(10_000 - slippageBps)) / 10_000n;
}

/** Read a token's decimals/symbol on an EVM source chain. */
export async function readSourceToken(
  source: SourceChainInfo,
  token: Address,
): Promise<{ decimals: number; symbol: string }> {
  if (source.family !== "EVM" || !source.rpcUrl) return { decimals: 9, symbol: "TOKEN" };
  const client = createPublicClient({ chain: sourceVChain(source), transport: http(source.rpcUrl) });
  const [decimals, symbol] = await Promise.all([
    client.readContract({ address: getAddress(token), abi: ERC20_ABI, functionName: "decimals" }).catch(() => 18),
    client.readContract({ address: getAddress(token), abi: ERC20_ABI, functionName: "symbol" }).catch(() => "TOKEN"),
  ]);
  return { decimals: Number(decimals), symbol: symbol as string };
}

/**
 * Discover the source-chain token that bridges 1:1 to a hub token via the CCIP Cross-Chain-Token (CCT)
 * pool graph: hub router → TokenAdminRegistry → token pool → remote config for the source selector →
 * `remoteToken`. For a deposit pass the vault asset; for a redeem pass the share token. Returns null
 * when the token isn't a CCT / has no lane (callers fall back to manual/hint entry).
 */
export async function resolveSourceToken(opts: {
  hubChain: CCIPChain;
  router: Address;
  hubToken: Address;
  sourceChainSelector: bigint;
}): Promise<string | null> {
  try {
    const publicClient = createPublicClient({
      chain: viemChainFor({
        id: opts.hubChain.id,
        name: opts.hubChain.name,
        nativeCurrency: opts.hubChain.nativeCurrency,
        rpcUrl: opts.hubChain.rpcUrl,
        explorerUrl: opts.hubChain.explorerUrl,
      }),
      transport: http(opts.hubChain.rpcUrl),
    });
    const chain: any = await fromViemClient(publicClient as any);
    const registry = await chain.getTokenAdminRegistryFor(opts.router);
    const cfg = await chain.getRegistryTokenConfig(registry, opts.hubToken);
    if (!cfg?.tokenPool) return null;
    const remote = await chain.getTokenPoolRemote(cfg.tokenPool, opts.sourceChainSelector);
    const remoteToken: string | undefined = remote?.remoteToken;
    return remoteToken && remoteToken !== "0x0000000000000000000000000000000000000000" ? remoteToken : null;
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------------- */
/*                                  CCIP rail                                 */
/* -------------------------------------------------------------------------- */

export interface CcipSendParams {
  source: SourceChainInfo;
  hubCcipSelector: bigint;
  adapter: Address;
  sourceToken: Address;
  amount: bigint;
  data: Hex; // encoded VaultMessage
  inboundGasLimit?: number;
  sender: Address;
}

export interface CcipQuote {
  fee: bigint;
  gasLimit: number;
}

/** Quote the source CCIP fee for an EVM-source programmable token transfer to the hub adapter. */
export async function quoteCcipSend(p: CcipSendParams): Promise<CcipQuote> {
  if (p.source.family !== "EVM" || !p.source.rpcUrl || !p.source.routerAddress) {
    throw new Error("quoteCcipSend requires an EVM source chain");
  }
  const gasLimit = p.inboundGasLimit ?? DEFAULT_CCIP_INBOUND_GAS;
  const evmChain = await EVMChain.fromUrl(p.source.rpcUrl);
  const fee = await evmChain.getFee({
    router: p.source.routerAddress as Address,
    destChainSelector: p.hubCcipSelector,
    message: {
      receiver: p.adapter,
      data: p.data,
      tokenAmounts: [{ token: p.sourceToken, amount: p.amount }],
      extraArgs: { gasLimit: BigInt(gasLimit), allowOutOfOrderExecution: true },
    },
  });
  return { fee: fee as bigint, gasLimit };
}

/** Originate a CCIP programmable token transfer from an EVM source to the hub adapter. */
export async function executeCcipSend(p: CcipSendParams): Promise<SendResult> {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  if (p.source.family !== "EVM" || !p.source.rpcUrl || !p.source.routerAddress) {
    throw new Error("executeCcipSend requires an EVM source chain");
  }
  const vchain = sourceVChain(p.source);
  const publicClient = createPublicClient({ chain: vchain, transport: http(p.source.rpcUrl) });
  const walletClient = createWalletClient({
    chain: vchain,
    transport: custom((window as any).ethereum),
    account: p.sender,
  });

  const gasLimit = p.inboundGasLimit ?? DEFAULT_CCIP_INBOUND_GAS;

  // Approve the source token to the CCIP router (it pulls during ccipSend).
  const approveHash = await walletClient.writeContract({
    address: p.sourceToken,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [p.source.routerAddress as Address, p.amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const evmChain = await fromViemClient(publicClient as any);
  const result = await evmChain.sendMessage({
    router: p.source.routerAddress as Address,
    destChainSelector: p.hubCcipSelector,
    message: {
      receiver: p.adapter,
      data: p.data,
      tokenAmounts: [{ token: p.sourceToken, amount: p.amount }],
      extraArgs: { gasLimit: BigInt(gasLimit), allowOutOfOrderExecution: true },
    },
    wallet: viemWallet(walletClient as any),
  });
  return { txHash: result.tx.hash, messageId: result.message.messageId };
}

/** Originate a CCIP programmable token transfer from a Solana (SVM) source. */
export async function executeSolanaCcipSend(opts: {
  source: SourceChainInfo;
  hubCcipSelector: bigint;
  adapter: Address;
  sourceToken: string; // SPL mint
  amount: bigint;
  data: Hex;
  inboundGasLimit?: number;
  solana: { publicKey: any; signTransaction: any };
}): Promise<SendResult> {
  if (!opts.source.endpoint || !opts.source.programId) throw new Error("Solana source misconfigured");
  const chain = await SolanaChain.fromUrl(opts.source.endpoint);
  const out: any = await chain.sendMessage({
    router: opts.source.programId,
    destChainSelector: opts.hubCcipSelector,
    message: {
      receiver: opts.adapter,
      data: opts.data,
      tokenAmounts: [{ token: opts.sourceToken, amount: opts.amount }],
      extraArgs: {
        gasLimit: BigInt(opts.inboundGasLimit ?? DEFAULT_CCIP_INBOUND_GAS),
        allowOutOfOrderExecution: true,
      },
    },
    wallet: { publicKey: opts.solana.publicKey, signTransaction: opts.solana.signTransaction } as any,
  });
  return { txHash: out.tx.hash, messageId: out.message.messageId };
}

/* -------------------------------------------------------------------------- */
/*                          LayerZero OFT / Stargate rail                     */
/* -------------------------------------------------------------------------- */

export interface LzSendParams {
  source: SourceChainInfo;
  /** The OFT adapter (oft rail) or Stargate pool (stargate rail) on the SOURCE chain. */
  endpoint: Address;
  hubLzEid: number;
  adapter: Address;
  sourceToken: Address;
  amount: bigint;
  composeMsg: Hex; // encoded VaultMessage
  /** Source-leg floor after LP fee (Stargate) / shared-decimal dust (OFT). */
  minAmountLD?: bigint;
  lzReceiveGasLimit?: bigint;
  composeGasLimit?: bigint;
  /** Native (wei) delivered with the compose to pre-pay the hub's outbound return leg. */
  returnLegValueWei?: bigint;
  sender: Address;
}

export interface LzQuote {
  nativeFee: bigint;
  extraOptions: Hex;
}

/** Build the executor options for an OFT/Stargate compose send (lzReceive credit + lzCompose at idx 0). */
function buildLzOptions(p: LzSendParams): Hex {
  return Options.newOptions()
    .addExecutorLzReceiveOption(Number(p.lzReceiveGasLimit ?? DEFAULT_LZ_RECEIVE_GAS), 0)
    .addExecutorComposeOption(
      0,
      Number(p.composeGasLimit ?? DEFAULT_LZ_COMPOSE_GAS),
      Number(p.returnLegValueWei ?? 0n),
    )
    .toHex() as Hex;
}

function buildSendParam(p: LzSendParams, extraOptions: Hex) {
  return {
    dstEid: p.hubLzEid,
    to: pad(p.adapter, { size: 32 }),
    amountLD: p.amount,
    minAmountLD: p.minAmountLD ?? 0n,
    extraOptions,
    composeMsg: p.composeMsg,
    oftCmd: "0x" as Hex, // instant "taxi" mode (Stargate) / plain compose (OFT)
  } as const;
}

/** Quote the native fee for an OFT or Stargate send (both use the IOFT `quoteSend` surface). */
export async function quoteLzSend(p: LzSendParams): Promise<LzQuote> {
  if (p.source.family !== "EVM" || !p.source.rpcUrl) throw new Error("quoteLzSend requires an EVM source chain");
  const publicClient = createPublicClient({ chain: sourceVChain(p.source), transport: http(p.source.rpcUrl) });
  const extraOptions = buildLzOptions(p);
  const fee = (await publicClient.readContract({
    address: p.endpoint,
    abi: OFT_ABI,
    functionName: "quoteSend",
    args: [buildSendParam(p, extraOptions), false],
  })) as { nativeFee: bigint; lzTokenFee: bigint };
  return { nativeFee: fee.nativeFee, extraOptions };
}

/** Originate an OFT or Stargate send from an EVM source to the hub adapter (token + compose payload). */
export async function executeLzSend(p: LzSendParams): Promise<SendResult> {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  if (p.source.family !== "EVM" || !p.source.rpcUrl) throw new Error("executeLzSend requires an EVM source chain");
  const vchain = sourceVChain(p.source);
  const publicClient = createPublicClient({ chain: vchain, transport: http(p.source.rpcUrl) });
  const walletClient = createWalletClient({
    chain: vchain,
    transport: custom((window as any).ethereum),
    account: p.sender,
  });

  const extraOptions = buildLzOptions(p);
  const sendParam = buildSendParam(p, extraOptions);

  const fee = (await publicClient.readContract({
    address: p.endpoint,
    abi: OFT_ABI,
    functionName: "quoteSend",
    args: [sendParam, false],
  })) as { nativeFee: bigint; lzTokenFee: bigint };

  // OFTAdapter requires an ERC-20 approval; native OFTs do not.
  const approvalRequired = (await publicClient.readContract({
    address: p.endpoint,
    abi: OFT_ABI,
    functionName: "approvalRequired",
  })) as boolean;
  if (approvalRequired) {
    const approveHash = await walletClient.writeContract({
      address: p.sourceToken,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [p.endpoint, p.amount],
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }

  const sendHash = await walletClient.writeContract({
    address: p.endpoint,
    abi: OFT_ABI,
    functionName: "send",
    args: [sendParam, { nativeFee: fee.nativeFee, lzTokenFee: 0n }, p.sender],
    value: fee.nativeFee,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: sendHash });

  const guid = extractGuidFromLogs(receipt.logs) ?? (await fetchGuidFromLzScan(receipt.transactionHash));
  return { txHash: receipt.transactionHash, messageId: guid ?? receipt.transactionHash };
}

/** Extract the LayerZero guid from an `OFTSent` log — iterate all logs (Stargate may emit elsewhere). */
function extractGuidFromLogs(logs: { data: Hex; topics: readonly Hex[] }[]): `0x${string}` | undefined {
  for (const log of logs) {
    try {
      const ev = decodeEventLog({ abi: OFT_ABI, data: log.data, topics: log.topics as [Hex, ...Hex[]] });
      if (ev.eventName === "OFTSent") {
        const g = (ev.args as { guid?: `0x${string}` }).guid;
        if (g) return g;
      }
    } catch {
      /* try next log */
    }
  }
  return undefined;
}

/** LayerZero Scan testnet API fallback when the local guid decode misses (indexing lag). */
async function fetchGuidFromLzScan(txHash: `0x${string}`): Promise<`0x${string}` | undefined> {
  const url = `https://scan-testnet.layerzero-api.com/v1/messages/tx/${txHash}`;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const res = await fetch(url);
      if (res.ok) {
        const body = (await res.json()) as { data?: Array<{ guid?: string }> };
        const guid = body.data?.[0]?.guid;
        if (guid?.startsWith("0x")) return guid as `0x${string}`;
      }
    } catch {
      /* retry */
    }
    if (attempt < 4) await new Promise((r) => setTimeout(r, 3000));
  }
  return undefined;
}
