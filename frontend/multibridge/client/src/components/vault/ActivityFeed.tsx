import {
  CheckCircle2,
  XCircle,
  Send,
  PackageCheck,
  ArrowLeftRight,
  Undo2,
  Coins,
  Download,
  ExternalLink,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "./ui";
import { shortAddr } from "@/lib/adapter/format";
import type { ActivityItem, AdapterState } from "@/lib/adapter/state";

const KIND_META: Record<string, { icon: any; label: string; tone: string }> = {
  TokensReceived: { icon: Download, label: "Tokens received", tone: "text-blue-500" },
  MessageProcessed: { icon: CheckCircle2, label: "Message processed", tone: "text-green-500" },
  MessageFailed: { icon: XCircle, label: "Message failed (captured)", tone: "text-destructive" },
  MessageRecovered: { icon: Undo2, label: "Recovered (retried)", tone: "text-green-500" },
  MessageRefunded: { icon: ArrowLeftRight, label: "Refunded", tone: "text-green-500" },
  DeliveredValueRefunded: { icon: Coins, label: "Prefund surplus refunded", tone: "text-amber-500" },
  VaultDelivered: { icon: PackageCheck, label: "Vault delivered", tone: "text-primary" },
  SentViaCcip: { icon: Send, label: "Sent via CCIP", tone: "text-blue-500" },
  SentViaOft: { icon: Send, label: "Sent via LayerZero OFT", tone: "text-blue-500" },
  SentViaStargate: { icon: Send, label: "Sent via Stargate", tone: "text-blue-500" },
  InboundFeeCollected: { icon: Coins, label: "Inbound fee collected", tone: "text-muted-foreground" },
  CollectedFeeWithdrawn: { icon: Coins, label: "Fee withdrawn", tone: "text-muted-foreground" },
  NativeRecovered: { icon: Coins, label: "Native recovered", tone: "text-muted-foreground" },
};

export function ActivityFeed({ state }: { state: AdapterState }) {
  if (state.activity.length === 0) {
    return <EmptyState>No activity found in the scanned block range.</EmptyState>;
  }
  return (
    <div className="space-y-2">
      {state.activity.slice(0, 100).map((a, i) => (
        <Row key={`${a.txHash}-${a.logIndex}-${i}`} item={a} state={state} />
      ))}
    </div>
  );
}

function Row({ item, state }: { item: ActivityItem; state: AdapterState }) {
  const meta = KIND_META[item.kind] ?? { icon: Send, label: item.kind, tone: "text-muted-foreground" };
  const Icon = meta.icon;
  return (
    <div className="flex items-start gap-3 rounded-md border border-border p-3">
      <Icon className={`w-4 h-4 mt-0.5 shrink-0 ${meta.tone}`} />
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="text-sm font-medium">{meta.label}</span>
          <Badge variant="outline" className="text-[10px]">block {item.blockNumber.toString()}</Badge>
        </div>
        {item.guid && (
          <span className="text-xs text-muted-foreground inline-flex items-center gap-1 font-mono">
            {shortAddr(item.guid, 10, 8)}
          </span>
        )}
        <ActivityDetail item={item} />
      </div>
      <a
        href={`${state.meta.explorerUrl}/tx/${item.txHash}`}
        target="_blank"
        rel="noreferrer"
        className="text-muted-foreground hover:text-foreground shrink-0"
      >
        <ExternalLink className="w-3.5 h-3.5" />
      </a>
    </div>
  );
}

function ActivityDetail({ item }: { item: ActivityItem }) {
  const a = item.args;
  if (item.kind === "VaultDelivered") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        {String(a.isDeposit) === "true" ? "deposit" : "redeem"} · out {String(a.outAmount)} → destination {String(a.destination)}
      </p>
    );
  }
  if (item.kind === "SentViaCcip" || item.kind === "SentViaOft" || item.kind === "SentViaStargate") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        → {String(a.dstSelector ?? a.dstEid)} · amount {String(a.amount)} · fee {String(a.fee)}
      </p>
    );
  }
  if (item.kind === "TokensReceived") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        channel {String(a.channel) === "1" ? "LayerZero" : "CCIP"} · src {String(a.srcId)} · tokens {String(a.tokenCount)}
      </p>
    );
  }
  if (item.kind === "InboundFeeCollected") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        {shortAddr(String(a.inboundToken))} · {String(a.fee)}
      </p>
    );
  }
  if (item.kind === "CollectedFeeWithdrawn") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        {shortAddr(String(a.token))} → {shortAddr(String(a.recipient))} · {String(a.amount)}
      </p>
    );
  }
  return null;
}
