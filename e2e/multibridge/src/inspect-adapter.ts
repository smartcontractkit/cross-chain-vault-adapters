import { existsSync, readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  createPublicClient,
  defineChain,
  formatEther,
  formatUnits,
  http,
  type Address,
} from 'viem'
import 'dotenv/config'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(here, '../../..')

const RAILS = ['LZ_OFT', 'CCIP', 'STARGATE', 'CCIP_SVM', 'LOCAL'] as const

const ERC20_META_ABI = [
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
] as const

const VAULT_ABI = [
  ...ERC20_META_ABI,
  { type: 'function', name: 'asset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'totalAssets', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
] as const

const ADAPTER_INSPECT_ABI = [
  { type: 'function', name: 'typeAndVersion', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'DEFAULT_ADMIN_ROLE', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  { type: 'function', name: 'FEE_SETTER_ROLE', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  { type: 'function', name: 'FEE_COLLECTOR_ROLE', stateMutability: 'view', inputs: [], outputs: [{ type: 'bytes32' }] },
  {
    type: 'function',
    name: 'hasRole',
    stateMutability: 'view',
    inputs: [{ type: 'bytes32' }, { type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  { type: 'function', name: 's_ccipRouter', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 's_lzEndpoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 's_vault', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 's_asset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 's_requireLzReturnPrefunded', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'LOCAL_DESTINATION', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  {
    type: 'function',
    name: 's_ccipSourceAllowed',
    stateMutability: 'view',
    inputs: [{ type: 'uint64' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 's_ccipDestAllowed',
    stateMutability: 'view',
    inputs: [{ type: 'uint64' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 's_lzOftAllowed',
    stateMutability: 'view',
    inputs: [{ type: 'uint32' }, { type: 'address' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 's_lzDestAllowed',
    stateMutability: 'view',
    inputs: [{ type: 'uint32' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 's_stargateDestAllowed',
    stateMutability: 'view',
    inputs: [{ type: 'uint32' }],
    outputs: [{ type: 'bool' }],
  },
  {
    type: 'function',
    name: 's_ccipSvm',
    stateMutability: 'view',
    inputs: [{ type: 'uint64' }],
    outputs: [
      { type: 'bool', name: 'enabled' },
      { type: 'uint32', name: 'computeUnits' },
      { type: 'bool', name: 'allowOutOfOrderExecution' },
    ],
  },
  {
    type: 'function',
    name: 's_oftForToken',
    stateMutability: 'view',
    inputs: [{ type: 'address' }],
    outputs: [{ type: 'address' }],
  },
  {
    type: 'function',
    name: 's_dstGas',
    stateMutability: 'view',
    inputs: [{ type: 'uint64' }],
    outputs: [{ type: 'uint128' }],
  },
  {
    type: 'function',
    name: 's_route',
    stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'uint64' }],
    outputs: [
      { type: 'bool', name: 'enabled' },
      { type: 'uint8', name: 'rail' },
      { type: 'address', name: 'endpoint' },
      { type: 'uint64', name: 'dstId' },
    ],
  },
  {
    type: 'function',
    name: 's_inboundFees',
    stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'uint64' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function',
    name: 's_collectedFees',
    stateMutability: 'view',
    inputs: [{ type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
] as const

const FACTORY_ABI = [
  { type: 'function', name: 'i_implementation', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  {
    type: 'event',
    name: 'VaultAdapterDeployed',
    inputs: [
      { type: 'address', name: 'app', indexed: true },
      { type: 'address', name: 'vault', indexed: true },
      { type: 'address', name: 'owner', indexed: true },
      { type: 'uint256', name: 'funded', indexed: false },
    ],
  },
] as const

const OFT_ABI = [
  { type: 'function', name: 'token', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
] as const

interface Net {
  label: string
  ccipChainSelector: string
  lzEid: number
}

interface RouteSpec {
  token: string
  destination: string
  rail: string
  endpoint: string
}

interface InboundFeeSpec {
  outboundToken: string
  destination: string
  fee: string
}

interface FeeConfigBlock {
  key: string
  vault?: Address
  requireLzReturnPrefunded?: boolean
  inboundFees: InboundFeeSpec[]
}

interface AdapterProfile {
  app: Address
  vault: Address
  asset: Address
  share: Address
}

interface ProbeContext {
  adapter: Address
  factory?: Address
  profiles: Record<string, AdapterProfile>
  spokes: Record<string, Net>
  hub: Net & { chainId: number; ccipRouter: Address; lzEndpoint: Address }
  ccipSelectors: bigint[]
  lzEids: number[]
  lzOftPairs: { eid: number; oft: Address }[]
  tokens: Address[]
  routeSpecs: RouteSpec[]
  tokenByKey: Record<string, Address>
  feeConfigBlocks: FeeConfigBlock[]
}

function resolveConfigPath(): string {
  const rel = process.env.CONFIG ?? 'config/multibridge/sepolia.json'
  if (rel.startsWith('/')) return rel
  const normalized = rel.replace(/^\.\/?/, '').replace(/^(?:\.\.\/)+/, '')
  return resolve(repoRoot, normalized)
}

function readSelectorInObject(rawJson: string, objectKey: string, field: string): string {
  const spokesIdx = rawJson.indexOf('"spokes"')
  const search = spokesIdx >= 0 ? rawJson.slice(spokesIdx) : rawJson
  const objIdx = search.indexOf(`"${objectKey}"`)
  if (objIdx < 0) throw new Error(`could not find spokes.${objectKey} in config`)
  const slice = search.slice(objIdx, objIdx + 2000)
  const re = new RegExp(`"${field}"\\s*:\\s*(?:"(0x[0-9a-fA-F]+)"|([0-9]+))`)
  const m = slice.match(re)
  if (!m) throw new Error(`could not read "${objectKey}.${field}" from config`)
  return m[1] ? BigInt(m[1]).toString() : m[2]
}

function readRouteSpecs(raw: string, key: string): RouteSpec[] {
  const anchor = `"${key.replace(/^\./, '')}"`
  const idx = raw.indexOf(anchor)
  if (idx < 0) return []
  const slice = raw.slice(idx, idx + 8000)
  const tokenRe = /"token"\s*:\s*"([^"]+)"/g
  const destRe = /"destination"\s*:\s*([0-9]+)/g
  const railRe = /"rail"\s*:\s*"([^"]+)"/g
  const endpointRe = /"endpoint"\s*:\s*"(0x[a-fA-F0-9]+)"/g
  const tokens = [...slice.matchAll(tokenRe)].map((m) => m[1])
  const dests = [...slice.matchAll(destRe)].map((m) => m[1])
  const rails = [...slice.matchAll(railRe)].map((m) => m[1])
  const endpoints = [...slice.matchAll(endpointRe)].map((m) => m[1])
  const n = Math.min(tokens.length, dests.length, rails.length, endpoints.length)
  const out: RouteSpec[] = []
  for (let i = 0; i < n; i++) {
    out.push({
      token: tokens[i],
      destination: dests[i],
      rail: rails[i],
      endpoint: endpoints[i] as Address,
    })
  }
  return out
}

function readInboundFees(raw: string, blockKey: string): InboundFeeSpec[] {
  const anchor = `"${blockKey}"`
  const idx = raw.indexOf(anchor)
  if (idx < 0) return []
  const slice = raw.slice(idx, idx + 12000)
  const feesIdx = slice.indexOf('"inboundFees"')
  if (feesIdx < 0) return []
  const feesSlice = slice.slice(feesIdx, feesIdx + 4000)
  const tokenRe = /"outboundToken"\s*:\s*"([^"]+)"/g
  const destRe = /"destination"\s*:\s*([0-9]+)/g
  const feeRe = /"fee"\s*:\s*([0-9]+)/g
  const tokens = [...feesSlice.matchAll(tokenRe)].map((m) => m[1])
  const dests = [...feesSlice.matchAll(destRe)].map((m) => m[1])
  const fees = [...feesSlice.matchAll(feeRe)].map((m) => m[1])
  const n = Math.min(tokens.length, dests.length, fees.length)
  const out: InboundFeeSpec[] = []
  for (let i = 0; i < n; i++) {
    out.push({ outboundToken: tokens[i], destination: dests[i], fee: fees[i] })
  }
  return out
}

function readFeeConfigBlocks(raw: string, json: Record<string, unknown>): FeeConfigBlock[] {
  const blocks: FeeConfigBlock[] = []
  for (const key of ['vaultAdapter', 'vaultAdapterUsdc']) {
    const block = json[key] as Record<string, unknown> | undefined
    if (!block) continue
    blocks.push({
      key,
      vault: block.vault as Address | undefined,
      requireLzReturnPrefunded: block.requireLzReturnPrefunded as boolean | undefined,
      inboundFees: readInboundFees(raw, key),
    })
  }
  return blocks
}

function resolveOutboundToken(
  spec: InboundFeeSpec,
  tokenByKey: Record<string, Address>,
  asset: Address,
  vault: Address,
): Address {
  const key = spec.outboundToken.toLowerCase()
  if (key === 'share' || key === 'vault') return vault
  if (key === 'asset') return asset
  if (spec.outboundToken.startsWith('0x')) return spec.outboundToken as Address
  return tokenByKey[spec.outboundToken] ?? (spec.outboundToken as Address)
}

function readHubSelector(rawJson: string): string {
  const re = /"ccipChainSelector"\s*:\s*([0-9]+)/
  const hubIdx = rawJson.indexOf('"hub"')
  const slice = rawJson.slice(hubIdx, hubIdx + 1200)
  const m = slice.match(re)
  if (!m) throw new Error('could not read hub.ccipChainSelector')
  return m[1]
}

function loadProbeContext(adapter: Address): ProbeContext {
  const configPath = resolveConfigPath()
  if (!existsSync(configPath)) throw new Error(`config file not found: ${configPath} (set CONFIG=config/multibridge/sepolia.json or a Tenderly config)`)
  const raw = readFileSync(configPath, 'utf-8')
  const json = JSON.parse(raw) as Record<string, unknown>

  const hub = json.hub as Net & { chainId: number; ccipRouter: Address; lzEndpoint: Address; factory?: Address }
  hub.ccipChainSelector = readHubSelector(raw)

  const spokes = json.spokes as Record<string, Net>
  for (const key of Object.keys(spokes ?? {})) {
    spokes[key].ccipChainSelector = readSelectorInObject(raw, key, 'ccipChainSelector')
  }

  const adapters = (json.adapters ?? {}) as Record<string, AdapterProfile>
  const profiles: Record<string, AdapterProfile> = {}
  for (const [k, v] of Object.entries(adapters)) {
    if (v.app) profiles[k] = v
  }

  const va = json.vaultAdapter as Record<string, unknown> | undefined
  const vaUsdc = json.vaultAdapterUsdc as Record<string, unknown> | undefined
  const routes = [...readRouteSpecs(raw, 'routes'), ...readRouteSpecs(raw, 'usdcRoutes')]

  const ccipSelectors = new Set<bigint>()
  const lzEids = new Set<number>()
  const lzOftPairs: { eid: number; oft: Address }[] = []
  const tokens = new Set<Address>()
  const tokenByKey: Record<string, Address> = {}

  ccipSelectors.add(BigInt(hub.ccipChainSelector))
  lzEids.add((hub as Net & { lzEid: number }).lzEid ?? 0)

  for (const spoke of Object.values(spokes ?? {})) {
    ccipSelectors.add(BigInt(spoke.ccipChainSelector))
    lzEids.add(spoke.lzEid)
  }

  for (const block of [va, vaUsdc]) {
    if (!block) continue
    for (const s of (block.ccipSrcSelectors as number[] | undefined) ?? []) ccipSelectors.add(BigInt(s))
    for (const s of (block.ccipDstSelectors as number[] | undefined) ?? []) ccipSelectors.add(BigInt(s))
    for (const e of (block.lzDstEids as number[] | undefined) ?? []) if (e) lzEids.add(e)
    for (const e of (block.stargateDstEids as number[] | undefined) ?? []) if (e) lzEids.add(e)
    const eids = (block.lzSrcEids as number[] | undefined) ?? []
    const ofts = (block.lzSrcOfts as Address[] | undefined) ?? []
    for (let i = 0; i < eids.length; i++) {
      lzEids.add(eids[i])
      if (ofts[i]) lzOftPairs.push({ eid: eids[i], oft: ofts[i] })
    }
    for (const e of (block.revokeLzEids as number[] | undefined) ?? []) lzEids.add(e)
    const revokeOfts = (block.revokeLzOfts as Address[] | undefined) ?? []
    const revokeEids = (block.revokeLzEids as number[] | undefined) ?? []
    for (let i = 0; i < revokeEids.length; i++) {
      if (revokeOfts[i]) lzOftPairs.push({ eid: revokeEids[i], oft: revokeOfts[i] })
    }
    if (block.asset) tokens.add(block.asset as Address)
    if (block.share) tokens.add(block.share as Address)
    if (block.vault) tokens.add(block.vault as Address)
    for (const t of (block.oftTokens as Address[] | undefined) ?? []) tokens.add(t)
  }

  for (const r of routes) {
    const d = BigInt(r.destination)
    ccipSelectors.add(d)
    if (d <= 0xffffffffn) lzEids.add(Number(d))
  }

  for (const [k, p] of Object.entries(profiles)) {
    tokens.add(p.asset)
    tokens.add(p.share)
    tokens.add(p.vault)
    tokenByKey[`${k}.asset`] = p.asset
    tokenByKey[`${k}.share`] = p.share
    tokenByKey.asset = p.asset
    tokenByKey.share = p.share
  }

  return {
    adapter,
    factory: hub.factory,
    profiles,
    spokes: spokes ?? {},
    hub,
    ccipSelectors: [...ccipSelectors].filter((s) => s > 0n).sort((a, b) => (a < b ? -1 : 1)),
    lzEids: [...lzEids].filter((e) => e > 0).sort((a, b) => a - b),
    lzOftPairs,
    tokens: [...tokens],
    routeSpecs: routes,
    tokenByKey,
    feeConfigBlocks: readFeeConfigBlocks(raw, json),
  }
}

function labelForSelector(ctx: ProbeContext, selector: bigint): string {
  if (selector === BigInt(ctx.hub.ccipChainSelector)) return `${ctx.hub.label} (hub)`
  for (const [key, spoke] of Object.entries(ctx.spokes)) {
    if (BigInt(spoke.ccipChainSelector) === selector) return `${spoke.label} [${key}]`
  }
  return 'unknown'
}

function labelForEid(ctx: ProbeContext, eid: number): string {
  if (eid === (ctx.hub as Net & { lzEid?: number }).lzEid) return `${ctx.hub.label} (hub)`
  for (const [key, spoke] of Object.entries(ctx.spokes)) {
    if (spoke.lzEid === eid) return `${spoke.label} [${key}]`
  }
  return 'unknown'
}

async function tokenMeta(
  client: ReturnType<typeof createPublicClient>,
  token: Address,
  holder?: Address,
) {
  try {
    const [symbol, decimals, balance] = await Promise.all([
      client.readContract({ address: token, abi: ERC20_META_ABI, functionName: 'symbol' }),
      client.readContract({ address: token, abi: ERC20_META_ABI, functionName: 'decimals' }),
      holder
        ? client.readContract({ address: token, abi: ERC20_META_ABI, functionName: 'balanceOf', args: [holder] })
        : Promise.resolve(0n),
    ])
    return {
      address: token,
      symbol,
      decimals: Number(decimals),
      balance: balance.toString(),
      balanceFormatted: formatUnits(balance, Number(decimals)),
    }
  } catch {
    return { address: token, symbol: '?', decimals: 0, balance: '0', balanceFormatted: '0' }
  }
}

/**
 * Returns which `candidates` hold `role`. The adapter uses non-enumerable AccessControl, so role members
 * cannot be listed on-chain; the candidates come from the config (owners, fee collectors, factory), the
 * `DEPLOYER` env var, and the optional comma-separated `ROLE_CANDIDATES` env var.
 */
async function roleHolders(
  client: ReturnType<typeof createPublicClient>,
  adapter: Address,
  role: `0x${string}`,
  candidates: Address[],
): Promise<Address[]> {
  const held = await Promise.all(
    candidates.map((account) =>
      client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'hasRole', args: [role, account] }),
    ),
  )
  return candidates.filter((_, i) => held[i])
}

/** Collects candidate role holders: config owners/fee collectors, the factory, and env overrides. */
function roleCandidates(raw: string, factory: Address | undefined): Address[] {
  const found = [...raw.matchAll(/"(?:owner|feeCollector)"\s*:\s*"(0x[0-9a-fA-F]{40})"/g)].map((m) => m[1])
  const fromEnv = [process.env.DEPLOYER, ...(process.env.ROLE_CANDIDATES ?? '').split(',')]
  const all = [...found, ...(factory ? [factory] : []), ...fromEnv]
    .map((a) => (a ?? '').trim())
    .filter((a) => /^0x[0-9a-fA-F]{40}$/.test(a) && !/^0x0{40}$/.test(a))
  return [...new Set(all.map((a) => a.toLowerCase()))] as Address[]
}

/**
 * Lists clones deployed by `factory` from its `VaultAdapterDeployed` events (the factory keeps no on-chain
 * registry). Scans from `fromBlock` to the latest block in chunks that public RPCs accept.
 */
async function factoryClones(
  client: ReturnType<typeof createPublicClient>,
  factory: Address,
  fromBlock: bigint,
): Promise<Address[]> {
  const latest = await client.getBlockNumber()
  const chunk = 9_000n
  const clones: Address[] = []
  for (let start = fromBlock; start <= latest; start += chunk + 1n) {
    const end = start + chunk > latest ? latest : start + chunk
    const logs = await client.getLogs({
      address: factory,
      event: FACTORY_ABI[1],
      fromBlock: start,
      toBlock: end,
    })
    for (const log of logs) if (log.args.app) clones.push(log.args.app)
  }
  return clones
}

async function main(): Promise<void> {
  const adapter = (process.env.ADAPTER ?? process.env.ADAPTER_ADDRESS) as Address | undefined
  if (!adapter) throw new Error('set ADAPTER=0x… (hub clone to inspect)')

  const rpcUrl = process.env.HUB_RPC_URL
  if (!rpcUrl) throw new Error('set HUB_RPC_URL')

  const ctx = loadProbeContext(adapter)
  const chain = defineChain({
    id: ctx.hub.chainId,
    name: ctx.hub.label,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  })
  const client = createPublicClient({ chain, transport: http(rpcUrl) })

  const code = await client.getBytecode({ address: adapter })
  if (!code || code === '0x') throw new Error(`no contract code at ${adapter}`)

  const [
    typeAndVersion,
    adminRole,
    feeSetterRole,
    feeCollectorRole,
    ccipRouter,
    lzEndpoint,
    vault,
    asset,
    requireLzPrefund,
    localDest,
    ethBalance,
  ] = await Promise.all([
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'typeAndVersion' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'DEFAULT_ADMIN_ROLE' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'FEE_SETTER_ROLE' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'FEE_COLLECTOR_ROLE' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_ccipRouter' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_lzEndpoint' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_vault' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_asset' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_requireLzReturnPrefunded' }),
    client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 'LOCAL_DESTINATION' }),
    client.getBalance({ address: adapter }),
  ])

  const candidates = roleCandidates(readFileSync(resolveConfigPath(), 'utf-8'), ctx.factory)
  const [admins, feeSetters, feeCollectors] = await Promise.all([
    roleHolders(client, adapter, adminRole, candidates),
    roleHolders(client, adapter, feeSetterRole, candidates),
    roleHolders(client, adapter, feeCollectorRole, candidates),
  ])

  let implementation: Address | undefined
  let factoryInfo: { count: number; adapters: Address[] } | undefined
  if (ctx.factory) {
    implementation = await client.readContract({
      address: ctx.factory,
      abi: FACTORY_ABI,
      functionName: 'i_implementation',
    })
    const fromBlock = process.env.FACTORY_FROM_BLOCK
    if (fromBlock) {
      const adapters = await factoryClones(client, ctx.factory, BigInt(fromBlock))
      factoryInfo = { count: adapters.length, adapters }
    }
  }

  const vaultStats = await Promise.all([
    client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'totalAssets' }),
    client.readContract({ address: vault, abi: VAULT_ABI, functionName: 'totalSupply' }),
    tokenMeta(client, asset),
    tokenMeta(client, vault, adapter),
    tokenMeta(client, asset, adapter),
  ])

  const ccipSources = []
  for (const selector of ctx.ccipSelectors) {
    const allowed = await client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_ccipSourceAllowed',
      args: [selector],
    })
    const svmResult = await client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_ccipSvm',
      args: [selector],
    })
    const svm = { enabled: svmResult[0], computeUnits: svmResult[1], allowOutOfOrderExecution: svmResult[2] }
    if (allowed || svm.enabled) {
      ccipSources.push({
        selector: selector.toString(),
        label: labelForSelector(ctx, selector),
        allowed,
        svm: svm.enabled
          ? { computeUnits: svm.computeUnits, allowOutOfOrderExecution: svm.allowOutOfOrderExecution }
          : null,
      })
    }
  }

  const ccipDests = []
  for (const selector of ctx.ccipSelectors) {
    const allowed = await client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_ccipDestAllowed',
      args: [selector],
    })
    if (allowed) {
      ccipDests.push({ selector: selector.toString(), label: labelForSelector(ctx, selector), allowed })
    }
  }

  const lzOfts = []
  const seenOft = new Set<string>()
  for (const pair of ctx.lzOftPairs) {
    const key = `${pair.eid}:${pair.oft}`
    if (seenOft.has(key)) continue
    seenOft.add(key)
    const allowed = await client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_lzOftAllowed',
      args: [pair.eid, pair.oft],
    })
    if (!allowed) continue
    let underlying: Address | undefined
    try {
      underlying = await client.readContract({ address: pair.oft, abi: OFT_ABI, functionName: 'token' })
    } catch {
      underlying = undefined
    }
    lzOfts.push({
      srcEid: pair.eid,
      label: labelForEid(ctx, pair.eid),
      oft: pair.oft,
      underlying,
      allowed,
    })
  }

  const lzDests = []
  const stargateDests = []
  for (const eid of ctx.lzEids) {
    const [lzAllowed, sgAllowed] = await Promise.all([
      client.readContract({ address: adapter, abi: ADAPTER_INSPECT_ABI, functionName: 's_lzDestAllowed', args: [eid] }),
      client.readContract({
        address: adapter,
        abi: ADAPTER_INSPECT_ABI,
        functionName: 's_stargateDestAllowed',
        args: [eid],
      }),
    ])
    if (lzAllowed) lzDests.push({ eid, label: labelForEid(ctx, eid), allowed: true })
    if (sgAllowed) stargateDests.push({ eid, label: labelForEid(ctx, eid), allowed: true })
  }

  const oftMap = []
  for (const token of ctx.tokens) {
    const oft = await client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_oftForToken',
      args: [token],
    })
    if (oft !== '0x0000000000000000000000000000000000000000') {
      oftMap.push({ token, oft })
    }
  }

  const destinationKeys = new Set<bigint>()
  destinationKeys.add(localDest)
  for (const s of ctx.ccipSelectors) destinationKeys.add(s)
  for (const e of ctx.lzEids) destinationKeys.add(BigInt(e))

  const routeMatrix = []
  const tokenList = [...new Set([asset, vault, ...ctx.tokens])]
  for (const token of tokenList) {
    for (const dest of [...destinationKeys].sort((a, b) => (a < b ? -1 : 1))) {
      const routeResult = await client.readContract({
        address: adapter,
        abi: ADAPTER_INSPECT_ABI,
        functionName: 's_route',
        args: [token, dest],
      })
      const route = {
        enabled: routeResult[0],
        rail: routeResult[1],
        endpoint: routeResult[2],
        dstId: routeResult[3],
      }
      if (!route.enabled) continue
      const gas = await client.readContract({
        address: adapter,
        abi: ADAPTER_INSPECT_ABI,
        functionName: 's_dstGas',
        args: [dest],
      })
      const tokenLabel =
        token.toLowerCase() === asset.toLowerCase()
          ? 'asset'
          : token.toLowerCase() === vault.toLowerCase()
            ? 'share'
            : token
      routeMatrix.push({
        token: tokenLabel,
        tokenAddress: token,
        destinationKey: dest.toString(),
        destinationLabel: dest === localDest ? 'LOCAL (0)' : dest <= 0xffffffffn ? labelForEid(ctx, Number(dest)) : labelForSelector(ctx, dest),
        rail: RAILS[route.rail] ?? `unknown(${route.rail})`,
        endpoint: route.endpoint,
        dstId: route.dstId.toString(),
        dstIdLabel: route.dstId <= 0xffffffffn ? labelForEid(ctx, Number(route.dstId)) : labelForSelector(ctx, BigInt(route.dstId)),
        gasLimit: gas === 0n ? 200_000 : Number(gas),
      })
    }
  }

  const configRoutes = ctx.routeSpecs.map((spec) => {
    const tokenAddr = ctx.tokenByKey[spec.token] ?? spec.token
    const dest = BigInt(spec.destination)
    return {
      ...spec,
      tokenAddress: tokenAddr,
      destinationLabel: dest <= 0xffffffffn ? labelForEid(ctx, Number(dest)) : labelForSelector(ctx, dest),
    }
  })

  const matchedProfile = Object.entries(ctx.profiles).find(([, p]) => p.app.toLowerCase() === adapter.toLowerCase())?.[0]

  const matchedFeeBlock =
    ctx.feeConfigBlocks.find((b) => b.vault?.toLowerCase() === vault.toLowerCase()) ??
    ctx.feeConfigBlocks[0]

  const configInboundFees = matchedFeeBlock?.inboundFees ?? []
  const inboundFeeChecks = await Promise.all(
    configInboundFees.map(async (spec) => {
      const outToken = resolveOutboundToken(spec, ctx.tokenByKey, asset, vault)
      const dest = BigInt(spec.destination)
      const onChain = await client.readContract({
        address: adapter,
        abi: ADAPTER_INSPECT_ABI,
        functionName: 's_inboundFees',
        args: [outToken, dest],
      })
      const destLabel =
        dest <= 0xffffffffn ? labelForEid(ctx, Number(dest)) : labelForSelector(ctx, dest)
      return {
        outboundToken: spec.outboundToken,
        outboundTokenAddress: outToken,
        destination: dest.toString(),
        destinationLabel: destLabel,
        configFee: spec.fee,
        onChainFee: onChain.toString(),
        match: BigInt(spec.fee) === onChain,
      }
    }),
  )

  const [assetCollected, shareCollected] = await Promise.all([
    client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_collectedFees',
      args: [asset],
    }),
    client.readContract({
      address: adapter,
      abi: ADAPTER_INSPECT_ABI,
      functionName: 's_collectedFees',
      args: [vault],
    }),
  ])

  const configRequireLzPrefund = matchedFeeBlock?.requireLzReturnPrefunded

  const report = {
    adapter,
    chainId: ctx.hub.chainId,
    profile: matchedProfile ?? process.env.ADAPTER_PROFILE ?? null,
    typeAndVersion,
    proxy: {
      factory: ctx.factory ?? null,
      implementation: implementation ?? null,
      registeredOnFactory: factoryInfo?.adapters.map((a) => a.toLowerCase()).includes(adapter.toLowerCase()) ?? null,
      factoryDeployedCount: factoryInfo?.count ?? null,
    },
    roles: {
      DEFAULT_ADMIN_ROLE: admins,
      FEE_SETTER_ROLE: feeSetters,
      FEE_COLLECTOR_ROLE: feeCollectors,
    },
    transport: {
      ccipRouter,
      lzEndpoint,
      configRouterMatch: ccipRouter.toLowerCase() === ctx.hub.ccipRouter.toLowerCase(),
      configEndpointMatch: lzEndpoint.toLowerCase() === ctx.hub.lzEndpoint.toLowerCase(),
      nativeBalanceWei: ethBalance.toString(),
      nativeBalanceEth: formatEther(ethBalance),
      requireLzReturnPrefunded: requireLzPrefund,
      configRequireLzReturnPrefunded: configRequireLzPrefund ?? null,
      configRequireLzMatch:
        configRequireLzPrefund === undefined ? null : configRequireLzPrefund === requireLzPrefund,
      localDestination: localDest.toString(),
    },
    fees: {
      configBlock: matchedFeeBlock?.key ?? null,
      inboundFees: inboundFeeChecks,
      collectedFees: {
        asset: {
          token: asset,
          amount: assetCollected.toString(),
          formatted: formatUnits(assetCollected, vaultStats[2].decimals),
          symbol: vaultStats[2].symbol,
        },
        share: {
          token: vault,
          amount: shareCollected.toString(),
          formatted: formatUnits(shareCollected, vaultStats[3].decimals),
          symbol: vaultStats[3].symbol,
        },
      },
    },
    vault: {
      address: vault,
      asset,
      totalAssets: vaultStats[0].toString(),
      totalSupply: vaultStats[1].toString(),
      assetMeta: vaultStats[2],
      shareHeldOnAdapter: vaultStats[3],
      assetHeldOnAdapter: vaultStats[4],
    },
    inbound: {
      ccipSources,
      lzOfts,
    },
    outbound: {
      ccipDestinations: ccipDests,
      lzDestinations: lzDests,
      stargateDestinations: stargateDests,
    },
    oftForToken: oftMap,
    routes: routeMatrix,
    configRouteSpecs: configRoutes,
    spokes: Object.fromEntries(
      Object.entries(ctx.spokes).map(([k, s]) => [
        k,
        { label: s.label, ccipChainSelector: s.ccipChainSelector, lzEid: s.lzEid },
      ]),
    ),
  }

  const jsonOut = process.env.JSON === '1' || process.argv.includes('--json')
  if (jsonOut) {
    console.log(JSON.stringify(report, null, 2))
    return
  }

  console.log(`\n=== Adapter inspection: ${adapter} ===`)
  console.log(`Chain: ${ctx.hub.label} (${ctx.hub.chainId})`)
  console.log(`Type:  ${typeAndVersion}`)
  if (matchedProfile) console.log(`Profile: ${matchedProfile}`)
  console.log(`Role holders among ${candidates.length} candidate address(es) (AccessControl is not enumerable):`)
  console.log(`Admins:       ${admins.join(', ') || '(none)'}`)
  console.log(`Fee setters:  ${feeSetters.join(', ') || '(none)'}`)
  console.log(`Fee collectors: ${feeCollectors.join(', ') || '(none)'}`)

  console.log(`\n--- Proxy ---`)
  console.log(`Factory:         ${ctx.factory ?? 'n/a'}`)
  console.log(`Implementation:  ${implementation ?? 'n/a'}`)
  if (factoryInfo) console.log(`Factory clones:  ${factoryInfo.count} (${factoryInfo.adapters.join(', ')})`)
  else if (ctx.factory) console.log(`Factory clones:  set FACTORY_FROM_BLOCK=<factory deploy block> to list them`)

  console.log(`\n--- Transport ---`)
  console.log(`CCIP router:     ${ccipRouter} ${report.transport.configRouterMatch ? '✓' : '≠ config'}`)
  console.log(`LZ endpoint:     ${lzEndpoint} ${report.transport.configEndpointMatch ? '✓' : '≠ config'}`)
  console.log(`Native balance:  ${formatEther(ethBalance)} ETH`)
  console.log(`LZ prefund req:  ${requireLzPrefund}${configRequireLzPrefund !== undefined ? ` (config: ${configRequireLzPrefund}${configRequireLzPrefund === requireLzPrefund ? ' ✓' : ' ≠ on-chain'})` : ''}`)
  console.log(`LOCAL dest key:  ${localDest}`)

  console.log(`\n--- Return-leg fees (CCIP inbound skim) ---`)
  if (inboundFeeChecks.length === 0) {
    console.log('  (no inboundFees in config for this adapter block)')
  }
  for (const f of inboundFeeChecks) {
    console.log(
      `  ${f.outboundToken} @ ${f.destination} (${f.destinationLabel}): on-chain=${f.onChainFee} config=${f.configFee}${f.match ? ' ✓' : ' ≠ config'}`,
    )
  }
  console.log(`\n--- Accrued inbound fees (withdraw via FEE_COLLECTOR_ROLE) ---`)
  console.log(`  ${vaultStats[2].symbol}: ${formatUnits(assetCollected, vaultStats[2].decimals)} (${assetCollected} raw)`)
  console.log(`  shares: ${formatUnits(shareCollected, vaultStats[3].decimals)} (${shareCollected} raw)`)

  console.log(`\n--- Vault ---`)
  console.log(`Vault:           ${vault}`)
  console.log(`Asset:           ${asset} (${vaultStats[2].symbol}, ${vaultStats[2].decimals} dec)`)
  console.log(`Total assets:    ${formatUnits(vaultStats[0], vaultStats[2].decimals)} ${vaultStats[2].symbol}`)
  console.log(`Total supply:    ${formatUnits(vaultStats[1], vaultStats[2].decimals)} shares`)
  console.log(`On adapter:      ${vaultStats[4].balanceFormatted} ${vaultStats[2].symbol}, ${vaultStats[3].balanceFormatted} shares`)

  console.log(`\n--- Inbound allowlists ---`)
  if (ccipSources.length === 0) console.log('  (no CCIP sources enabled)')
  for (const s of ccipSources) {
    console.log(`  CCIP src ${s.selector}  ${s.label}${s.svm ? ` [SVM cu=${s.svm.computeUnits}]` : ''}`)
  }
  if (lzOfts.length === 0) console.log('  (no LZ/Stargate OFT inbound)')
  for (const o of lzOfts) {
    console.log(`  LZ oft eid=${o.srcEid} ${o.label}  oft=${o.oft}  token=${o.underlying ?? '?'}`)
  }

  console.log(`\n--- Outbound allowlists ---`)
  if (ccipDests.length === 0) console.log('  (no CCIP destinations enabled)')
  for (const d of ccipDests) console.log(`  CCIP dst ${d.selector}  ${d.label}`)
  if (lzDests.length === 0 && stargateDests.length === 0) console.log('  (no LZ/Stargate outbound)')
  for (const d of lzDests) console.log(`  LZ dst eid=${d.eid}  ${d.label}`)
  for (const d of stargateDests) console.log(`  Stargate dst eid=${d.eid}  ${d.label}`)

  if (oftMap.length > 0) {
    console.log(`\n--- OFT map (legacy bounce / default) ---`)
    for (const m of oftMap) console.log(`  ${m.token} → ${m.oft}`)
  }

  console.log(`\n--- Route registry (enabled paths) ---`)
  if (routeMatrix.length === 0) console.log('  (no routes enabled)')
  for (const r of routeMatrix) {
    console.log(
      `  ${r.token} @ dest ${r.destinationKey} (${r.destinationLabel})`,
    )
    console.log(
      `    → ${r.rail} dstId=${r.dstId} (${r.dstIdLabel}) endpoint=${r.endpoint} gas=${r.gasLimit}`,
    )
  }

  console.log(`\n--- Config route specs (for comparison) ---`)
  for (const r of configRoutes) {
    console.log(`  ${r.token} → ${r.destination} (${r.destinationLabel}) via ${r.rail}`)
  }

  console.log(`\nINSPECT_RESULT=${JSON.stringify({ ok: true, adapter, profile: matchedProfile, routes: routeMatrix.length, ccipSources: ccipSources.length, lzOfts: lzOfts.length })}`)
}

main().catch((err) => {
  // Set E2E_DEBUG=1 for the full stack trace.
  console.error(process.env.E2E_DEBUG ? err : `error: ${err instanceof Error ? err.message : String(err)}`)
  process.exit(1)
})
