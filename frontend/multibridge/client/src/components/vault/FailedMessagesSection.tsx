import { useEffect, useState } from "react";
import { getAddress, parseEther, type Address } from "viem";
import { useAppKitAccount, useAppKitNetwork } from "@reown/appkit/react";
import { AlertTriangle, Loader2, RotateCcw, Undo2, ArrowLeftRight } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Input } from "@/components/ui/input";
import { useToast } from "@/hooks/use-toast";
import { AddressChip, Field, EmptyState } from "./ui";
import { fmtUnits } from "@/lib/adapter/format";
import {
  refundToSource,
  retryFailedMessage,
  refundLocal,
  suggestRefundToSourceFee,
  padFee,
} from "@/lib/adapter/actions";
import { appKitNetworkById } from "@/config/web3.config";
import type { AdapterContext, AdapterState, FailedMessage } from "@/lib/adapter/state";

const ZERO = "0x0000000000000000000000000000000000000000";

interface Props {
  ctx: AdapterContext;
  state: AdapterState;
  onResolved: () => void;
}

export function FailedMessagesSection({ ctx, state, onResolved }: Props) {
  const open = state.failedMessages.filter((m) => m.isFailed);
  const done = state.failedMessages.filter((m) => !m.isFailed);

  if (state.failedMessages.length === 0) {
    return <EmptyState>No failed messages found in the scanned range. ✅</EmptyState>;
  }

  return (
    <div className="space-y-4">
      {open.length > 0 && (
        <div className="space-y-3">
          <p className="text-sm font-medium flex items-center gap-2">
            <AlertTriangle className="w-4 h-4 text-amber-500" /> Recoverable ({open.length})
          </p>
          {open.map((m) => (
            <FailedRow key={m.guid} ctx={ctx} state={state} msg={m} onResolved={onResolved} />
          ))}
        </div>
      )}
      {done.length > 0 && (
        <div className="space-y-3">
          <p className="text-sm font-medium text-muted-foreground">Resolved ({done.length})</p>
          {done.map((m) => (
            <FailedRow key={m.guid} ctx={ctx} state={state} msg={m} onResolved={onResolved} resolved />
          ))}
        </div>
      )}
    </div>
  );
}

