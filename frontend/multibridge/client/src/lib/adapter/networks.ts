import { ccipChains, getChainBySelector, getChainById, type CCIPChain } from "@/config/ccip.config";
import { SOLANA_NETWORKS, type SolanaNetwork } from "@/config/solana.config";

export type ChainFamily = "EVM" | "SVM";

/**
 * Unified description of a chain a CCIP message can originate from (source) or that the
 * adapter is deployed on (hub). EVM entries come from `ccip.config.ts`; SVM entries from
 * `solana.config.ts`.
 */
export interface SourceChainInfo {
  key: string; // unique id, e.g. "evm-11155111" or "svm-devnet"
  family: ChainFamily;
  label: string;
  chainSelector: string;
  isTestnet: boolean;
  explorerUrl: string;
  // EVM only
  evmChainId?: number;
  routerAddress?: string;
  rpcUrl?: string;
  nativeCurrency?: { name: string; symbol: string; decimals: number };
  // SVM only
  solanaNetwork?: SolanaNetwork;
  programId?: string;
  endpoint?: string;
}

export function evmChainToSource(c: CCIPChain): SourceChainInfo {
  return {
    key: `evm-${c.id}`,
    family: "EVM",
    label: c.name,
    chainSelector: c.chainSelector,
    isTestnet: c.isTestnet,
    explorerUrl: c.explorerUrl,
    evmChainId: c.id,
    routerAddress: c.routerAddress,
    rpcUrl: c.rpcUrl,
    nativeCurrency: c.nativeCurrency,
  };
}

export const SOLANA_SOURCES: SourceChainInfo[] = (
  Object.entries(SOLANA_NETWORKS) as [SolanaNetwork, (typeof SOLANA_NETWORKS)[SolanaNetwork]][]
).map(([net, cfg]) => ({
  key: `svm-${net}`,
  family: "SVM",
  label: cfg.name,
  chainSelector: cfg.chainSelector,
  isTestnet: net === "devnet",
  explorerUrl: net === "devnet"
    ? "https://explorer.solana.com/?cluster=devnet"
    : "https://explorer.solana.com",
  solanaNetwork: net,
  programId: cfg.programId,
  endpoint: cfg.endpoint,
}));

export const EVM_SOURCES: SourceChainInfo[] = ccipChains.map(evmChainToSource);

export const ALL_SOURCES: SourceChainInfo[] = [...EVM_SOURCES, ...SOLANA_SOURCES];

/** All hub chains the adapter could live on (EVM only — it is a Solidity contract). */
export const HUB_CHAINS: CCIPChain[] = ccipChains;

export function hubChainById(id: number): CCIPChain | undefined {
  return getChainById(id);
}

/** Resolve a CCIP chain selector to a human display, across EVM + SVM. */
export function describeSelector(selector: string | bigint): {
  label: string;
  family: ChainFamily | "UNKNOWN";
  source?: SourceChainInfo;
} {
  const sel = selector.toString();
  const evm = getChainBySelector(sel);
  if (evm) return { label: evm.name, family: "EVM", source: evmChainToSource(evm) };
  const svm = SOLANA_SOURCES.find((s) => s.chainSelector === sel);
  if (svm) return { label: svm.label, family: "SVM", source: svm };
  return { label: `Selector ${sel}`, family: "UNKNOWN" };
}

export function sourceByKey(key: string): SourceChainInfo | undefined {
  return ALL_SOURCES.find((s) => s.key === key);
}

export function sourceBySelector(selector: string | bigint): SourceChainInfo | undefined {
  const sel = selector.toString();
  return ALL_SOURCES.find((s) => s.chainSelector === sel);
}

/** CCIP Explorer link for a message id. */
export function ccipExplorerUrl(messageId: string): string {
  return `https://ccip.chain.link/msg/${messageId}`;
}
