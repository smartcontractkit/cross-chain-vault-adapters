"use client";

import { useEffect, type ReactNode } from "react";
import { createAppKit } from "@reown/appkit/react";
import { EthersAdapter } from "@reown/appkit-adapter-ethers";
import { projectId, networks, metadata, defaultNetwork } from "@/config/web3.config";
import { themeConfig, applyTheme } from "@/config/theme.config";

const hasProjectId = Boolean(projectId);

if (!hasProjectId) {
  console.warn("Warning: VITE_REOWN_PROJECT_ID is not set. Wallet connection will not work.");
}

if (hasProjectId) {
  const ethersAdapter = new EthersAdapter();

  const { colors } = themeConfig;
  const primaryHsl = `hsl(${colors.primary.hue}, ${colors.primary.saturation}%, ${colors.primary.lightness}%)`;

  createAppKit({
    adapters: [ethersAdapter],
    networks,
    projectId,
    metadata,
    defaultNetwork,
    features: {
      analytics: false,
    },
    themeMode: "dark",
    themeVariables: {
      "--w3m-accent": primaryHsl,
      "--w3m-border-radius-master": "1px",
    },
  });
}

interface Web3ProviderProps {
  children: ReactNode;
}

export function Web3Provider({ children }: Web3ProviderProps) {
  useEffect(() => {
    applyTheme();
  }, []);

  return <>{children}</>;
}
