// Import available networks from Reown/AppKit
// Note: Not all CCIP networks are available in Reown. Custom networks are defined below.
import {
  mainnet,
  arbitrum,
  polygon,
  optimism,
  base,
  avalanche,
  bsc,
  gnosis,
  sepolia,
  arbitrumSepolia,
  baseSepolia,
  optimismSepolia,
  avalancheFuji,
  polygonAmoy,
  bscTestnet,
  gnosisChiado,
  zkSync,
  zkSyncSepoliaTestnet,
  linea,
  lineaSepolia,
  scroll,
  scrollSepolia,
  mantle,
  mantleSepoliaTestnet,
  mode,
  modeTestnet,
  blast,
  blastSepolia,
  celo,
  celoAlfajores,
  holesky,
  zora,
  zoraSepolia,
  polygonZkEvm,
  polygonZkEvmCardona,
  fraxtal,
  fraxtalTestnet,
  metis,
  cronos,
  cronosTestnet,
  rootstock,
  rootstockTestnet,
  worldchain,
  lisk,
  liskSepolia,
} from "@reown/appkit/networks";
import type { AppKitNetwork } from "@reown/appkit/networks";

export const projectId = import.meta.env.VITE_REOWN_PROJECT_ID || "";

// ============================================
// CUSTOM NETWORKS (Not available in Reown)
// ============================================

// Mainnet Custom Networks
export const hyperEvmMainnet: AppKitNetwork = {
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
  blockExplorers: { default: { name: "HyperEVM Explorer", url: "https://explorer.hyperliquid.xyz" } },
};

export const shibarium: AppKitNetwork = {
  id: 109,
  name: "Shibarium",
  nativeCurrency: { name: "BONE", symbol: "BONE", decimals: 18 },
  rpcUrls: { default: { http: ["https://www.shibrpc.com"] } },
  blockExplorers: { default: { name: "Shibarium Explorer", url: "https://shibariumscan.io" } },
};

export const unichain: AppKitNetwork = {
  id: 130,
  name: "Unichain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.unichain.org"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://uniscan.xyz" } },
};

export const monadMainnet: AppKitNetwork = {
  id: 143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.monad.xyz"] } },
  blockExplorers: { default: { name: "Monad Explorer", url: "https://explorer.monad.xyz" } },
};

