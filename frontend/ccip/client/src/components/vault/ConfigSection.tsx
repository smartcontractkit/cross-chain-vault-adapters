import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Link2, Coins, Wallet, ShieldCheck, Network } from "lucide-react";
import { AddressChip, EmptyState } from "./ui";
import { fmtUnits } from "@/lib/adapter/format";
import type { AdapterState } from "@/lib/adapter/state";

export function ConfigSection({ state }: { state: AdapterState }) {
  return (
    <div className="space-y-6">
      {/* Configured chains */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Network className="w-4 h-4 text-primary" /> Configured source chains
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.chains.length === 0 ? (
            <EmptyState>No chains configured.</EmptyState>
          ) : (
            <div className="flex flex-wrap gap-2">
              {state.chains.map((c) => (
                <div key={c.selector} className="rounded-md border border-border px-3 py-2 space-y-0.5">
                  <div className="flex items-center gap-2">
                    <span className="text-sm font-medium">{c.label}</span>
                    <Badge variant={c.type === "NONE" ? "secondary" : "default"} className="text-[10px]">
                      {c.type}
                    </Badge>
                  </div>
                  <p className="text-[11px] font-mono text-muted-foreground">{c.selector}</p>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Asset fees */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Link2 className="w-4 h-4 text-primary" /> Return-leg asset fees
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.assetFees.length === 0 ? (
            <EmptyState>No asset fees configured.</EmptyState>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Destination selector</TableHead>
                  <TableHead>Bridged token</TableHead>
                  <TableHead className="text-right">Fee (raw)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.assetFees.map((f, i) => (
                  <TableRow key={i}>
                    <TableCell className="font-mono text-xs">{f.destinationChainSelector}</TableCell>
                    <TableCell>
                      <AddressChip address={f.bridgedToken} explorerUrl={state.meta.explorerUrl} />
                    </TableCell>
                    <TableCell className="text-right font-mono">{f.fee.toString()}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* Collected fees */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Coins className="w-4 h-4 text-primary" /> Collected fees (treasury)
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.collectedFees.length === 0 ? (
            <EmptyState>No collected fees.</EmptyState>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Asset</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.collectedFees.map((f, i) => (
                  <TableRow key={i}>
                    <TableCell>
                      <AddressChip address={f.asset} explorerUrl={state.meta.explorerUrl} />
                    </TableCell>
                    <TableCell className="text-right font-mono">
                      {f.decimals !== undefined ? `${fmtUnits(f.amount, f.decimals)} ${f.symbol ?? ""}` : f.amount.toString()}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* CCV / finality */}
      {state.ccv.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm flex items-center gap-2">
              <ShieldCheck className="w-4 h-4 text-primary" /> CCV &amp; finality (per source)
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            {state.ccv.map((c) => (
              <div key={c.sourceChainSelector} className="rounded-md border border-border p-3 text-sm space-y-1">
                <p className="font-mono text-xs text-muted-foreground">selector {c.sourceChainSelector}</p>
                <p>Required CCVs: {c.requiredCCVs.length ? c.requiredCCVs.map((a) => <span key={a} className="font-mono text-xs mr-2">{a}</span>) : "none"}</p>
                <p>Optional CCVs: {c.optionalCCVs.length} (threshold {c.optionalThreshold})</p>
                <p className="text-xs text-muted-foreground">finality: {c.allowedFinalityConfig}</p>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {/* Roles */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Wallet className="w-4 h-4 text-primary" /> Roles &amp; governance
          </CardTitle>
        </CardHeader>
        <CardContent className="grid grid-cols-1 md:grid-cols-3 gap-4">
          <RoleColumn title="Admins" addrs={state.roles.admins} explorerUrl={state.meta.explorerUrl} />
          <RoleColumn title="Fee setters" addrs={state.roles.feeSetters} explorerUrl={state.meta.explorerUrl} />
          <RoleColumn title="Fee collectors" addrs={state.roles.feeCollectors} explorerUrl={state.meta.explorerUrl} />
        </CardContent>
      </Card>
    </div>
  );
}

function RoleColumn({ title, addrs, explorerUrl }: { title: string; addrs: string[]; explorerUrl: string }) {
  return (
    <div className="space-y-2">
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{title}</p>
      {addrs.length === 0 ? (
        <p className="text-xs text-muted-foreground">none</p>
      ) : (
        addrs.map((a) => (
          <div key={a}>
            <AddressChip address={a} explorerUrl={explorerUrl} />
          </div>
        ))
      )}
    </div>
  );
}
