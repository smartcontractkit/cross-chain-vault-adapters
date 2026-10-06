import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  getAddress,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { estimateReceiveExecution } from "@chainlink/ccip-sdk";
import { fromViemClient, viemWallet } from "@chainlink/ccip-sdk/viem";
import { ADAPTER_ABI, ERC4626_ABI } from "./abi";
import { encodePayload, type BeneficiaryType } from "./payload";
import type { SourceChainInfo } from "./networks";
import type { CCIPChain } from "@/config/ccip.config";

export const DEFAULT_DEST_GAS_LIMIT = 500_000;
export const GAS_MULTIPLIER_BPS = 12_000; // 1.2x pad on the estimated dest execution gas

export type VaultAction = "deposit" | "redeem";

function viemChainFor(c: { id: number; name: string; nativeCurrency: any; rpcUrl: string; explorerUrl: string }) {
  return {
    id: c.id,
    name: c.name,
    nativeCurrency: c.nativeCurrency,
    rpcUrls: { default: { http: [c.rpcUrl] } },
    blockExplorers: { default: { name: "Explorer", url: c.explorerUrl } },
  };
}

/**
 * preview() is a VIEW on the hub adapter. token/amount are in HUB-chain delivered units.
 * Returns net output after the flat asset fee when returnToSourceChain is true. Returns 0
 * for benign "no trade" cases — treat 0 as not-viable.
 */
export async function previewOutput(opts: {
  hubClient: PublicClient;
  adapter: Address;
  deliveredToken: Address; // vault.asset() for deposit, target for redeem
  target: Address;
  deliveredAmount: bigint;
  returnToSourceChain: boolean;
  sourceChainSelector: bigint;
}): Promise<bigint> {
  const out = (await opts.hubClient.readContract({
    address: opts.adapter,
    abi: ADAPTER_ABI,
    functionName: "preview",
    args: [
      opts.deliveredToken,
      opts.target,
      opts.deliveredAmount,
      opts.returnToSourceChain,
      opts.sourceChainSelector,
    ],
  })) as bigint;
  return out;
}

export function applySlippage(amount: bigint, slippageBps: number): bigint {
  return (amount * BigInt(10_000 - slippageBps)) / 10_000n;
}

export interface BuildSendParams {
  source: SourceChainInfo; // EVM source
  hubChain: CCIPChain;
  adapter: Address;
  target: Address;
  sourceToken: Address; // token to bridge from the source chain
  amount: bigint; // in source token decimals
  beneficiary: string;
  beneficiaryType: BeneficiaryType;
  minimumOut: bigint;
  returnToSourceChain: boolean;
  localRefundAddress?: string;
  gasLimitOverride?: number;
  sender: Address;
}

export interface SendQuote {
  payload: Hex;
  gasLimit: number;
  fee: bigint;
  destChainSelector: bigint;
}

/** Estimate destination execution gas + quote the source CCIP fee (EVM source). */
export async function quoteEvmSend(p: BuildSendParams): Promise<SendQuote> {
  if (p.source.family !== "EVM" || !p.source.rpcUrl || !p.source.routerAddress) {
    throw new Error("quoteEvmSend requires an EVM source chain");
  }
  const destChainSelector = BigInt(p.hubChain.chainSelector);

  const payload = encodePayload({
    target: p.target,
    beneficiary: p.beneficiary,
    beneficiaryType: p.beneficiaryType,
    minimumOut: p.minimumOut,
    returnToSourceChain: p.returnToSourceChain,
    localRefundAddress: p.localRefundAddress,
  });

  const sourceClient = createPublicClient({
    chain: viemChainFor({
      id: p.source.evmChainId!,
      name: p.source.label,
      nativeCurrency: p.source.nativeCurrency,
      rpcUrl: p.source.rpcUrl!,
      explorerUrl: p.source.explorerUrl,
    }),
    transport: http(p.source.rpcUrl),
  });
  const destClient = createPublicClient({
    chain: viemChainFor({
      id: p.hubChain.id,
      name: p.hubChain.name,
      nativeCurrency: p.hubChain.nativeCurrency,
      rpcUrl: p.hubChain.rpcUrl,
      explorerUrl: p.hubChain.explorerUrl,
    }),
    transport: http(p.hubChain.rpcUrl),
  });

  const tokenAmounts = [{ token: p.sourceToken, amount: p.amount }];

  // 1. destination execution gas
  let gasLimit = p.gasLimitOverride ?? DEFAULT_DEST_GAS_LIMIT;
  if (!p.gasLimitOverride) {
    try {
      const sourceEvmChain = await fromViemClient(sourceClient as any);
      const destEvmChain = await fromViemClient(destClient as any);
      const estimated = await estimateReceiveExecution({
        source: sourceEvmChain,
        dest: destEvmChain,
        routerOrRamp: p.source.routerAddress as Address,
        message: {
          sender: p.sender,
          receiver: p.adapter,
          data: payload,
          tokenAmounts,
        },
      });
      gasLimit = Math.ceil((Number(estimated) * GAS_MULTIPLIER_BPS) / 10_000);
    } catch {
      gasLimit = p.gasLimitOverride ?? DEFAULT_DEST_GAS_LIMIT;
    }
  }

  // 2. fee quote
  const evmChain = await fromViemClient(sourceClient as any);
  const fee = await evmChain.getFee({
    router: p.source.routerAddress as Address,
    destChainSelector,
    message: {
      receiver: p.adapter,
      data: payload,
      tokenAmounts,
      extraArgs: { gasLimit: BigInt(gasLimit), allowOutOfOrderExecution: true },
    },
  });

  return { payload, gasLimit, fee, destChainSelector };
}

