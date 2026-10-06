import {
  CheckCircle2,
  XCircle,
  Send,
  PackageCheck,
  ArrowLeftRight,
  Undo2,
  Coins,
  ExternalLink,
} from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "./ui";
import { shortAddr } from "@/lib/adapter/format";
import { ccipExplorerUrl } from "@/lib/adapter/networks";
import type { ActivityItem, AdapterState } from "@/lib/adapter/state";

const KIND_META: Record<string, { icon: any; label: string; tone: string }> = {
  MessageSucceeded: { icon: CheckCircle2, label: "Message succeeded", tone: "text-green-500" },
  MessageFailed: { icon: XCircle, label: "Message failed", tone: "text-destructive" },
  TargetProcessed: { icon: PackageCheck, label: "Vault processed", tone: "text-primary" },
  MessageSent: { icon: Send, label: "Outbound bridged", tone: "text-blue-500" },
  LocalTokenDelivered: { icon: Coins, label: "Local delivery", tone: "text-amber-500" },
  MessageRefunded: { icon: ArrowLeftRight, label: "Refunded", tone: "text-green-500" },
  MessageRecoveredLocally: { icon: Undo2, label: "Recovered locally", tone: "text-green-500" },
  FeeWithdrawn: { icon: Coins, label: "Fee withdrawn", tone: "text-muted-foreground" },
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
        {item.messageId && (
          <a
            href={ccipExplorerUrl(item.messageId)}
            target="_blank"
            rel="noreferrer"
            className="text-xs text-primary inline-flex items-center gap-1 font-mono"
          >
            {shortAddr(item.messageId, 10, 8)} <ExternalLink className="w-3 h-3" />
          </a>
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
  if (item.kind === "TargetProcessed") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        in {String(a.inputAmount)} → out {String(a.outputAmount)}
      </p>
    );
  }
  if (item.kind === "MessageSent") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        → selector {String(a.destinationChainSelector)} · amount {String(a.amount)} · fee {String(a.fee)}
      </p>
    );
  }
  if (item.kind === "FeeWithdrawn") {
    return (
      <p className="text-xs text-muted-foreground mt-0.5">
        {shortAddr(String(a.asset))} → {shortAddr(String(a.recipient))} · {String(a.amount)}
      </p>
    );
  }
  return null;
}
