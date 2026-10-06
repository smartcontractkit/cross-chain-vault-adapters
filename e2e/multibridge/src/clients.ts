import { createPublicClient, createWalletClient, defineChain, http, type Chain } from 'viem'
import { type HubLoaded, type Loaded } from './config.js'

/** Builds a minimal viem Chain for a fork / testnet RPC. */
export function netChain(net: Loaded['hub'] | HubLoaded['hub'], rpcUrl: string): Chain {
  return defineChain({
    id: net.chainId,
    name: net.label,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  })
}

export function originateClients(cfg: Loaded) {
  const chain = netChain(cfg.originateNet, cfg.originateRpcUrl)
  const transport = http(cfg.originateRpcUrl)
  const publicClient = createPublicClient({ chain, transport })
  const walletClient = createWalletClient({ account: cfg.account, chain, transport })
  return { chain, publicClient, walletClient }
}

export function hubClients(cfg: Loaded | HubLoaded, hubRpcUrl: string) {
  const chain = netChain(cfg.hub, hubRpcUrl)
  const transport = http(hubRpcUrl)
  const publicClient = createPublicClient({ chain, transport })
  const walletClient = createWalletClient({ account: cfg.account, chain, transport })
  return { chain, publicClient, walletClient }
}

/** @deprecated use originateClients */
export function spokeClients(cfg: Loaded) {
  return originateClients(cfg)
}
