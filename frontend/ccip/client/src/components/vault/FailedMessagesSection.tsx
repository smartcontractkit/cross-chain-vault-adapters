import { useState } from "react";
import { getAddress, type Hex } from "viem";
import { useAppKitAccount, useAppKitNetwork } from "@reown/appkit/react";
import { AlertTriangle, Loader2, RotateCcw, Undo2, ExternalLink } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { useToast } from "@/hooks/use-toast";
import { AddressChip, Field, EmptyState } from "./ui";
import { fmtUnits } from "@/lib/adapter/format";
import { ccipExplorerUrl } from "@/lib/adapter/networks";
import { refundFailedMessage, recoverFailedMessageLocally, padFee } from "@/lib/adapter/actions";
import { appKitNetworkById } from "@/config/web3.config";
import type { AdapterContext, AdapterState, FailedMessage } from "@/lib/adapter/state";

interface Props {
  ctx: AdapterContext;
  state: AdapterState;
  onResolved: () => void;
}

export function FailedMessagesSection({ ctx, state, onResolved }: Props) {
  const open = state.failedMessages.filter((m) => m.errorCode === "BASIC");
  const resolved = state.failedMessages.filter((m) => m.errorCode === "RESOLVED");

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
            <FailedRow key={m.messageId} ctx={ctx} state={state} msg={m} onResolved={onResolved} />
          ))}
        </div>
      )}
      {resolved.length > 0 && (
        <div className="space-y-3">
          <p className="text-sm font-medium text-muted-foreground">Resolved ({resolved.length})</p>
          {resolved.map((m) => (
            <FailedRow key={m.messageId} ctx={ctx} state={state} msg={m} onResolved={onResolved} resolved />
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
  const [busy, setBusy] = useState<null | "refund" | "recover">(null);

  const onHub = isConnected && Number(chainId) === ctx.hubChainId;
  const isLocalRefundOwner =
    !!address && msg.localRecoveryAddress &&
    msg.localRecoveryAddress.toLowerCase() === address.toLowerCase();

  async function doRefund() {
    if (!address) return;
    setBusy("refund");
    try {
      const fee = msg.requiredRefundFee ?? 0n;
      const value = padFee(fee, 20);
      const { txHash } = await refundFailedMessage({
        hubChain: ctx.chain,
        adapter: ctx.adapter,
        messageId: msg.messageId,
        account: getAddress(address),
        value,
      });
      toast({ title: "Refund submitted", description: txHash.slice(0, 12) + "…" });
      onResolved();
    } catch (e: any) {
      toast({ title: "Refund failed", description: shortErr(e), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  async function doRecover() {
    if (!address) return;
    setBusy("recover");
    try {
      const { txHash } = await recoverFailedMessageLocally({
        hubChain: ctx.chain,
        adapter: ctx.adapter,
        messageId: msg.messageId,
        account: getAddress(address),
      });
      toast({ title: "Local recovery submitted", description: txHash.slice(0, 12) + "…" });
      onResolved();
    } catch (e: any) {
      toast({ title: "Recovery failed", description: shortErr(e), variant: "destructive" });
    } finally {
      setBusy(null);
    }
  }

  return (
    <Card>
      <CardContent className="p-4 space-y-3">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 space-y-1">
            <div className="flex items-center gap-2">
              <span className="font-mono text-xs break-all">{msg.messageId}</span>
            </div>
            <a href={ccipExplorerUrl(msg.messageId)} target="_blank" rel="noreferrer" className="text-xs text-primary inline-flex items-center gap-1">
              CCIP Explorer <ExternalLink className="w-3 h-3" />
            </a>
          </div>
          <Badge variant={resolved ? "secondary" : "destructive"}>{msg.errorCode}</Badge>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-3 gap-3">
          <Field label="Source chain">
            <span>{msg.sourceLabel}</span>
          </Field>
          <Field label="Original sender">
            <span className="font-mono text-xs break-all">{msg.sender}</span>
          </Field>
          <Field label="Local refund addr">
            {msg.localRefundAddress && msg.localRefundAddress !== "0x0000000000000000000000000000000000000000" ? (
              <AddressChip address={msg.localRefundAddress} explorerUrl={state.meta.explorerUrl} />
            ) : (
              <span className="text-muted-foreground text-xs">none</span>
            )}
          </Field>
        </div>

        {msg.destTokenAmounts.length > 0 && (
          <div className="space-y-1">
            <p className="text-[11px] uppercase tracking-wide text-muted-foreground">Stuck tokens</p>
            {msg.destTokenAmounts.map((t, i) => {
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
              <Button
                variant="outline"
                size="sm"
                className="w-full"
                onClick={() => {
                  const net = appKitNetworkById(ctx.hubChainId);
                  if (net) switchNetwork?.(net);
                  else
                    toast({
                      title: "Network not registered",
                      description: `${ctx.chain.name} (chain ${ctx.hubChainId}) is not in the wallet's network list. Add it in web3.config.ts.`,
                      variant: "destructive",
                    });
                }}
                data-testid="button-switch-hub"
              >
                Switch wallet to {ctx.chain.name} (hub) to recover
              </Button>
            )}
            <div className="flex flex-wrap gap-2">
              <Button
                size="sm"
                onClick={doRefund}
                disabled={!onHub || !msg.canRefund || busy !== null}
                data-testid={`button-refund-${msg.messageId}`}
              >
                {busy === "refund" ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : <RotateCcw className="w-4 h-4 mr-2" />}
                Cross-chain refund
                {msg.requiredRefundFee !== undefined && msg.canRefund && (
                  <span className="ml-1 text-xs opacity-80">
                    (~{fmtUnits(padFee(msg.requiredRefundFee, 20), 18)} {ctx.chain.nativeCurrency.symbol})
                  </span>
                )}
              </Button>
              <Button
                size="sm"
                variant="outline"
                onClick={doRecover}
                disabled={!onHub || !msg.canRecoverLocally || !isLocalRefundOwner || busy !== null}
                data-testid={`button-recover-${msg.messageId}`}
              >
                {busy === "recover" ? <Loader2 className="w-4 h-4 mr-2 animate-spin" /> : <Undo2 className="w-4 h-4 mr-2" />}
                Local recovery
              </Button>
            </div>
            {!msg.canRefund && (
              <p className="text-xs text-muted-foreground">
                Cross-chain refund unavailable right now (lane/extraArgs not quotable). Try local recovery if you are the refund address.
              </p>
            )}
            {msg.canRecoverLocally && !isLocalRefundOwner && (
              <p className="text-xs text-muted-foreground">
                Local recovery is restricted to {msg.localRecoveryAddress}.
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
  for (const v of state.vaults) {
    if (v.underlying.address.toLowerCase() === t) return { symbol: v.underlying.symbol, decimals: v.underlying.decimals };
    if (v.target.toLowerCase() === t) return { symbol: v.share.symbol, decimals: v.share.decimals };
  }
  return undefined;
}

function shortErr(e: any): string {
  const msg = e?.shortMessage || e?.details || e?.message || String(e);
  return msg.length > 200 ? msg.slice(0, 200) + "…" : msg;
}
