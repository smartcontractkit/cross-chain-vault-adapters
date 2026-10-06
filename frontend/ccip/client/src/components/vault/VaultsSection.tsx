import { useState } from "react";
import { ArrowDownToLine, ArrowUpFromLine, Layers, Coins } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { AddressChip, Field, EmptyState } from "./ui";
import { SendDialog } from "./SendDialog";
import { fmtCompact, fmtUnits } from "@/lib/adapter/format";
import type { AdapterContext, AdapterState, VaultInfo } from "@/lib/adapter/state";
import type { VaultAction } from "@/lib/adapter/send";

interface Props {
  ctx: AdapterContext;
  state: AdapterState;
}

export function VaultsSection({ ctx, state }: Props) {
  const [dialog, setDialog] = useState<{ vault: VaultInfo; action: VaultAction } | null>(null);

  if (state.vaults.length === 0) {
    return (
      <EmptyState>
        No vault targets discovered from <span className="font-mono">TargetEnabled</span> logs in the scanned
        range. The adapter may have none enabled, or the deploy block predates the scan window.
      </EmptyState>
    );
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        {state.vaults.map((v) => {
          const depositReady = v.enabled && state.processing.depositsEnabled;
          const redeemReady = v.enabled && state.processing.redeemsEnabled;
          return (
            <Card key={v.target} className="overflow-hidden">
              <CardContent className="p-5 space-y-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-start gap-3">
                    <div className="w-9 h-9 rounded-lg bg-primary/10 text-primary flex items-center justify-center shrink-0">
                      <Layers className="w-4.5 h-4.5" />
                    </div>
                    <div>
                      <p className="font-semibold leading-tight">{v.share.name}</p>
                      <p className="text-xs text-muted-foreground">{v.share.symbol}</p>
                    </div>
                  </div>
                  <Badge variant={v.enabled ? "default" : "secondary"}>
                    {v.enabled ? "Enabled" : "Disabled"}
                  </Badge>
                </div>

                <div className="grid grid-cols-2 gap-4">
                  <Field label="Share token">
                    <AddressChip address={v.target} explorerUrl={state.meta.explorerUrl} />
                  </Field>
                  <Field label="Underlying">
                    <span className="flex items-center gap-1.5">
                      <Coins className="w-3.5 h-3.5 text-muted-foreground" />
                      {v.underlying.symbol}
                      <AddressChip address={v.underlying.address} explorerUrl={state.meta.explorerUrl} />
                    </span>
                  </Field>
                  <Field label="Total assets">
                    <span className="font-mono">{fmtCompact(v.totalAssets, v.underlying.decimals)} {v.underlying.symbol}</span>
                  </Field>
                  <Field label="Total supply">
                    <span className="font-mono">{fmtCompact(v.totalSupply, v.share.decimals)} {v.share.symbol}</span>
                  </Field>
                  {v.exchangeRate !== undefined && (
                    <Field label="Exchange rate">
                      <span className="font-mono">
                        1 {v.share.symbol} ≈ {fmtUnits(v.exchangeRate, v.underlying.decimals)} {v.underlying.symbol}
                      </span>
                    </Field>
                  )}
                  <Field label="Decimals">
                    <span className="font-mono text-xs">share {v.share.decimals} · asset {v.underlying.decimals}</span>
                  </Field>
                </div>

                <div className="flex gap-2 pt-1">
                  <Button
                    className="flex-1"
                    disabled={!depositReady}
                    onClick={() => setDialog({ vault: v, action: "deposit" })}
                    data-testid={`button-deposit-${v.target}`}
                  >
                    <ArrowDownToLine className="w-4 h-4 mr-2" /> Deposit
                  </Button>
                  <Button
                    className="flex-1"
                    variant="outline"
                    disabled={!redeemReady}
                    onClick={() => setDialog({ vault: v, action: "redeem" })}
                    data-testid={`button-redeem-${v.target}`}
                  >
                    <ArrowUpFromLine className="w-4 h-4 mr-2" /> Redeem
                  </Button>
                </div>
              </CardContent>
            </Card>
          );
        })}
      </div>

      {dialog && (
        <SendDialog
          open
          onClose={() => setDialog(null)}
          ctx={ctx}
          state={state}
          vault={dialog.vault}
          action={dialog.action}
        />
      )}
    </div>
  );
}