function FailedRow({
  ctx,
  state,
  msg,
  onResolved,
  resolved,
}: {
  ctx: AdapterContext;
  state: AdapterState;
  msg: FailedMessage;
  onResolved: () => void;
  resolved?: boolean;
}) {
  const { toast } = useToast();
  const { address, isConnected } = useAppKitAccount();
  const { chainId, switchNetwork } = useAppKitNetwork();
  const [busy, setBusy] = useState<null | "refund" | "retry" | "local">(null);
  const [valueEth, setValueEth] = useState("");
  const [suggested, setSuggested] = useState<bigint | null>(null);

  const onHub = isConnected && Number(chainId) === ctx.hubChainId;
  const isHandler =
    !!address && msg.failedMessageHandler !== ZERO && msg.failedMessageHandler.toLowerCase() === address.toLowerCase();
  const isSvm = state.svmLanes.some((l) => l.selector === msg.srcId && l.enabled);
  const inbound = msg.inbound;
  // Mirrors the on-chain gate: bounce is blocked only when the sender opted into local-only
  // recovery AND designated a handler (a handler-less message always stays refundable).
  const bounceBlocked = msg.onlyLocalRefund && msg.failedMessageHandler !== ZERO;

  // Suggest a bounce fee (surplus is refunded on-chain, so this is only a hint).
  useEffect(() => {
    if (resolved || msg.tokens.length === 0) return;
    let cancelled = false;
    suggestRefundToSourceFee({
      hubClient: ctx.client,
      adapter: ctx.adapter,
      channel: msg.channel,
      srcId: BigInt(msg.srcId || "0"),
      sender: msg.sender,
      token: msg.tokens[0].token,
      amount: msg.tokens[0].amount,
      lzOft: msg.lzOft,
      isSvm,
    })
      .then((f) => {
        if (!cancelled && f) {
          setSuggested(f);
          setValueEth(fmtUnits(f, 18));
        }
      })
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [msg.guid]); // eslint-disable-line react-hooks/exhaustive-deps

  function parsedValue(): bigint {
    try {
      return valueEth ? parseEther(valueEth as `${number}`) : (suggested ?? 0n);
    } catch {
      return suggested ?? 0n;
    }
  }

  function requireHub(): boolean {
    if (onHub) return true;
    const net = appKitNetworkById(ctx.hubChainId);
    if (net) switchNetwork?.(net);
    else
      toast({
        title: "Network not registered",
        description: `${ctx.chain.name} (chain ${ctx.hubChainId}) is not in the wallet's network list.`,
        variant: "destructive",
      });
    return false;
  }

  async function run(kind: "refund" | "retry" | "local", fn: () => Promise<{ txHash: string }>) {
    if (!address || !requireHub()) return;
    setBusy(kind);
    try {
      const { txHash } = await fn();
      toast({ title: "Submitted", description: txHash.slice(0, 12) + "…" });
      onResolved();
    } catch (e: any) {
      toast({ title: "Failed", description: shortErr(e), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  const nativeSym = ctx.chain.nativeCurrency.symbol;

  return (
    <Card>
      <CardContent className="p-4 space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 space-y-1">
            <span className="font-mono text-xs break-all">{msg.guid}</span>
            {msg.reasonDecoded && (
              <p className="text-xs text-destructive break-words">{msg.reasonDecoded}</p>
            )}
          </div>
          <Badge variant={msg.isRefunded ? "secondary" : resolved ? "secondary" : "destructive"}>
            {msg.isRefunded ? "REFUNDED" : resolved ? "RESOLVED" : "FAILED"}
          </Badge>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          <Field label="Channel">
            <Badge variant="outline" className="text-[10px]">{msg.channel}</Badge>
          </Field>
          <Field label="Source">
            <span className="text-xs">{msg.srcLabel}</span>
          </Field>
          <Field label="Failed-message handler">
            {msg.failedMessageHandler !== ZERO ? (
              <AddressChip address={msg.failedMessageHandler} explorerUrl={state.meta.explorerUrl} />
            ) : (
              <span className="text-muted-foreground text-xs">none (bounce-to-source only)</span>
            )}
          </Field>
          <Field label="Local refund only">
            <span className="text-xs">{msg.onlyLocalRefund ? "yes (bounce disabled)" : "no"}</span>
          </Field>
        </div>

        {msg.tokens.length > 0 && (
          <div className="space-y-1">
            <p className="text-[11px] uppercase tracking-wide text-muted-foreground">Held tokens</p>
            {msg.tokens.map((t, i) => {
              const meta = lookupToken(state, t.token);
              return (
                <div key={i} className="flex items-center justify-between text-sm">
                  <AddressChip address={t.token} explorerUrl={state.meta.explorerUrl} />
                  <span className="font-mono">
                    {meta ? `${fmtUnits(t.amount, meta.decimals)} ${meta.symbol}` : t.amount.toString()}
                  </span>
                </div>
              );
            })}
          </div>
        )}

        {!resolved && (
          <div className="space-y-2 pt-1">
            {!onHub && isConnected && (
              <Button variant="outline" size="sm" className="w-full" onClick={requireHub} data-testid="button-switch-hub">
                Switch wallet to {ctx.chain.name} (hub) to recover
              </Button>
            )}

            <div className="flex items-end gap-2">
              <div className="flex-1 space-y-1">
                <label className="text-[11px] text-muted-foreground">
                  Native to attach ({nativeSym}) — surplus refunded{suggested !== null ? ` · suggested ~${fmtUnits(padFee(suggested, 0), 18)}` : ""}
                </label>
                <Input
                  value={valueEth}
                  inputMode="decimal"
                  placeholder="0.0"
                  onChange={(e) => setValueEth(e.target.value)}
                  data-testid={`input-recover-value-${msg.guid}`}
                />
              </div>
            </div>

            <div className="flex flex-wrap gap-2">
              <Button
                size="sm"
                onClick={() =>
                  run("refund", () =>
                    refundToSource({
                      hubChain: ctx.chain,
                      adapter: ctx.adapter,
                      inbound: inbound!,
                      account: getAddress(address!),
                      value: parsedValue(),
                    }),
                  )
                }
                disabled={!onHub || !inbound || bounceBlocked || busy !== null}
                data-testid={`button-refund-${msg.guid}`}
              >
                {busy === "refund" ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : <ArrowLeftRight className="w-4 h-4 mr-2" />}
                Bounce to source
              </Button>
              <Button
                size="sm"
                variant="outline"
                onClick={() =>
                  run("retry", () =>
                    retryFailedMessage({
                      hubChain: ctx.chain,
                      adapter: ctx.adapter,
                      inbound: inbound!,
                      account: getAddress(address!),
                      value: parsedValue(),
                    }),
                  )
                }
                disabled={!onHub || !inbound || !isHandler || busy !== null}
                data-testid={`button-retry-${msg.guid}`}
              >
                {busy === "retry" ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : <RotateCcw className="w-4 h-4 mr-2" />}
                Retry
              </Button>
              <Button
                size="sm"
                variant="outline"
                onClick={() =>
                  run("local", () =>
                    refundLocal({
                      hubChain: ctx.chain,
                      adapter: ctx.adapter,
                      inbound: inbound!,
                      to: getAddress(address!) as Address,
                      account: getAddress(address!),
                    }),
                  )
                }
                disabled={!onHub || !inbound || !isHandler || busy !== null}
                data-testid={`button-local-${msg.guid}`}
              >
                {busy === "local" ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : <Undo2 className="w-4 h-4 mr-2" />}
                Refund local
              </Button>
            </div>
            {!inbound && (
              <p className="text-xs text-destructive">
                Could not decode the captured Inbound from the MessageFailed event, so recovery calls cannot be built.
              </p>
            )}
            {bounceBlocked && (
              <p className="text-xs text-muted-foreground">
                This message opted into local-only recovery: bounce-to-source is disabled and only the handler can retry or refund locally.
              </p>
            )}
            {!isHandler && (
              <p className="text-xs text-muted-foreground">
                Retry / refund-local are restricted to the message's failed-message handler.
                {msg.failedMessageHandler !== ZERO ? ` (${msg.failedMessageHandler})` : " This message has none — use bounce-to-source."}
              </p>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function lookupToken(state: AdapterState, token: string): { symbol: string; decimals: number } | undefined {
  const t = token.toLowerCase();
  const v = state.vault;
  if (!v) return undefined;
  if (v.underlying.address.toLowerCase() === t) return { symbol: v.underlying.symbol, decimals: v.underlying.decimals };
  if (v.vault.toLowerCase() === t) return { symbol: v.share.symbol, decimals: v.share.decimals };
  return undefined;
}

function shortErr(e: any): string {
  const msg = e?.shortMessage || e?.details || e?.message || String(e);
  return msg.length > 200 ? msg.slice(0, 200) + "…" : msg;
}
