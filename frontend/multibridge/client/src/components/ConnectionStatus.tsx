import { useState, useEffect, useRef } from "react";
import { useAppKitAccount, useAppKitNetwork } from "@reown/appkit/react";
import { Wifi, WifiOff, AlertCircle, CheckCircle2 } from "lucide-react";
import { Badge } from "@/components/ui/badge";

const NETWORK_NAMES: Record<number, string> = {
  999: "HyperEVM",
  998: "HyperEVM Testnet",
  1: "Ethereum",
  11155111: "Sepolia",
  42161: "Arbitrum",
  137: "Polygon",
  10: "Optimism",
  8453: "Base",
};

function useWalletChainId() {
  const [chainId, setChainId] = useState<number | undefined>(undefined);
  const networkData = useAppKitNetwork();
  const lastChainIdRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    const ethereum = (window as any).ethereum;
    if (!ethereum) return;

    const getChainId = async () => {
      try {
        const hexChainId = await ethereum.request({ method: "eth_chainId" });
        const newChainId = parseInt(hexChainId, 16);
        if (newChainId !== lastChainIdRef.current) {
          lastChainIdRef.current = newChainId;
          setChainId(newChainId);
        }
      } catch (e) {
        // Silently fail
      }
    };

    getChainId();

    const intervalId = setInterval(getChainId, 1000);

    const handleChainChanged = (hexChainId: string) => {
      const newChainId = parseInt(hexChainId, 16);
      lastChainIdRef.current = newChainId;
      setChainId(newChainId);
    };

    ethereum.on?.("chainChanged", handleChainChanged);

    return () => {
      clearInterval(intervalId);
      ethereum.removeListener?.("chainChanged", handleChainChanged);
    };
  }, []);

  useEffect(() => {
    if (networkData?.chainId && typeof networkData.chainId === "number") {
      if (networkData.chainId !== lastChainIdRef.current) {
        lastChainIdRef.current = networkData.chainId;
        setChainId(networkData.chainId);
      }
    }
  }, [networkData?.chainId]);

  return chainId;
}

export function ConnectionStatus() {
  const accountData = useAppKitAccount();
  const currentChainId = useWalletChainId();
  
  const isConnected = accountData?.isConnected;
  const address = accountData?.address;

  const formatAddress = (addr: string) => {
    return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
  };

  const getNetworkName = (id: number | undefined) => {
    return id ? NETWORK_NAMES[id] || `Chain ${id}` : "Unknown";
  };

  if (!isConnected) {
    return (
      <Badge variant="secondary" className="gap-1" data-testid="badge-disconnected">
        <WifiOff className="h-3 w-3" />
        Disconnected
      </Badge>
    );
  }

  return (
    <div className="flex items-center gap-2">
      <Badge variant="default" className="gap-1" data-testid="badge-connected">
        <CheckCircle2 className="h-3 w-3" />
        {address ? formatAddress(address) : "Connected"}
      </Badge>
      
      {currentChainId && (
        <Badge variant="secondary" className="gap-1" data-testid="badge-network">
          <Wifi className="h-3 w-3" />
          {getNetworkName(currentChainId)}
        </Badge>
      )}
    </div>
  );
}

export function NetworkWarning() {
  const currentChainId = useWalletChainId();
  
  const isTestnet = currentChainId === 11155111 || currentChainId === 998;
  
  if (!isTestnet) return null;

  return (
    <div className="flex items-center gap-2 rounded-md bg-warning/10 px-3 py-2 text-sm" data-testid="warning-testnet">
      <AlertCircle className="h-4 w-4 text-warning" />
      <span className="text-warning">You are connected to a testnet</span>
    </div>
  );
}
