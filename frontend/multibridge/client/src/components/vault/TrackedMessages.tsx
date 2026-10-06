import { useEffect, useState, useCallback } from "react";
import { ExternalLink, RefreshCw, Loader2, CheckCircle2, XCircle, Clock } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "./ui";
import { relativeTime, shortAddr } from "@/lib/adapter/format";
import { ccipExplorerUrl } from "@/lib/adapter/networks";
import { loadTracked, type TrackedMessage } from "@/lib/adapter/tracked";
import { fetchUnifiedStatus, type UnifiedStatus } from "@/lib/adapter/status";
import type { AdapterContext } from "@/lib/adapter/state";

interface Props {
  ctx: AdapterContext;
}

export function TrackedMessages({ ctx }: Props) {
  const [items, setItems] = useState<TrackedMessage[]>([]);
  const reload = useCallback(() => setItems(loadTracked(ctx.adapter, ctx.hubChainId)), [ctx.adapter, ctx.hubChainId]);

  useEffect(() => {
    reload();
    const handler = () => reload();
    window.addEventListener("vaultTrackedUpdate", handler);
    return () => window.removeEventListener("vaultTrackedUpdate", handler);
  }, [reload]);

  if (items.length === 0) {
    return (
      <EmptyState>
        No messages sent from this dashboard yet. Deposits and redeems you initiate appear here for
        transport + on-chain status tracking.
      </EmptyState>
    );
  }

  return (
    <div className="space-y-3">
      {items.map((m) => (
        <TrackedRow key={m.messageId} msg={m} ctx={ctx} />
      ))}
    </div>
  );
}

const RAIL_LABEL: Record<string, string> = { ccip: "CCIP", oft: "LayerZero OFT", stargate: "Stargate" };

function TrackedRow({ msg, ctx }: { msg: TrackedMessage; ctx: AdapterContext }) {
  const [status, setStatus] = useState<UnifiedStatus | null>(null);
  const [loading, setLoading] = useState(false);

  const poll = useCallback(async () => {
    setLoading(true);
    const s = await fetchUnifiedStatus(
      { rail: msg.rail, messageId: msg.messageId, txHash: msg.txHash, guid: msg.rail === "ccip" ? msg.messageId : undefined },
      { client: ctx.client, adapter: ctx.adapter },
    );
    setStatus(s);
    setLoading(false);
  }, [msg.rail, msg.messageId, msg.txHash, ctx.client, ctx.adapter]);

  useEffect(() => {
    poll();
    const t = setInterval(() => {
      setStatus((s) => {
        const terminal = s && (s.app === "REFUNDED" || s.app === "PROCESSED" || (s.transport?.terminal && s.app !== "PENDING"));
        if (terminal) {
          clearInterval(t);
          return s;
        }
        poll();
        return s;
      });
    }, 20_000);
    return () => clearInterval(t);
  }, [poll]);

  const transport = status?.transport;
  const app = status?.app ?? "UNKNOWN";
  const stageCount = transport?.stageCount ?? 3;
  const stageIndex = transport?.stageIndex ?? 0;
  const failed = app === "FAILED" || transport?.stage === "FAILED";

  const explorerHref =
    msg.rail === "ccip"
      ? ccipExplorerUrl(msg.messageId)
      : `https://testnet.layerzeroscan.com/tx/${msg.txHash}`;

  return (
    <Card>
      <CardContent className="p-4 space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <Badge variant="outline" className="capitalize">{msg.action}</Badge>
              <Badge variant="secondary" className="text-[10px]">{RAIL_LABEL[msg.rail] ?? msg.rail}</Badge>
              <span className="text-sm font-medium">
                {msg.amount} {msg.tokenSymbol}
              </span>
              <span className="text-xs text-muted-foreground">
                {msg.sourceLabel} → {msg.destinationLabel ?? "hub"}
              </span>
            </div>
            <a href={explorerHref} target="_blank" rel="noreferrer" className="text-xs text-primary inline-flex items-center gap-1 font-mono mt-0.5">
              {shortAddr(msg.messageId, 10, 8)} <ExternalLink className="w-3 h-3" />
            </a>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <AppBadge app={app} failed={failed} />
            <Button size="icon" variant="ghost" className="h-7 w-7" onClick={poll} disabled={loading}>
              {loading ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <RefreshCw className="w-3.5 h-3.5" />}
            </Button>
          </div>
        </div>

        {/* Transport stepper */}
        <div className="flex items-center gap-1">
          {Array.from({ length: stageCount }).map((_, i) => {
            const reached = i <= stageIndex && !failed;
            const failedHere = failed && i === stageCount - 1;
            return (
              <div
                key={i}
                className={`h-1.5 flex-1 rounded-full ${failedHere ? "bg-destructive" : reached ? "bg-primary" : "bg-muted"}`}
              />
            );
          })}
        </div>
        <div className="flex items-center justify-between text-[11px] text-muted-foreground">
          <span>{relativeTime(msg.timestamp)}</span>
          <span>
            transport: {transport?.stage ?? "…"} · app: {app}
          </span>
        </div>
      </CardContent>
    </Card>
  );
}

function AppBadge({ app, failed }: { app: string; failed: boolean }) {
  if (app === "PROCESSED")
    return <Badge className="bg-green-500/15 text-green-600 dark:text-green-400 hover:bg-green-500/15"><CheckCircle2 className="w-3 h-3 mr-1" />Processed</Badge>;
  if (app === "REFUNDED")
    return <Badge className="bg-green-500/15 text-green-600 dark:text-green-400 hover:bg-green-500/15"><CheckCircle2 className="w-3 h-3 mr-1" />Refunded</Badge>;
  if (app === "FAILED" || failed)
    return <Badge variant="destructive"><XCircle className="w-3 h-3 mr-1" />Failed — recover</Badge>;
  return <Badge variant="secondary"><Clock className="w-3 h-3 mr-1" />Pending</Badge>;
}
