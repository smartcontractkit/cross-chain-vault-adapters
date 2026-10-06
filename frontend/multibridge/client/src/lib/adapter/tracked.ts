import type { Rail, VaultAction } from "./send";

export interface TrackedMessage {
  messageId: string;
  txHash: string;
  /** The rail this message originated on (source → hub) — selects the transport status source. */
  rail: Rail;
  action: VaultAction;
  adapter: string;
  hubChainId: number;
  sourceKey: string;
  sourceLabel: string;
  vaultLabel: string;
  amount: string;
  tokenSymbol: string;
  /** Return-leg route key carried in the VaultMessage (for display). */
  destinationLabel?: string;
  timestamp: number;
}

const KEY = (adapter: string, hubChainId: number) =>
  `vault-tracked:${hubChainId}:${adapter.toLowerCase()}`;
const MAX = 50;

export function loadTracked(adapter: string, hubChainId: number): TrackedMessage[] {
  try {
    const raw = localStorage.getItem(KEY(adapter, hubChainId));
    return raw ? (JSON.parse(raw) as TrackedMessage[]) : [];
  } catch {
    return [];
  }
}

export function addTracked(msg: TrackedMessage): TrackedMessage[] {
  const list = loadTracked(msg.adapter, msg.hubChainId);
  const next = [msg, ...list.filter((m) => m.messageId !== msg.messageId)].slice(0, MAX);
  try {
    localStorage.setItem(KEY(msg.adapter, msg.hubChainId), JSON.stringify(next));
    window.dispatchEvent(new CustomEvent("vaultTrackedUpdate"));
  } catch {
    /* ignore */
  }
  return next;
}
