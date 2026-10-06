import { PublicKey } from "@solana/web3.js";

export type SolanaNetwork = "devnet" | "mainnet-beta";

export interface SolanaChainConfig {
  name: string;
  endpoint: string;
  chainSelector: string;
  programId: string;
  tokens: {
    usdc: string;
    nativeMint: string;
    poolToken?: string;
  };
  lookupTables: {
    deposit?: string;
    withdrawal?: string;
  };
}

export interface EVMDestinationChain {
  name: string;
  chainId: number;
  chainSelector: string;
  isTestnet: boolean;
}

export const SOLANA_NETWORKS: Record<SolanaNetwork, SolanaChainConfig> = {
  devnet: {
    name: "Solana Devnet",
    endpoint: "https://api.devnet.solana.com",
    chainSelector: "16423721717087811551",
    programId: "Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C",
    tokens: {
      usdc: "4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU",
      nativeMint: "So11111111111111111111111111111111111111112",
      poolToken: "6Sn78bdY12h6j5wVzeXqYrTZboKPqBtqjB4p5xsRNFaX",
    },
    lookupTables: {
      deposit: "B3MZq6GXFCto2qH2wN3Mvoc4vW8ku6KGbMrihwqVwB1S",
      withdrawal: "7wSANc1A7o6SY5B8C4NWYJMUwM8kDTXiQEYEffvW8vJ9",
    },
  },
  "mainnet-beta": {
    name: "Solana Mainnet",
    endpoint: "https://api.mainnet-beta.solana.com",
    chainSelector: "124615329519749607", // Solana mainnet chain selector from Chainlink CCIP docs
    programId: "Ccip842gzYHhvdDkSyi2YVCoAWPbYJoApMFzSxQroE9C", // Router program ID (same as devnet, upgradable)
    tokens: {
      usdc: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", // USDC mainnet mint
      nativeMint: "So11111111111111111111111111111111111111112", // WSOL
    },
    lookupTables: {},
  },
};

/**
 * Known OffRamp addresses on destination EVM chains for Solana source.
 * Pass message.offRampAddress to estimateReceiveExecution to bypass discoverOffRamp,
 * avoiding getSourceChainConfig BAD_DATA when decoding Solana source config.
 * Populate from CCIP directory: docs.chain.link/ccip/directory/testnet/chain/ethereum-testnet-sepolia
 * Look for inbound lane from Solana Devnet (selector 16423721717087811551).
 */
export const SOLANA_TO_EVM_OFFRAMPS: Partial<Record<string, string>> = {
  // Add when verified: "16015286601757825753": "0x...", // Sepolia
};

export const EVM_DESTINATION_CHAINS: EVMDestinationChain[] = [
  {
    name: "Ethereum Sepolia",
    chainId: 11155111,
    chainSelector: "16015286601757825753",
    isTestnet: true,
  },
  {
    name: "Base Sepolia",
    chainId: 84532,
    chainSelector: "10344971235874465080",
    isTestnet: true,
  },
  {
    name: "Ethereum Mainnet",
    chainId: 1,
    chainSelector: "5009297550715157269",
    isTestnet: false,
  },
  {
    name: "Base",
    chainId: 8453,
    chainSelector: "15971525489660198786",
    isTestnet: false,
  },
  {
    name: "Arbitrum One",
    chainId: 42161,
    chainSelector: "4949039107694359620",
    isTestnet: false,
  },
  {
    name: "Polygon",
    chainId: 137,
    chainSelector: "4051577828743386545",
    isTestnet: false,
  },
  {
    name: "Optimism",
    chainId: 10,
    chainSelector: "3734403246176062136",
    isTestnet: false,
  },
];

export const MAPLE_SOLANA_PRESET = {
  sourceNetwork: "devnet" as SolanaNetwork,
  destinationChainSelector: "16015286601757825753", // Ethereum Sepolia
  receiver: "0x3bAb429d3e4fDa281Af9D6A41A8ECafB894eFf1e",
  pool: "0x3EB612858EE843eBb14Df37b9Ec2c7c82B23eE2B",
  gasLimit: 600000,
  structDefinition: `struct UniversalMessage {
    bytes32 universalSenderAddress;
    address pool;
    bytes32 metaData;
}`,
};

export const KNOWN_FEE_QUOTERS = [
  "FeeQhewH1cd6ZyHqhfMiKAQntgzPT6bWwK26cJ5qSFo6", // USDC feeQuoter
  "FeeQPGkKDeRV1MgoYfMH6L8o3KeuYjwUZrgn4LRKfjHi", // Pool token feeQuoter
];

export function getNetworkConfig(network: SolanaNetwork): SolanaChainConfig {
  return SOLANA_NETWORKS[network];
}

export function getEVMDestinationBySelector(chainSelector: string): EVMDestinationChain | undefined {
  return EVM_DESTINATION_CHAINS.find((c) => c.chainSelector === chainSelector);
}

export function getProgramId(network: SolanaNetwork): PublicKey {
  return new PublicKey(SOLANA_NETWORKS[network].programId);
}

export function getTokenMint(network: SolanaNetwork, token: "usdc" | "nativeMint" | "poolToken"): PublicKey | null {
  const mint = SOLANA_NETWORKS[network].tokens[token];
  return mint ? new PublicKey(mint) : null;
}
