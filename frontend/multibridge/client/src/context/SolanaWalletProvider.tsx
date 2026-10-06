import { useMemo, useState, createContext, useContext, useCallback } from "react";
import { ConnectionProvider, WalletProvider } from "@solana/wallet-adapter-react";
import { WalletModalProvider } from "@solana/wallet-adapter-react-ui";
import { PhantomWalletAdapter } from "@solana/wallet-adapter-phantom";
import { SolflareWalletAdapter } from "@solana/wallet-adapter-solflare";
import { BackpackWalletAdapter } from "@solana/wallet-adapter-backpack";
import { clusterApiUrl } from "@solana/web3.js";
import type { SolanaNetwork } from "@/config/solana.config";
import { SOLANA_NETWORKS } from "@/config/solana.config";

import "@solana/wallet-adapter-react-ui/styles.css";

interface SolanaNetworkContextType {
  network: SolanaNetwork;
  setNetwork: (network: SolanaNetwork) => void;
  endpoint: string;
  chainConfig: typeof SOLANA_NETWORKS["devnet"];
}

const SolanaNetworkContext = createContext<SolanaNetworkContextType>({
  network: "devnet",
  setNetwork: () => {},
  endpoint: SOLANA_NETWORKS.devnet.endpoint,
  chainConfig: SOLANA_NETWORKS.devnet,
});

export function useSolanaNetwork() {
  return useContext(SolanaNetworkContext);
}

interface SolanaWalletProviderProps {
  children: React.ReactNode;
}

export function SolanaWalletProvider({ children }: SolanaWalletProviderProps) {
  const [network, setNetwork] = useState<SolanaNetwork>("devnet");
  
  const endpoint = useMemo(() => {
    // Use custom RPC from environment variable if available
    if (network === "devnet" && import.meta.env.VITE_SOLANA_DEVNET_RPC) {
      return import.meta.env.VITE_SOLANA_DEVNET_RPC;
    }
    if (network === "mainnet-beta" && import.meta.env.VITE_SOLANA_MAINNET_RPC) {
      return import.meta.env.VITE_SOLANA_MAINNET_RPC;
    }
    
    const config = SOLANA_NETWORKS[network];
    return config.endpoint || clusterApiUrl(network);
  }, [network]);

  const chainConfig = useMemo(() => SOLANA_NETWORKS[network], [network]);

  const wallets = useMemo(() => {
    const adapters = [
      new PhantomWalletAdapter(),
      new SolflareWalletAdapter(),
      new BackpackWalletAdapter(),
    ];
    
    // Filter out any adapters that might cause issues
    // Some adapters might use Wallet Standard API which requires signIn
    const validAdapters = adapters.filter((adapter) => {
      try {
        // Check if adapter has required methods
        if (!adapter || typeof adapter.connect !== 'function') {
          console.warn(`Skipping invalid adapter: ${adapter?.name || 'unknown'}`);
          return false;
        }
        return true;
      } catch (error) {
        console.warn(`Error checking adapter ${adapter?.name || 'unknown'}:`, error);
        return false;
      }
    });
    
    console.log("Initialized Solana wallet adapters:", validAdapters.map(a => a.name));
    
    return validAdapters;
  }, []);

  const handleSetNetwork = useCallback((newNetwork: SolanaNetwork) => {
    setNetwork(newNetwork);
  }, []);

  const networkContextValue = useMemo(
    () => ({ network, setNetwork: handleSetNetwork, endpoint, chainConfig }),
    [network, handleSetNetwork, endpoint, chainConfig]
  );

  return (
    <SolanaNetworkContext.Provider value={networkContextValue}>
      <ConnectionProvider endpoint={endpoint}>
        <WalletProvider 
          wallets={wallets} 
          autoConnect={false}
          localStorageKey="solana-wallet"
          onError={(error, adapter) => {
            console.error("Solana wallet error:", error);
            console.error("Error name:", error.name);
            console.error("Error message:", error.message);
            console.error("Error stack:", error.stack);
            console.error("Adapter:", adapter?.name || "unknown");
            
            // Check if this is a Wallet Standard signIn error
            if (error.message?.includes("signIn") || error.name === "WalletConnectionError") {
              console.warn("Wallet Standard signIn error detected. This may indicate a compatibility issue with the wallet.");
            }
          }}
        >
          <WalletModalProvider>
            {children}
          </WalletModalProvider>
        </WalletProvider>
      </ConnectionProvider>
    </SolanaNetworkContext.Provider>
  );
}