export interface SendResult {
  txHash: string;
  messageId: string;
}

/** Build + send the CCIP deposit/redeem from an EVM source via the connected wallet. */
export async function executeEvmSend(p: BuildSendParams, quote: SendQuote): Promise<SendResult> {
  if (!(window as any).ethereum) throw new Error("No EVM wallet found");
  const sourceVChain = viemChainFor({
    id: p.source.evmChainId!,
    name: p.source.label,
    nativeCurrency: p.source.nativeCurrency,
    rpcUrl: p.source.rpcUrl!,
    explorerUrl: p.source.explorerUrl,
  });
  const publicClient = createPublicClient({ chain: sourceVChain, transport: http(p.source.rpcUrl) });
  const walletClient = createWalletClient({
    chain: sourceVChain,
    transport: custom((window as any).ethereum),
    account: p.sender,
  });

  const evmChain = await fromViemClient(publicClient as any);
  const message = {
    receiver: p.adapter,
    data: quote.payload,
    fee: quote.fee,
    tokenAmounts: [{ token: p.sourceToken, amount: p.amount }],
    extraArgs: { gasLimit: BigInt(quote.gasLimit), allowOutOfOrderExecution: true },
  };

  const result = await evmChain.sendMessage({
    router: p.source.routerAddress as Address,
    destChainSelector: quote.destChainSelector,
    message,
    wallet: viemWallet(walletClient as any),
  });

  return { txHash: result.tx.hash, messageId: result.message.messageId };
}

/**
 * Discover the source-chain token that bridges 1:1 to a hub token, using the CCIP
 * Cross-Chain Token (CCT) graph:
 *   hub router → TokenAdminRegistry → token's pool → pool's remote config for the
 *   source chain selector → `remoteToken` (the address on the source chain).
 *
 * For a deposit pass the vault's underlying asset; for a redeem pass the share token
 * (`target`). Returns null when the token isn't a CCT / has no lane to that source
 * chain — callers should fall back to manual entry.
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
    return remoteToken && remoteToken !== "0x0000000000000000000000000000000000000000"
      ? remoteToken
      : null;
  } catch {
    return null;
  }
}

/** Read the source-token decimals/symbol on the source chain. */
export async function readSourceToken(
  source: SourceChainInfo,
  token: Address,
): Promise<{ decimals: number; symbol: string }> {
  if (source.family !== "EVM" || !source.rpcUrl) {
    return { decimals: 9, symbol: "TOKEN" };
  }
  const client = createPublicClient({
    chain: viemChainFor({
      id: source.evmChainId!,
      name: source.label,
      nativeCurrency: source.nativeCurrency,
      rpcUrl: source.rpcUrl,
      explorerUrl: source.explorerUrl,
    }),
    transport: http(source.rpcUrl),
  });
  const [decimals, symbol] = await Promise.all([
    client.readContract({ address: getAddress(token), abi: ERC4626_ABI, functionName: "decimals" }).catch(() => 18),
    client.readContract({ address: getAddress(token), abi: ERC4626_ABI, functionName: "symbol" }).catch(() => "TOKEN"),
  ]);
  return { decimals: Number(decimals), symbol: symbol as string };
}
