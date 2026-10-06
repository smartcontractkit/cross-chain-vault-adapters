/**
 * Rail-aware message status tracking.
 *
 * Transport status comes from the rail's own indexer: the Chainlink CCIP API for CCIP, the LayerZero
 * Scan API for OFT / Stargate. But because `MultiChannelBridgeAdapter` try/catches app failures, a
 * transport "SUCCESS" / "DELIVERED" does NOT mean the vault deposit/redeem succeeded — the APP outcome
 * is authoritative only from the hub (`isFailed`/`isRefunded`). `fetchUnifiedStatus` returns both.
 */
import type { Address, Hex, PublicClient } from "viem";
import { ADAPTER_ABI } from "./abi";

/* ------------------------------- CCIP transport ------------------------------- */

/** Public Chainlink CCIP API (the same default the @chainlink/ccip-sdk uses). */
const CCIP_API_BASE = "https://api.ccip.chain.link/v2/";

export type CcipMessageStatus =
  | "SENT"
  | "SOURCE_FINALIZED"
  | "COMMITTED"
  | "BLESSED"
  | "VERIFYING"
  | "VERIFIED"
  | "SUCCESS"
  | "FAILED"
  | "UNKNOWN";

export interface CcipMessageInfo {
  messageId: string;
  status: CcipMessageStatus;
  sender?: string;
  receiver?: string;
  sourceLabel?: string;
  destLabel?: string;
  sendTransactionHash?: string;
  receiptTransactionHash?: string | null;
  sendTimestamp?: string;
  receiptTimestamp?: string | null;
}

export async function fetchCcipStatus(messageId: string): Promise<CcipMessageInfo | null> {
  try {
    const url = `${CCIP_API_BASE}messages/${encodeURIComponent(messageId)}`;
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) return null; // 404 until the CCIP API has indexed the message
    const m = await res.json();
    if (!m?.messageId) return null;
    return {
      messageId: m.messageId,
      status: (m.status as CcipMessageStatus) ?? "UNKNOWN",
      sender: m.sender,
      receiver: m.receiver,
      sourceLabel: m.sourceNetworkInfo?.name,
      destLabel: m.destNetworkInfo?.name,
      sendTransactionHash: m.sendTransactionHash,
      receiptTransactionHash: m.receiptTransactionHash,
      sendTimestamp: m.sendTimestamp,
      receiptTimestamp: m.receiptTimestamp,
    };
  } catch {
    return null;
  }
}

/** Back-compat alias (the Receiver Monitor / CCIP-only callers use this name). */
export const fetchMessageStatus = fetchCcipStatus;

export const CCIP_STATUS_STAGES: CcipMessageStatus[] = [
  "SENT",
  "SOURCE_FINALIZED",
  "COMMITTED",
  "BLESSED",
  "VERIFIED",
  "SUCCESS",
];

export function ccipStageIndex(status: CcipMessageStatus): number {
  const idx = CCIP_STATUS_STAGES.indexOf(status);
  if (idx >= 0) return idx;
  if (status === "VERIFYING") return CCIP_STATUS_STAGES.indexOf("BLESSED");
  if (status === "FAILED") return CCIP_STATUS_STAGES.length - 1;
  return 0;
}

/* --------------------------- LayerZero transport --------------------------- */

const LZ_SCAN_TESTNET = "https://scan-testnet.layerzero-api.com/v1/messages/tx/";

export type LzMessageStatus =
  | "INFLIGHT"
  | "CONFIRMING"
  | "DELIVERED"
  | "FAILED"
  | "PAYLOAD_STORED"
  | "BLOCKED"
  | "UNKNOWN";

export const LZ_STATUS_STAGES: LzMessageStatus[] = ["INFLIGHT", "CONFIRMING", "DELIVERED"];

export function lzStageIndex(status: LzMessageStatus): number {
  const idx = LZ_STATUS_STAGES.indexOf(status);
  if (idx >= 0) return idx;
  if (status === "FAILED" || status === "BLOCKED" || status === "PAYLOAD_STORED") return LZ_STATUS_STAGES.length - 1;
  return 0;
}

