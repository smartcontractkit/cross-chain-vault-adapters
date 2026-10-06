import { useState } from "react";
import { isAddress } from "viem";
import { Vault, ArrowRight, Loader2, Boxes } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { NetworkCombobox } from "./NetworkCombobox";
import { KNOWN_ADAPTERS } from "@/config/adapters.config";
import { getChainById } from "@/config/ccip.config";
import type { LoadedAdapter } from "@/hooks/useAdapterState";

interface Props {
  onLoad: (loaded: LoadedAdapter) => void;
  loading?: boolean;
  error?: string;
}

export function AdapterLoader({ onLoad, loading, error }: Props) {
  const [address, setAddress] = useState("");
  const [hubChainId, setHubChainId] = useState<number | undefined>(11155111);

  const addrValid = isAddress(address);
  const canSubmit = addrValid && !!hubChainId && !loading;

  return (
    <div className="max-w-2xl mx-auto w-full space-y-6">
      <div className="text-center space-y-3">
        <div className="inline-flex items-center justify-center w-14 h-14 rounded-2xl bg-primary/10 text-primary mb-1">
          <Vault className="w-7 h-7" />
        </div>
        <h1 className="font-display text-3xl font-bold tracking-tight">Cross-Chain Vault Dashboard</h1>
        <p className="text-muted-foreground max-w-lg mx-auto">
          Paste a <span className="font-mono text-foreground">CrossChainVaultAdapter</span> address and
          pick the network it is deployed on to inspect its state and send deposit / redeem messages
          over CCIP, LayerZero OFT, or Stargate — plus recover failed messages.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Load an adapter</CardTitle>
          <CardDescription>Reads are performed against the hub chain's RPC.</CardDescription>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="space-y-2">
            <Label htmlFor="adapter-address">Adapter address</Label>
            <Input
              id="adapter-address"
              data-testid="input-adapter-address"
              placeholder="0x..."
              value={address}
              spellCheck={false}
              className="font-mono"
              onChange={(e) => setAddress(e.target.value.trim())}
            />
            {address && !addrValid && (
              <p className="text-xs text-destructive">Enter a valid EVM address.</p>
            )}
          </div>

          <div className="space-y-2">
            <Label>Hub network</Label>
            <NetworkCombobox value={hubChainId} onChange={setHubChainId} />
          </div>

          {error && (
            <div className="rounded-md border border-destructive/40 bg-destructive/10 px-3 py-2 text-sm text-destructive">
              {error}
            </div>
          )}

          <Button
            className="w-full"
            disabled={!canSubmit}
            data-testid="button-load-adapter"
            onClick={() => canSubmit && onLoad({ address, hubChainId: hubChainId! })}
          >
            {loading ? (
              <>
                <Loader2 className="w-4 h-4 mr-2 animate-spin" /> Loading state...
              </>
            ) : (
              <>
                Load adapter <ArrowRight className="w-4 h-4 ml-2" />
              </>
            )}
          </Button>
        </CardContent>
      </Card>

      {KNOWN_ADAPTERS.length > 0 && (
        <Card>
          <CardHeader className="pb-3">
            <CardTitle className="text-sm flex items-center gap-2">
              <Boxes className="w-4 h-4 text-primary" /> Known deployments
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {KNOWN_ADAPTERS.map((a) => {
              const chain = getChainById(a.hubChainId);
              return (
                <button
                  key={`${a.adapterAddress}-${a.hubChainId}`}
                  data-testid={`known-adapter-${a.adapterAddress}`}
                  className="w-full text-left rounded-md border border-border px-3 py-2 hover:bg-accent/50 transition-colors"
                  onClick={() => {
                    setAddress(a.adapterAddress);
                    setHubChainId(a.hubChainId);
                  }}
                >
                  <div className="flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-medium truncate">{a.label ?? "Adapter"}</p>
                      <p className="text-xs font-mono text-muted-foreground truncate">{a.adapterAddress}</p>
                    </div>
                    <Badge variant="secondary" className="shrink-0">{chain?.name ?? a.hubChainId}</Badge>
                  </div>
                </button>
              );
            })}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
