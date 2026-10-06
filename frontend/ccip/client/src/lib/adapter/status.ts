/**
 * CCIP message status tracking via the public CCIP API (same source the Receiver Monitor
 * uses). Normalizes the lifecycle into a small set of stages for a stepper UI.
 */
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

export async function fetchMessageStatus(messageId: string): Promise<CcipMessageInfo | null> {
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

export const STATUS_STAGES: CcipMessageStatus[] = [
  "SENT",
  "SOURCE_FINALIZED",
  "COMMITTED",
  "BLESSED",
  "VERIFIED",
  "SUCCESS",
];

export function statusStageIndex(status: CcipMessageStatus): number {
  const idx = STATUS_STAGES.indexOf(status);
  if (idx >= 0) return idx;
  if (status === "VERIFYING") return STATUS_STAGES.indexOf("BLESSED");
  if (status === "FAILED") return STATUS_STAGES.length - 1;
  return 0;
}

export function isTerminal(status: CcipMessageStatus): boolean {
  return status === "SUCCESS" || status === "FAILED";
}