/**
 * LayerZero Scan by source txHash. An OFT compose produces TWO messages (token credit + compose), so
 * we match the entry whose `guid` equals the tracked guid when available; otherwise the last entry.
 */
export async function fetchLzStatus(txHash: string, guid?: string): Promise<{ status: LzMessageStatus; guid?: string } | null> {
  try {
    const res = await fetch(`${LZ_SCAN_TESTNET}${encodeURIComponent(txHash)}`, {
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    const body = (await res.json()) as { data?: Array<{ guid?: string; status?: { name?: string } }> };
    const rows = body.data ?? [];
    if (!rows.length) return null;
    const match = (guid && rows.find((r) => r.guid?.toLowerCase() === guid.toLowerCase())) || rows[rows.length - 1];
    const name = (match?.status?.name?.toUpperCase() as LzMessageStatus) ?? "UNKNOWN";
    return { status: name, guid: match?.guid };
  } catch {
    return null;
  }
}

/* ------------------------------- App outcome ------------------------------- */

export type AppOutcome = "PENDING" | "PROCESSED" | "FAILED" | "REFUNDED" | "UNKNOWN";

/** Authoritative app outcome from the hub, keyed by the channel-unique guid. */
export async function fetchAppOutcome(
  hubClient: PublicClient,
  adapter: Address,
  guid: Hex,
): Promise<AppOutcome> {
  try {
    const [failed, refunded] = await Promise.all([
      hubClient.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "isFailed", args: [guid] }) as Promise<boolean>,
      hubClient.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "isRefunded", args: [guid] }) as Promise<boolean>,
    ]);
    if (refunded) return "REFUNDED";
    if (failed) return "FAILED";
    // Not failed and not refunded: either still in flight or already processed. The tracked-message UI
    // reconciles with transport (delivered + not failed ⇒ processed).
    return "PENDING";
  } catch {
    return "UNKNOWN";
  }
}

/* -------------------------------- Unified -------------------------------- */

export type Rail = "ccip" | "oft" | "stargate";

export interface TransportStatus {
  rail: Rail;
  stage: string; // rail-specific status name
  stageIndex: number;
  stageCount: number;
  terminal: boolean;
  delivered: boolean;
}

export interface UnifiedStatus {
  transport: TransportStatus | null;
  app: AppOutcome;
}

export async function fetchUnifiedStatus(
  m: { rail: Rail; messageId?: string; txHash?: string; guid?: string },
  hub?: { client: PublicClient; adapter: Address },
): Promise<UnifiedStatus> {
  let transport: TransportStatus | null = null;
  let guid = m.guid ?? (m.rail === "ccip" ? m.messageId : undefined);

  if (m.rail === "ccip" && m.messageId) {
    const info = await fetchCcipStatus(m.messageId);
    if (info) {
      transport = {
        rail: "ccip",
        stage: info.status,
        stageIndex: ccipStageIndex(info.status),
        stageCount: CCIP_STATUS_STAGES.length,
        terminal: info.status === "SUCCESS" || info.status === "FAILED",
        delivered: info.status === "SUCCESS",
      };
    }
    guid = m.messageId;
  } else if ((m.rail === "oft" || m.rail === "stargate") && m.txHash) {
    const info = await fetchLzStatus(m.txHash, m.guid);
    if (info) {
      transport = {
        rail: m.rail,
        stage: info.status,
        stageIndex: lzStageIndex(info.status),
        stageCount: LZ_STATUS_STAGES.length,
        terminal: info.status === "DELIVERED" || info.status === "FAILED" || info.status === "BLOCKED",
        delivered: info.status === "DELIVERED",
      };
      if (info.guid) guid = info.guid;
    }
  }

  let app: AppOutcome = "UNKNOWN";
  if (hub && guid) app = await fetchAppOutcome(hub.client, hub.adapter, guid as Hex);
  // Delivered on transport + not failed/refunded on the hub ⇒ the vault action processed.
  if (app === "PENDING" && transport?.delivered) app = "PROCESSED";
  return { transport, app };
}
