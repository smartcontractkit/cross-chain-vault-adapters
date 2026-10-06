import { useState } from "react";
import { ArrowDownToLine, ArrowUpFromLine, Layers, Coins } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { AddressChip, Field, EmptyState } from "./ui";
import { SendDialog } from "./SendDialog";
import { fmtCompact, fmtUnits } from "@/lib/adapter/format";
import type { AdapterContext, AdapterState } from "@/lib/adapter/state";
import type { VaultAction } from "@/lib/adapter/send";

interface Props {
  ctx: AdapterContext;
  state: AdapterState;
}

export function VaultsSection({ ctx, state }: Props) {
  const [dialog, setDialog] = useState<VaultAction | null>(null);
  const v = state.vault;

  if (!v) {
    return (
      <EmptyState>
        Could not read the fixed vault (<span className="font-mono">s_vault()</span> /{" "}
        <span className="font-mono">s_asset()</span>) from this adapter. Confirm the address is a
        deployed <span className="font-mono">CrossChainVaultAdapter</span> clone.
      </EmptyState>
    );
  }

  return (
    <div className="space-y-4">
      <Card className="overflow-hidden">
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
            <Badge variant="default">ERC-4626</Badge>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <Field label="Vault / share token">
              <AddressChip address={v.vault} explorerUrl={state.meta.explorerUrl} />
            </Field>
            <Field label="Underlying asset">
              <span className="flex items-center gap-1.5">
                <Coins className="w-3.5 h-3.5 text-muted-foreground" />
                {v.underlying.symbol}
                <AddressChip address={v.underlying.address} explorerUrl={state.meta.explorerUrl} />
              </span>
            </Field>
            <Field label="Total assets">
              <span className="font-mono">
                {fmtCompact(v.totalAssets, v.underlying.decimals)} {v.underlying.symbol}
              </span>
            </Field>
            <Field label="Total supply">
              <span className="font-mono">
                {fmtCompact(v.totalSupply, v.share.decimals)} {v.share.symbol}
              </span>
            </Field>
            {v.exchangeRate !== undefined && (
              <Field label="Exchange rate">
                <span className="font-mono">
                  1 {v.share.symbol} ≈ {fmtUnits(v.exchangeRate, v.underlying.decimals)} {v.underlying.symbol}
                </span>
              </Field>
            )}
            <Field label="Decimals">
              <span className="font-mono text-xs">
                share {v.share.decimals} · asset {v.underlying.decimals}
              </span>
            </Field>
          </div>

          <div className="flex gap-2 pt-1">
            <Button className="flex-1" onClick={() => setDialog("deposit")} data-testid="button-deposit">
              <ArrowDownToLine className="w-4 h-4 mr-2" /> Deposit asset
            </Button>
            <Button className="flex-1" variant="outline" onClick={() => setDialog("redeem")} data-testid="button-redeem">
              <ArrowUpFromLine className="w-4 h-4 mr-2" /> Redeem shares
            </Button>
          </div>
        </CardContent>
      </Card>

      {dialog && (
        <SendDialog open onClose={() => setDialog(null)} ctx={ctx} state={state} vault={v} action={dialog} />
      )}
    </div>
  );
}
