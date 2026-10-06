import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { ArrowDownToLine, ArrowUpFromLine, Route, Coins, Wallet, Link2, Cpu } from "lucide-react";
import { AddressChip, EmptyState } from "./ui";
import { fmtUnits } from "@/lib/adapter/format";
import type { AdapterState, AllowlistEntry } from "@/lib/adapter/state";

export function ConfigSection({ state }: { state: AdapterState }) {
  const inboundCcip = state.allowlists.filter((a) => a.kind === "ccipSrc");
  const inboundLz = state.allowlists.filter((a) => a.kind === "lzOft");
  const outboundCcip = state.allowlists.filter((a) => a.kind === "ccipDst");
  const outboundLz = state.allowlists.filter((a) => a.kind === "lzDst");
  const outboundSg = state.allowlists.filter((a) => a.kind === "stargateDst");

  return (
    <div className="space-y-6">
      {/* Inbound allowlists */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <ArrowDownToLine className="w-4 h-4 text-primary" /> Inbound sources (who may send here)
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <AllowlistGroup title="CCIP source chains" entries={inboundCcip} />
          <AllowlistGroup title="LayerZero OFTs / Stargate pools" entries={inboundLz} showOft />
        </CardContent>
      </Card>

      {/* Outbound allowlists */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <ArrowUpFromLine className="w-4 h-4 text-primary" /> Outbound destinations (return legs)
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <AllowlistGroup title="CCIP destinations" entries={outboundCcip} />
          <AllowlistGroup title="LayerZero OFT destinations" entries={outboundLz} />
          <AllowlistGroup title="Stargate destinations" entries={outboundSg} />
        </CardContent>
      </Card>

      {/* SVM lanes */}
      {state.svmLanes.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm flex items-center gap-2">
              <Cpu className="w-4 h-4 text-primary" /> Solana (SVM) CCIP lanes
            </CardTitle>
          </CardHeader>
          <CardContent>
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Selector</TableHead>
                  <TableHead>Enabled</TableHead>
                  <TableHead className="text-right">Compute units</TableHead>
                  <TableHead className="text-right">Out-of-order</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.svmLanes.map((l) => (
                  <TableRow key={l.selector}>
                    <TableCell className="font-mono text-xs">{l.selector}</TableCell>
                    <TableCell><Badge variant={l.enabled ? "default" : "secondary"}>{l.enabled ? "yes" : "no"}</Badge></TableCell>
                    <TableCell className="text-right font-mono">{l.computeUnits}</TableCell>
                    <TableCell className="text-right">{l.allowOutOfOrderExecution ? "yes" : "no"}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </CardContent>
        </Card>
      )}

      {/* Routes */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Route className="w-4 h-4 text-primary" /> Outbound routes (produced token → destination)
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.routes.length === 0 ? (
            <EmptyState>No explicit routes registered — the adapter falls back to the legacy destination-size default.</EmptyState>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Token</TableHead>
                  <TableHead>Destination</TableHead>
                  <TableHead>Rail</TableHead>
                  <TableHead>Endpoint</TableHead>
                  <TableHead className="text-right">Dst id</TableHead>
                  <TableHead className="text-right">On</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.routes.map((r, i) => (
                  <TableRow key={i}>
                    <TableCell><AddressChip address={r.token} explorerUrl={state.meta.explorerUrl} /></TableCell>
                    <TableCell className="text-xs">{r.destinationLabel}</TableCell>
                    <TableCell><Badge variant="outline" className="text-[10px]">{r.rail}</Badge></TableCell>
                    <TableCell>
                      {r.endpoint === "0x0000000000000000000000000000000000000000" ? (
                        <span className="text-muted-foreground text-xs">—</span>
                      ) : (
                        <AddressChip address={r.endpoint} explorerUrl={state.meta.explorerUrl} />
                      )}
                    </TableCell>
                    <TableCell className="text-right font-mono text-xs">{r.dstId}</TableCell>
                    <TableCell className="text-right"><Badge variant={r.enabled ? "default" : "secondary"} className="text-[10px]">{r.enabled ? "yes" : "no"}</Badge></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          {state.oftForToken.length > 0 && (
            <div className="mt-4 space-y-1">
              <p className="text-[11px] uppercase tracking-wide text-muted-foreground">OFT-for-token (legacy default + LZ bounce)</p>
              {state.oftForToken.map((o, i) => (
                <div key={i} className="flex items-center justify-between text-sm">
                  <AddressChip address={o.token} explorerUrl={state.meta.explorerUrl} />
                  <span className="text-muted-foreground text-xs">→</span>
                  <AddressChip address={o.oft} explorerUrl={state.meta.explorerUrl} />
                </div>
              ))}
            </div>
          )}
          {state.dstGas.length > 0 && (
            <div className="mt-4 space-y-1">
              <p className="text-[11px] uppercase tracking-wide text-muted-foreground">Destination gas overrides</p>
              {state.dstGas.map((g, i) => (
                <div key={i} className="flex items-center justify-between text-sm">
                  <span className="text-xs">{g.destinationLabel}</span>
                  <span className="font-mono text-xs">{g.gasLimit.toString()}</span>
                </div>
              ))}
            </div>
          )}
        </CardContent>
      </Card>

      {/* Inbound fees */}
      <Card>
        <CardHeader className="pb-3">
          <CardTitle className="text-sm flex items-center gap-2">
            <Link2 className="w-4 h-4 text-primary" /> Inbound fees (CCIP-origin bridged returns)
          </CardTitle>
        </CardHeader>
        <CardContent>
          {state.inboundFees.length === 0 ? (
            <EmptyState>No inbound fees configured.</EmptyState>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Outbound token</TableHead>
                  <TableHead>Destination</TableHead>
                  <TableHead className="text-right">Fee (raw)</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.inboundFees.map((f, i) => (
                  <TableRow key={i}>
                    <TableCell><AddressChip address={f.outboundToken} explorerUrl={state.meta.explorerUrl} /></TableCell>
                    <TableCell className="text-xs">{f.destinationLabel}</TableCell>
                    <TableCell className="text-right font-mono">{f.fee.toString()}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          <p className="mt-3 text-[11px] text-muted-foreground">
            LayerZero return-leg prefund required:{" "}
            <Badge variant={state.policy.requireLzReturnPrefunded ? "default" : "secondary"} className="text-[10px]">
              {state.policy.requireLzReturnPrefunded ? "yes" : "no"}
            </Badge>
          </p>
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
                  <TableHead>Token</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {state.collectedFees.map((f, i) => (
                  <TableRow key={i}>
                    <TableCell><AddressChip address={f.token} explorerUrl={state.meta.explorerUrl} /></TableCell>
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

function AllowlistGroup({
  title,
  entries,
  showOft,
}: {
  title: string;
  entries: AllowlistEntry[];
  showOft?: boolean;
}) {
  return (
    <div className="space-y-2">
      <p className="text-[11px] uppercase tracking-wide text-muted-foreground">{title}</p>
      {entries.length === 0 ? (
        <p className="text-xs text-muted-foreground">none</p>
      ) : (
        <div className="flex flex-wrap gap-2">
          {entries.map((e, i) => (
            <div key={i} className="rounded-md border border-border px-3 py-2 space-y-0.5">
              <div className="flex items-center gap-2">
                <span className="text-sm font-medium">{e.label}</span>
                <Badge variant={e.allowed ? "default" : "secondary"} className="text-[10px]">
                  {e.allowed ? "allowed" : "off"}
                </Badge>
              </div>
              <p className="text-[11px] font-mono text-muted-foreground">{e.id}</p>
              {showOft && e.oft && <p className="text-[11px] font-mono text-muted-foreground">{e.oft}</p>}
            </div>
          ))}
        </div>
      )}
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
