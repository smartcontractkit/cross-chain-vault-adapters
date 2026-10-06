import { Switch, Route, Router as WouterRouter } from "wouter";
import { useHashLocation } from "wouter/use-hash-location";
import { queryClient } from "./lib/queryClient";
import { QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Web3Provider } from "@/context/Web3Provider";
import { SolanaWalletProvider } from "@/context/SolanaWalletProvider";
import { Layout } from "@/components/layout/Layout";
import VaultDashboard from "@/pages/vault-dashboard";
import ReceiverMonitor from "@/pages/receiver-monitor";
import NotFound from "@/pages/not-found";

function Router() {
  // Hash-based routing keeps the SPA working under any base path (e.g. GitHub Pages
  // project sites) without server-side history fallbacks.
  return (
    <WouterRouter hook={useHashLocation}>
      <Switch>
        <Route path="/" component={VaultDashboard} />
        <Route path="/monitor" component={ReceiverMonitor} />
        <Route component={NotFound} />
      </Switch>
    </WouterRouter>
  );
}

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <Web3Provider>
          <SolanaWalletProvider>
            <Layout>
              <Router />
            </Layout>
          </SolanaWalletProvider>
        </Web3Provider>
        <Toaster />
      </TooltipProvider>
    </QueryClientProvider>
  );
}

export default App;
