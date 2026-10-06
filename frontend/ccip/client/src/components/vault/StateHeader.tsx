import { RefreshCw, Vault, Network, Router as RouterIcon, ShieldCheck } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { AddressChip, StatPill, Field } from "./ui";
import type { AdapterState } from "@/lib/adapter/state";

interface Props {
  state: AdapterState;
  connectedAddress?: string;
  isFetching?: boolean;
  onRefresh: () => void;
  onChangeAdapter: () => void;
}

export function StateHeader({ state, connectedAddress, isFetching, onRefresh, onChangeAdapter }: Props) {
  const { meta, processing, roles } = state;
  const addr = connectedAddress?.toLowerCase();
  const walletRoles: string[] = [];
  if (addr) {
    if (roles.admins.some((a) => a.toLowerCase() === addr)) walletRoles.push("Admin");
    if (roles.feeSetters.some((a) => a.toLowerCase() === addr)) walletRoles.push("Fee Setter");
    if (roles.feeCollectors.some((a) => a.toLowerCase() === addr)) walletRoles.push("Fee Collector");
  }

  return (
    <Card>
      <CardContent className="p-5 space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="flex items-start gap-3">
            <div className="w-10 h-10 rounded-lg bg-primary/10 text-primary flex items-center justify-center shrink-0">
              <Vault className="w-5 h-5" />
            </div>
            <div className="space-y-1">
              <div className="flex items-center gap-2 flex-wrap">
                <h2 className="font-display text-xl font-bold leading-none">Vault Adapter</h2>
                <Badge variant="outline" className="font-mono text-[10px]">{meta.typeAndVersion}</Badge>
              </div>
              <AddressChip address={meta.adapter} explorerUrl={meta.explorerUrl} full />
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button variant="outline" size="sm" onClick={onRefresh} disabled={isFetching} data-testid="button-refresh-state">
              <RefreshCw className={`w-4 h-4 mr-2 ${isFetching ? "animate-spin" : ""}`} /> Refresh
            </Button>
            <Button variant="ghost" size="sm" onClick={onChangeAdapter} data-testid="button-change-adapter">
              Change
            </Button>
          </div>
        </div>

        <div className="grid grid-cols-2 md:grid-cols-4 gap-4 pt-1">
          <Field label="Hub network">
            <span className="flex items-center gap-1.5">
              <Network className="w-3.5 h-3.5 text-muted-foreground" />
              {meta.hubChainName}
            </span>
          </Field>
          <Field label="CCIP router">
            <span className="flex items-center gap-1.5">
              <RouterIcon className="w-3.5 h-3.5 text-muted-foreground" />
              <AddressChip address={meta.router} explorerUrl={meta.explorerUrl} />
            </span>
          </Field>
          <Field label="Your roles">
            {walletRoles.length ? (
              <span className="flex flex-wrap gap-1">
                {walletRoles.map((r) => (
                  <Badge key={r} variant="secondary" className="text-[10px]">
                    <ShieldCheck className="w-3 h-3 mr-1" />
                    {r}
                  </Badge>
                ))}
              </span>
            ) : (
              <span className="text-muted-foreground text-xs">{addr ? "No special roles" : "Wallet not connected"}</span>
            )}
          </Field>
          <Field label="Processing">
            <div className="flex flex-wrap gap-2">
              <StatPill label="Deposits" on={processing.depositsEnabled} />
              <StatPill label="Redeems" on={processing.redeemsEnabled} />
            </div>
          </Field>
        </div>
      </CardContent>
    </Card>
  );
}
