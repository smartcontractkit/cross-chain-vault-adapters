import { useEffect, useState } from "react";
import { useAppKitAccount } from "@reown/appkit/react";
import { Loader2, Layers, Radio, AlertTriangle, Activity as ActivityIcon, Settings2 } from "lucide-react";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { useAdapterState, type LoadedAdapter } from "@/hooks/useAdapterState";
import { AdapterLoader } from "@/components/vault/AdapterLoader";
import { StateHeader } from "@/components/vault/StateHeader";
import { VaultsSection } from "@/components/vault/VaultsSection";
import { FailedMessagesSection } from "@/components/vault/FailedMessagesSection";
import { ActivityFeed } from "@/components/vault/ActivityFeed";
import { ConfigSection } from "@/components/vault/ConfigSection";
import { TrackedMessages } from "@/components/vault/TrackedMessages";

const LAST_KEY = "vault-last-adapter";

export default function VaultDashboard() {
  const { address } = useAppKitAccount();
  const [loaded, setLoaded] = useState<LoadedAdapter | null>(() => {
    try {
      const raw = localStorage.getItem(LAST_KEY);
      return raw ? (JSON.parse(raw) as LoadedAdapter) : null;
    } catch {
      return null;
    }
  });

  const { ctx, state, isLoading, isFetching, error, refetch } = useAdapterState(loaded);

  useEffect(() => {
    if (loaded) localStorage.setItem(LAST_KEY, JSON.stringify(loaded));
  }, [loaded]);

  if (!loaded || (error && !state)) {
    return (
      <AdapterLoader
        onLoad={setLoaded}
        loading={isLoading}
        error={error && loaded ? error.message : undefined}
      />
    );
  }

  if (isLoading || !ctx || !state) {
    return (
      <div className="flex flex-col items-center justify-center py-24 gap-3 text-muted-foreground">
        <Loader2 className="w-8 h-8 animate-spin text-primary" />
        <p>Reading adapter state on chain {loaded.hubChainId}…</p>
      </div>
    );
  }

  const openFailed = state.failedMessages.filter((m) => m.errorCode === "BASIC").length;

  return (
    <div className="space-y-6">
      <StateHeader
        state={state}
        connectedAddress={address}
        isFetching={isFetching}
        onRefresh={() => refetch()}
        onChangeAdapter={() => {
          localStorage.removeItem(LAST_KEY);
          setLoaded(null);
        }}
      />

      <Tabs defaultValue="vaults">
        <TabsList className="grid w-full grid-cols-5">
          <TabsTrigger value="vaults" data-testid="tab-vaults">
            <Layers className="w-4 h-4 mr-2" /> Vaults
          </TabsTrigger>
          <TabsTrigger value="messages" data-testid="tab-messages">
            <Radio className="w-4 h-4 mr-2" /> Messages
          </TabsTrigger>
          <TabsTrigger value="failed" data-testid="tab-failed">
            <AlertTriangle className="w-4 h-4 mr-2" /> Failed
            {openFailed > 0 && <Badge variant="destructive" className="ml-2 h-5 px-1.5">{openFailed}</Badge>}
          </TabsTrigger>
          <TabsTrigger value="activity" data-testid="tab-activity">
            <ActivityIcon className="w-4 h-4 mr-2" /> Activity
          </TabsTrigger>
          <TabsTrigger value="config" data-testid="tab-config">
            <Settings2 className="w-4 h-4 mr-2" /> Config
          </TabsTrigger>
        </TabsList>

        <TabsContent value="vaults" className="mt-6">
          <VaultsSection ctx={ctx} state={state} />
        </TabsContent>
        <TabsContent value="messages" className="mt-6">
          <TrackedMessages adapter={ctx.adapter} hubChainId={ctx.hubChainId} />
        </TabsContent>
        <TabsContent value="failed" className="mt-6">
          <FailedMessagesSection ctx={ctx} state={state} onResolved={() => refetch()} />
        </TabsContent>
        <TabsContent value="activity" className="mt-6">
          <ActivityFeed state={state} />
        </TabsContent>
        <TabsContent value="config" className="mt-6">
          <ConfigSection state={state} />
        </TabsContent>
      </Tabs>

      <p className="text-[11px] text-muted-foreground text-center">
        Scanned blocks {state.scan.fromBlock.toString()} – {state.scan.toBlock.toString()} on {state.meta.hubChainName}.
        Vault/chain/fee discovery relies on event logs in this range.
      </p>
    </div>
  );
}