export const sonic: AppKitNetwork = {
  id: 146,
  name: "Sonic",
  nativeCurrency: { name: "Sonic", symbol: "S", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.soniclabs.com"] } },
  blockExplorers: { default: { name: "Sonic Explorer", url: "https://sonicscan.org" } },
};

export const hashkeyChain: AppKitNetwork = {
  id: 177,
  name: "HashKey Chain",
  nativeCurrency: { name: "HSK", symbol: "HSK", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.hashkeychain.com"] } },
  blockExplorers: { default: { name: "HashKey Explorer", url: "https://hashkeyscan.io" } },
};

export const mint: AppKitNetwork = {
  id: 185,
  name: "Mint",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mintchain.io"] } },
  blockExplorers: { default: { name: "Mint Explorer", url: "https://mintscan.io" } },
};

export const xlayer: AppKitNetwork = {
  id: 196,
  name: "X Layer",
  nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.xlayer.tech"] } },
  blockExplorers: { default: { name: "X Layer Explorer", url: "https://www.okx.com/web3/explorer/xlayer" } },
};

export const opBNB: AppKitNetwork = {
  id: 204,
  name: "opBNB",
  nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
  rpcUrls: { default: { http: ["https://opbnb-mainnet-rpc.bnbchain.org"] } },
  blockExplorers: { default: { name: "opBNB Explorer", url: "https://opbnbscan.com" } },
};

export const bSquared: AppKitNetwork = {
  id: 223,
  name: "B²",
  nativeCurrency: { name: "BTC", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.bsquared.network"] } },
  blockExplorers: { default: { name: "B² Explorer", url: "https://explorer.bsquared.network" } },
};

export const mindNetwork: AppKitNetwork = {
  id: 228,
  name: "Mind Network",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mindnetwork.xyz"] } },
  blockExplorers: { default: { name: "Mind Network Explorer", url: "https://explorer.mindnetwork.xyz" } },
};

export const lens: AppKitNetwork = {
  id: 232,
  name: "Lens",
  nativeCurrency: { name: "GHO", symbol: "GHO", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.lens.xyz"] } },
  blockExplorers: { default: { name: "Lens Explorer", url: "https://lensscan.io" } },
};

export const tac: AppKitNetwork = {
  id: 239,
  name: "Tac",
  nativeCurrency: { name: "TAC", symbol: "TAC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.tac.build"] } },
  blockExplorers: { default: { name: "Tac Explorer", url: "https://explorer.tac.build" } },
};

export const hedera: AppKitNetwork = {
  id: 295,
  name: "Hedera",
  nativeCurrency: { name: "HBAR", symbol: "HBAR", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.hashio.io/api"] } },
  blockExplorers: { default: { name: "HashScan", url: "https://hashscan.io/mainnet" } },
};

export const cronosZkEvm: AppKitNetwork = {
  id: 388,
  name: "Cronos zkEVM",
  nativeCurrency: { name: "zkCRO", symbol: "zkCRO", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.zkevm.cronos.org"] } },
  blockExplorers: { default: { name: "Cronos zkEVM Explorer", url: "https://zkevm.cronos.org/explorer" } },
};

export const astar: AppKitNetwork = {
  id: 592,
  name: "Astar",
  nativeCurrency: { name: "ASTR", symbol: "ASTR", decimals: 18 },
  rpcUrls: { default: { http: ["https://evm.astar.network"] } },
  blockExplorers: { default: { name: "Astar Explorer", url: "https://astar.subscan.io" } },
};

export const bittensorEvm: AppKitNetwork = {
  id: 964,
  name: "Bittensor EVM",
  nativeCurrency: { name: "TAO", symbol: "TAO", decimals: 18 },
  rpcUrls: { default: { http: ["https://evm.bittensor.com"] } },
  blockExplorers: { default: { name: "Bittensor Explorer", url: "https://evm.taostats.io" } },
};

export const stable: AppKitNetwork = {
  id: 988,
  name: "Stable",
  nativeCurrency: { name: "gUSDT", symbol: "gUSDT", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.stable.money"] } },
  blockExplorers: { default: { name: "Stable Explorer", url: "https://stable.dexguru.biz" } },
};

export const wemix: AppKitNetwork = {
  id: 1111,
  name: "Wemix",
  nativeCurrency: { name: "WEMIX", symbol: "WEMIX", decimals: 18 },
  rpcUrls: { default: { http: ["https://api.wemix.com"] } },
  blockExplorers: { default: { name: "Wemix Explorer", url: "https://wemixscan.com" } },
};

export const core: AppKitNetwork = {
  id: 1116,
  name: "Core",
  nativeCurrency: { name: "CORE", symbol: "CORE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.coredao.org"] } },
  blockExplorers: { default: { name: "Core Explorer", url: "https://scan.coredao.org" } },
};

export const sei: AppKitNetwork = {
  id: 1329,
  name: "Sei",
  nativeCurrency: { name: "SEI", symbol: "SEI", decimals: 18 },
  rpcUrls: { default: { http: ["https://evm-rpc.sei-apis.com"] } },
  blockExplorers: { default: { name: "SeiTrace", url: "https://seitrace.com" } },
};

export const metalL2: AppKitNetwork = {
  id: 1750,
  name: "Metal L2",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.metall2.com"] } },
  blockExplorers: { default: { name: "Metal L2 Explorer", url: "https://explorer.metall2.com" } },
};

export const soneium: AppKitNetwork = {
  id: 1868,
  name: "Soneium",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.soneium.org"] } },
  blockExplorers: { default: { name: "Soneium Explorer", url: "https://soneium.blockscout.com" } },
};

export const ronin: AppKitNetwork = {
  id: 2020,
  name: "Ronin",
  nativeCurrency: { name: "RON", symbol: "RON", decimals: 18 },
  rpcUrls: { default: { http: ["https://ronin.drpc.org"] } },
  blockExplorers: { default: { name: "Ronin Explorer", url: "https://app.roninchain.com" } },
};

export const abstract: AppKitNetwork = {
  id: 2741,
  name: "Abstract",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://api.abs.xyz"] } },
  blockExplorers: { default: { name: "Abstract Explorer", url: "https://explorer.abs.xyz" } },
};

export const morph: AppKitNetwork = {
  id: 2818,
  name: "Morph",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.morphl2.io"] } },
  blockExplorers: { default: { name: "Morph Explorer", url: "https://explorer.morphl2.io" } },
};

export const botanix: AppKitNetwork = {
  id: 3637,
  name: "Botanix",
  nativeCurrency: { name: "BTC", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.botanixlabs.dev"] } },
  blockExplorers: { default: { name: "Botanix Explorer", url: "https://blockscout.botanixlabs.dev" } },
};

export const merlin: AppKitNetwork = {
  id: 4200,
  name: "Merlin",
  nativeCurrency: { name: "BTC", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.merlinchain.io"] } },
  blockExplorers: { default: { name: "Merlin Explorer", url: "https://scan.merlinchain.io" } },
};

export const superseed: AppKitNetwork = {
  id: 5330,
  name: "Superseed",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.superseed.xyz"] } },
  blockExplorers: { default: { name: "Superseed Explorer", url: "https://explorer.superseed.xyz" } },
};

export const kaia: AppKitNetwork = {
  id: 8217,
  name: "Kaia",
  nativeCurrency: { name: "KAIA", symbol: "KAIA", decimals: 18 },
  rpcUrls: { default: { http: ["https://public-en.node.kaia.io"] } },
  blockExplorers: { default: { name: "Kaia Explorer", url: "https://klaytnscope.com" } },
};

export const plasma: AppKitNetwork = {
  id: 9745,
  name: "Plasma",
  nativeCurrency: { name: "XPL", symbol: "XPL", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.plasma.build"] } },
  blockExplorers: { default: { name: "Plasma Explorer", url: "https://plasma-explorer.com" } },
};

export const og: AppKitNetwork = {
  id: 16661,
  name: "0G",
  nativeCurrency: { name: "0G", symbol: "OG", decimals: 18 },
  rpcUrls: { default: { http: ["https://evmrpc-mainnet.0g.ai"] } },
  blockExplorers: { default: { name: "0G Explorer", url: "https://0g.ai/explorer" } },
};

export const everclear: AppKitNetwork = {
  id: 25327,
  name: "Everclear",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.everclear.raas.gelato.cloud"] } },
  blockExplorers: { default: { name: "Everclear Explorer", url: "https://scan.everclear.org" } },
};

export const apechain: AppKitNetwork = {
  id: 33139,
  name: "Apechain",
  nativeCurrency: { name: "APE", symbol: "APE", decimals: 18 },
  rpcUrls: { default: { http: ["https://apechain.calderachain.xyz/http"] } },
  blockExplorers: { default: { name: "ApeScan", url: "https://apescan.io" } },
};

export const abChain: AppKitNetwork = {
  id: 36888,
  name: "AB Chain",
  nativeCurrency: { name: "AB", symbol: "AB", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.abchain.io"] } },
  blockExplorers: { default: { name: "AB Chain Explorer", url: "https://abscan.io" } },
};

export const etherlink: AppKitNetwork = {
  id: 42793,
  name: "Etherlink",
  nativeCurrency: { name: "XTZ", symbol: "XTZ", decimals: 18 },
  rpcUrls: { default: { http: ["https://node.mainnet.etherlink.com"] } },
  blockExplorers: { default: { name: "Etherlink Explorer", url: "https://explorer.etherlink.com" } },
};

export const hemi: AppKitNetwork = {
  id: 43111,
  name: "Hemi",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hemi.network/rpc"] } },
  blockExplorers: { default: { name: "Hemi Explorer", url: "https://explorer.hemi.xyz" } },
};

export const zircuit: AppKitNetwork = {
  id: 48900,
  name: "Zircuit",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://zircuit-mainnet.drpc.org"] } },
  blockExplorers: { default: { name: "Zircuit Explorer", url: "https://explorer.zircuit.com" } },
};

export const memento: AppKitNetwork = {
  id: 51888,
  name: "Memento",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.memento.io"] } },
  blockExplorers: { default: { name: "Memento Explorer", url: "https://explorer.memento.io" } },
};

export const ink: AppKitNetwork = {
  id: 57073,
  name: "Ink",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc-gel.inkonchain.com"] } },
  blockExplorers: { default: { name: "Ink Explorer", url: "https://explorer.inkonchain.com" } },
};

export const bob: AppKitNetwork = {
  id: 60808,
  name: "BOB",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.gobob.xyz"] } },
  blockExplorers: { default: { name: "BOB Explorer", url: "https://explorer.gobob.xyz" } },
};

export const henesys: AppKitNetwork = {
  id: 68414,
  name: "Henesys",
  nativeCurrency: { name: "NXPC", symbol: "NXPC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.henesys.io"] } },
  blockExplorers: { default: { name: "Henesys Explorer", url: "https://explorer.henesys.io" } },
};

export const berachain: AppKitNetwork = {
  id: 80094,
  name: "Berachain",
  nativeCurrency: { name: "BERA", symbol: "BERA", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.berachain.com"] } },
  blockExplorers: { default: { name: "BeraScan", url: "https://berascan.com" } },
};

export const plume: AppKitNetwork = {
  id: 98866,
  name: "Plume",
  nativeCurrency: { name: "PLUME", symbol: "PLUME", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.plumenetwork.xyz"] } },
  blockExplorers: { default: { name: "Plume Explorer", url: "https://explorer.plumenetwork.xyz" } },
};

export const taiko: AppKitNetwork = {
  id: 167000,
  name: "Taiko",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.taiko.xyz"] } },
  blockExplorers: { default: { name: "TaikoScan", url: "https://taikoscan.io" } },
};

export const bitlayer: AppKitNetwork = {
  id: 200901,
  name: "Bitlayer",
  nativeCurrency: { name: "BTC", symbol: "BTC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.bitlayer.org"] } },
  blockExplorers: { default: { name: "Bitlayer Explorer", url: "https://www.btrscan.com" } },
};

export const katana: AppKitNetwork = {
  id: 747474,
  name: "Katana",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.katana.network"] } },
  blockExplorers: { default: { name: "Katana Explorer", url: "https://explorer.katana.network" } },
};

export const jovay: AppKitNetwork = {
  id: 5734951,
  name: "Jovay",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.jovay.io"] } },
  blockExplorers: { default: { name: "Jovay Explorer", url: "https://explorer.jovay.io" } },
};

export const corn: AppKitNetwork = {
  id: 21000000,
  name: "Corn",
  nativeCurrency: { name: "BTCN", symbol: "BTCN", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.corn-rpc.com"] } },
  blockExplorers: { default: { name: "CornScan", url: "https://cornscan.io" } },
};

export const xdcNetwork: AppKitNetwork = {
  id: 50,
  name: "XDC Network",
  nativeCurrency: { name: "XDC", symbol: "XDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.xinfin.network"] } },
  blockExplorers: { default: { name: "XDC Explorer", url: "https://xdcscan.io" } },
};

// Testnet Custom Networks
export const hyperEvmTestnet: AppKitNetwork = {
  id: 998,
  name: "HyperEVM Testnet",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid-testnet.xyz/evm"] } },
  blockExplorers: { default: { name: "HyperEVM Testnet Explorer", url: "https://explorer.hyperliquid-testnet.xyz" } },
};

export const soneiumMinato: AppKitNetwork = {
  id: 1946,
  name: "Soneium Minato",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.minato.soneium.org"] } },
  blockExplorers: { default: { name: "Soneium Minato Explorer", url: "https://soneium-minato.blockscout.com" } },
};

export const berachainBartio: AppKitNetwork = {
  id: 80084,
  name: "Berachain Bartio",
  nativeCurrency: { name: "BERA", symbol: "BERA", decimals: 18 },
  rpcUrls: { default: { http: ["https://bartio.rpc.berachain.com"] } },
  blockExplorers: { default: { name: "Berachain Bartio Explorer", url: "https://bartio.beratrail.io" } },
};

export const monadTestnet: AppKitNetwork = {
  id: 10143,
  name: "Monad Testnet",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://testnet-rpc.monad.xyz"] } },
  blockExplorers: { default: { name: "Monad Testnet Explorer", url: "https://testnet.monadexplorer.com" } },
};

// ============================================
// ALL NETWORKS
// ============================================

export const networks: [AppKitNetwork, ...AppKitNetwork[]] = [
  // Reown Built-in Mainnets
  mainnet,
  arbitrum,
  polygon,
  optimism,
  base,
  avalanche,
  bsc,
  gnosis,
  zkSync,
  linea,
  scroll,
  mantle,
  mode,
  blast,
  celo,
  zora,
  polygonZkEvm,
  fraxtal,
  metis,
  cronos,
  rootstock,
  worldchain,
  lisk,

  // Custom Mainnets (CCIP supported but not in Reown)
  hyperEvmMainnet,
  shibarium,
  unichain,
  monadMainnet,
  sonic,
  hashkeyChain,
  mint,
  xlayer,
  opBNB,
  bSquared,
  mindNetwork,
  lens,
  tac,
  hedera,
  cronosZkEvm,
  astar,
  bittensorEvm,
  stable,
  wemix,
  core,
  sei,
  metalL2,
  soneium,
  ronin,
  abstract,
  morph,
  botanix,
  merlin,
  superseed,
  kaia,
  plasma,
  og,
  everclear,
  apechain,
  abChain,
  etherlink,
  hemi,
  zircuit,
  memento,
  ink,
  bob,
  henesys,
  berachain,
  plume,
  taiko,
  bitlayer,
  katana,
  jovay,
  corn,
  xdcNetwork,

  // Reown Built-in Testnets
  sepolia,
  arbitrumSepolia,
  baseSepolia,
  optimismSepolia,
  avalancheFuji,
  polygonAmoy,
  bscTestnet,
  gnosisChiado,
  zkSyncSepoliaTestnet,
  lineaSepolia,
  scrollSepolia,
  mantleSepoliaTestnet,
  modeTestnet,
  blastSepolia,
  celoAlfajores,
  holesky,
  zoraSepolia,
  polygonZkEvmCardona,
  fraxtalTestnet,
  cronosTestnet,
  rootstockTestnet,
  liskSepolia,

  // Custom Testnets (CCIP supported but not in Reown)
  hyperEvmTestnet,
  soneiumMinato,
  berachainBartio,
  monadTestnet,
];

// ============================================
// METADATA & CONFIG
// ============================================

export const metadata = {
  name: "Cross-Chain ERC-4626 Adapter Dashboard (CCIP)",
  description: "Reference dashboard for the CCIP CrossChainERC4626Adapter",
  url: typeof window !== "undefined" ? window.location.origin : "",
  icons: [
    typeof window !== "undefined"
      ? new URL(`${import.meta.env.BASE_URL}favicon.png`, window.location.origin).href
      : "",
  ].filter(Boolean),
};

export const defaultNetwork = mainnet;

/**
 * Resolve a configured AppKit network object by EVM chain id. Reown's `switchNetwork`
 * requires the actual network object from the `networks` array (passing `{ chainId }`
 * throws "Network not found"). Returns undefined for chains not registered with AppKit.
 */
export function appKitNetworkById(id: number): AppKitNetwork | undefined {
  return networks.find((n) => Number(n.id) === id);
}

// ============================================
// NETWORK TRACKING FOR README
// ============================================

/**
 * Networks available in Reown/AppKit (native support):
 * - Mainnet: Ethereum, Arbitrum, Polygon, Optimism, Base, Avalanche, BNB Chain, Gnosis,
 *   ZKsync, Linea, Scroll, Mantle, Mode, Blast, Celo, Zora, Polygon zkEVM, Fraxtal,
 *   Metis, Cronos, Rootstock, World Chain, Lisk
 * - Testnet: Sepolia, Arbitrum Sepolia, Base Sepolia, OP Sepolia, Avalanche Fuji,
 *   Polygon Amoy, BNB Testnet, Gnosis Chiado, ZKsync Sepolia, Linea Sepolia,
 *   Scroll Sepolia, Mantle Sepolia, Mode Testnet, Blast Sepolia, Celo Alfajores,
 *   Holesky, Zora Sepolia, Polygon zkEVM Cardona, Fraxtal Testnet, Cronos Testnet,
 *   Rootstock Testnet, Lisk Sepolia
 *
 * Networks with custom definitions (CCIP supported, added via custom network object):
 * - Mainnet: HyperEVM, Shibarium, Unichain, Monad, Sonic, HashKey Chain, Mint, X Layer,
 *   opBNB, B², Mind Network, Lens, Tac, Hedera, Cronos zkEVM, Astar, Bittensor EVM,
 *   Stable, Wemix, Core, Sei, Metal L2, Soneium, Ronin, Abstract, Morph, Botanix,
 *   Merlin, Superseed, Kaia, Plasma, 0G, Everclear, Apechain, AB Chain, Etherlink,
 *   Hemi, Zircuit, Memento, Ink, BOB, Henesys, Berachain, Plume, Taiko, Bitlayer,
 *   Katana, Jovay, Corn, XDC Network
 * - Testnet: HyperEVM Testnet, Soneium Minato, Berachain Bartio, Monad Testnet
 *
 * Note: All custom networks work for wallet switching but may have limited
 * ecosystem support (token lists, etc.) compared to native Reown networks.
 */
