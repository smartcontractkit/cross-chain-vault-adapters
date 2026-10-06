import { useEffect, useState, useCallback } from "react";
import { ExternalLink, RefreshCw, Loader2, CheckCircle2, XCircle, Clock } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "./ui";
import { relativeTime, shortAddr } from "@/lib/adapter/format";
import { ccipExplorerUrl } from "@/lib/adapter/networks";
import { loadTracked, type TrackedMessage } from "@/lib/adapter/tracked";
import {
  fetchMessageStatus,
  statusStageIndex,
  STATUS_STAGES,
  isTerminal,
  type CcipMessageStatus,
} from "@/lib/adapter/status";

interface Props {
  adapter: string;
  hubChainId: number;
}

export function TrackedMessages({ adapter, hubChainId }: Props) {
  const [items, setItems] = useState<TrackedMessage[]>([]);

  const reload = useCallback(() => setItems(loadTracked(adapter, hubChainId)), [adapter, hubChainId]);

  useEffect(() => {
    reload();
    const handler = () => reload();
    window.addEventListener("vaultTrackedUpdate", handler);
    return () => window.removeEventListener("vaultTrackedUpdate", handler);
  }, [reload]);

  if (items.length === 0) {
    return <EmptyState>No messages sent from this dashboard yet. Deposits and redeems you initiate appear here for status tracking.</EmptyState>;
  }

  return (
    <div className="space-y-3">
      {items.map((m) => (
        <TrackedRow key={m.messageId} msg={m} />
      ))}
    </div>
  );
}

function TrackedRow({ msg }: { msg: TrackedMessage }) {
  const [status, setStatus] = useState<CcipMessageStatus>("SENT");
  const [loading, setLoading] = useState(false);
  const [dest, setDest] = useState<string | undefined>();

  const poll = useCallback(async () => {
    setLoading(true);
    const info = await fetchMessageStatus(msg.messageId);
    if (info) {
      setStatus(info.status);
      setDest(info.destLabel);
    }
    setLoading(false);
  }, [msg.messageId]);

  useEffect(() => {
    poll();
    const t = setInterval(() => {
      setStatus((s) => {
        if (isTerminal(s)) {
          clearInterval(t);
          return s;
        }
        poll();
        return s;
      });
    }, 20_000);
    return () => clearInterval(t);
  }, [poll]);

  const stage = statusStageIndex(status);
  const terminal = isTerminal(status);

  return (
    <Card>
      <CardContent className="p-4 space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="flex items-center gap-2 flex-wrap">
              <Badge variant="outline" className="capitalize">{msg.action}</Badge>
              <span className="text-sm font-medium">
                {msg.amount} {msg.tokenSymbol}
              </span>
              <span className="text-xs text-muted-foreground">
                {msg.sourceLabel} → {dest ?? "hub"}
              </span>
            </div>
            <a href={ccipExplorerUrl(msg.messageId)} target="_blank" rel="noreferrer" className="text-xs text-primary inline-flex items-center gap-1 font-mono mt-0.5">
              {shortAddr(msg.messageId, 10, 8)} <ExternalLink className="w-3 h-3" />
            </a>
          </div>
          <div className="flex items-center gap-2 shrink-0">
            <StatusBadge status={status} />
            <Button size="icon" variant="ghost" className="h-7 w-7" onClick={poll} disabled={loading}>
              {loading ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <RefreshCw className="w-3.5 h-3.5" />}
            </Button>
          </div>
        </div>

        {/* Stepper */}
        <div className="flex items-center gap-1">
          {STATUS_STAGES.map((s, i) => {
            const reached = i <= stage && status !== "FAILED";
            const failedHere = status === "FAILED" && i === STATUS_STAGES.length - 1;
            return (
              <div key={s} className="flex-1 flex items-center gap-1">
                <div
                  className={`h-1.5 flex-1 rounded-full ${
                    failedHere ? "bg-destructive" : reached ? "bg-primary" : "bg-muted"
                  }`}
                />
              </div>
            );
          })}
        </div>
        <div className="flex items-center justify-between text-[11px] text-muted-foreground">
          <span>{relativeTime(msg.timestamp)}</span>
          <span>{terminal ? "" : "auto-refreshing"}</span>
        </div>
      </CardContent>
    </Card>
  );
}

function StatusBadge({ status }: { status: CcipMessageStatus }) {
  if (status === "SUCCESS")
    return <Badge className="bg-green-500/15 text-green-600 dark:text-green-400 hover:bg-green-500/15"><CheckCircle2 className="w-3 h-3 mr-1" />Success</Badge>;
  if (status === "FAILED")
    return <Badge variant="destructive"><XCircle className="w-3 h-3 mr-1" />Failed</Badge>;
  return <Badge variant="secondary"><Clock className="w-3 h-3 mr-1" />{status}</Badge>;
}
