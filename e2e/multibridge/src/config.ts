import { existsSync, readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { type Address, type Hex } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import 'dotenv/config'

const here = dirname(fileURLToPath(import.meta.url))
/** Repo root, three levels above `e2e/multibridge/src`. */
const repoRoot = resolve(here, '../../..')

function resolveConfigPath(): string {
  const rel = process.env.CONFIG ?? 'config/multibridge/tenderly.json'
  if (rel.startsWith('/')) return rel
  // Accept `config/multibridge/sepolia.json`, `./config/...`, or `../config/...` — all relative to repo root.
  const normalized = rel.replace(/^\.\/?/, '').replace(/^(?:\.\.\/)+/, '')
  return resolve(repoRoot, normalized)
}

/** Reads the JSON config selected by `CONFIG`, with an actionable error when it doesn't exist. */
function readConfigFile(configPath: string): string {
  if (!existsSync(configPath)) {
    throw new Error(
      `config file not found: ${configPath}\n` +
        '  Tenderly: cp config/multibridge/tenderly.example.json config/multibridge/tenderly.json and fill it in.\n' +
        '  Sepolia:  set CONFIG=config/multibridge/sepolia.json (in e2e/multibridge/.env or the environment).',
    )
  }
  return readFileSync(configPath, 'utf-8')
}

/** A hub/spoke network block from config/multibridge/tenderly.json. */
export interface Net {
  label: string
  rpcUrlEnv: string
  chainId: number
  ccipRouter: Address
  lzEndpoint: Address
  ccipChainSelector: string // kept as string: selectors exceed JS safe-integer range
  lzEid: number
  /** CCIP-bridged vault share token on this spoke (redeem inbound). */
  shareToken?: Address
}

export interface VaultMessageCfg {
  minAmountOut: string
  /** Outbound destination: a CCIP selector (> uint32.max) or a LayerZero EID. The user's chosen path. */
  destination: string
  /** Override `destination` from the active spoke: `ccip` = share delivery via CCIP; `stargate` = USDT via Stargate LZ EID. */
  returnTo?: 'ccip' | 'stargate'
  recipient: Address
  /** Party allowed to retry / refund-local a base transport failure. address(0) => bounce-to-source only. */
  failedMessageHandler: Address
  /**
   * When true, a failed message can only be recovered by `failedMessageHandler` (retry or local refund);
   * the permissionless bounce to source is disabled. Requires a non-zero handler. Defaults to false.
   */
  onlyLocalRefund?: boolean
}

export interface AdapterProfile {
  app: Address
  vault: Address
  asset: Address
  share: Address
}

export interface Scenario {
  /** Hub adapter profile (`adapters.usdt` / `adapters.usdc` in config). Defaults to `usdt`. */
  adapter?: string
  /** Key into config `spokes` (or legacy single `spoke`). Defaults to the first spoke. */
  spoke?: string
  /** Use the active spoke's `shareToken` as `srcToken` (redeem flows). */
  useSpokeShareToken?: boolean
  /**
   * Intentionally breach vault slippage on the hub (`minAmountOut` → max uint256) so the adapter
   * reverts and the base captures the inbound (MessageFailed). Use with recover.ts + refundToSource.
   */
  failSlippage?: boolean
  channel: 'ccip' | 'layerzero'
  /** Which chain to broadcast the originate tx from. Defaults to `spoke`. */
  originateOn?: 'hub' | 'spoke'
  srcToken: Address
  srcOft: Address
  amount: string
  inboundGasLimit: number
  lzReceiveGasLimit: number
  /** Native (wei) attached to a LayerZero compose to pre-pay the outbound return leg. 0 = don't prefund. */
  returnLegValueWei: string
  message: VaultMessageCfg
}

export interface Deployment {
  chainId: number
  app: Address
  factory: Address
  implementation: Address
}

export interface Loaded {
  hub: Net
  /** Active spoke for this scenario (resolved from scenario.spoke or legacy config.spoke). */
  spoke: Net
  scenario: Scenario
  deployment: Deployment
  /** Resolved originate RPC URL (hub or spoke, per scenario.originateOn). */
  originateRpcUrl: string
  /** The network block used to originate (hub or spoke). */
  originateNet: Net
  account: ReturnType<typeof privateKeyToAccount>
  /** CCIP inbound fee (inbound token units) skimmed on hub delivery; 0 when disabled or N/A (LZ). */
  expectedInboundFee: string
  /** Hub policy: LZ inbound must attach compose value for bridged return legs. */
  requireLzReturnPrefunded: boolean
}

/**
 * Selectors and wei amounts can exceed JS's safe-integer range, so we re-read the raw JSON text and
 * pull those fields out as strings before they are lossily parsed into Numbers. JSON.parse itself is
 * fine for everything else (addresses, small ints, bools).
 */
function readSelectorString(rawJson: string, path: string[]): string {
  const key = path[path.length - 1]
  const re = new RegExp(`"${key}"\\s*:\\s*(?:"(0x[0-9a-fA-F]+)"|([0-9]+))`)
  const m = rawJson.match(re)
  if (!m) throw new Error(`could not read big-int field "${path.join('.')}" from config`)
  return m[1] ? BigInt(m[1]).toString() : m[2]
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

/** Resolve `spokes` map or fall back to legacy single `spoke` block. */
function loadSpokes(raw: string, json: Record<string, unknown>): Record<string, Net> {
  const spokes = json.spokes as Record<string, Net> | undefined
  if (spokes && Object.keys(spokes).length > 0) {
    for (const key of Object.keys(spokes)) {
      spokes[key].ccipChainSelector = readSelectorInObject(raw, key, 'ccipChainSelector')
    }
    return spokes
  }

  const legacy = json.spoke as Net | undefined
  if (!legacy) throw new Error('config must define "spokes" or legacy "spoke"')
  legacy.ccipChainSelector = readSelectorString(raw, ['spoke', 'ccipChainSelector'])
  return { default: legacy }
}

function resolveSpoke(spokes: Record<string, Net>, scenario: Scenario): Net {
  const key = scenario.spoke ?? Object.keys(spokes)[0]
  const spoke = spokes[key]
  if (!spoke) {
    throw new Error(
      `unknown spoke "${key}" — available: ${Object.keys(spokes).join(', ')} (set scenario.spoke in config)`,
    )
  }
  return spoke
}

function spokeKeyToEnv(key: string): string {
  return key.replace(/([a-z])([A-Z])/g, '$1_$2').replace(/[^a-zA-Z0-9]+/g, '_').toUpperCase()
}

export interface HubLoaded {
  hub: Net
  deployment: Deployment
  account: ReturnType<typeof privateKeyToAccount>
}

/** Hub-only config for recover / status checks (no SCENARIO required). */
export function loadHubConfig(): HubLoaded {
  const configPath = resolveConfigPath()
  const raw = readConfigFile(configPath)
  const json = JSON.parse(raw) as Record<string, unknown>

  json.hub = json.hub as Net
  ;(json.hub as Net).ccipChainSelector = readSelectorString(raw, ['hub', 'ccipChainSelector'])

  const hub = json.hub as Net
  const deployment = resolveDeployment(hub.chainId, json, process.env.SCENARIO)
  const pk = requireEnv('PRIVATE_KEY') as Hex
  const account = privateKeyToAccount(pk)
  return { hub, deployment, account }
}

export function loadConfig(): Loaded {
  const configPath = resolveConfigPath()
  const raw = readConfigFile(configPath)
  const json = JSON.parse(raw) as Record<string, unknown>

  json.hub = json.hub as Net
  ;(json.hub as Net).ccipChainSelector = readSelectorString(raw, ['hub', 'ccipChainSelector'])

  const spokes = loadSpokes(raw, json)

  const scenarioKey = process.env.SCENARIO ?? 'default'
  const scenarioBlock =
    scenarioKey === 'default'
      ? (json.scenario as Scenario | undefined)
      : ((json.scenarios as Record<string, Scenario> | undefined)?.[scenarioKey] ??
        (json.scenario as Scenario | undefined))
  if (!scenarioBlock) {
    throw new Error(`unknown SCENARIO "${scenarioKey}" — set SCENARIO or add scenarios.${scenarioKey} in the config`)
  }

  const blockPath = scenarioKey === 'default' ? 'scenario' : `scenarios.${scenarioKey}`

  scenarioBlock.amount = bigFieldInBlock(raw, blockPath, 'amount')
  scenarioBlock.returnLegValueWei = bigFieldInBlock(raw, blockPath, 'returnLegValueWei')
  scenarioBlock.message.minAmountOut = bigFieldInBlock(raw, blockPath, 'minAmountOut', 'message')
  scenarioBlock.message.destination = bigFieldInBlock(raw, blockPath, 'destination', 'message')

  const hub = json.hub as Net
  const spoke = resolveSpoke(spokes, scenarioBlock)
  const scenario = scenarioBlock

  if (scenario.useSpokeShareToken) {
    const envKey = `SPOKE_${spokeKeyToEnv(scenario.spoke ?? Object.keys(spokes)[0])}_SHARE_TOKEN`
    const fromEnv = process.env[envKey] as Address | undefined
    const token = fromEnv ?? spoke.shareToken
    if (!token || token === '0x0000000000000000000000000000000000000000') {
      throw new Error(
        `redeem needs the CCIP share token on ${spoke.label} — set spokes.*.shareToken in config or ${envKey} in e2e/multibridge/.env`,
      )
    }
    scenario.srcToken = token
  }

  if (scenario.message.returnTo === 'ccip') {
    scenario.message.destination = spoke.ccipChainSelector
  } else if (scenario.message.returnTo === 'stargate') {
    scenario.message.destination = String(spoke.lzEid)
  }

  const failSlippage = scenario.failSlippage === true || process.env.FAIL_SLIPPAGE === '1'
  if (failSlippage) {
    scenario.failSlippage = true
    scenario.message.minAmountOut = (2n ** 256n - 1n).toString()
  }

  const deployment = resolveDeployment(hub.chainId, json, scenarioKey)

  const pk = requireEnv('PRIVATE_KEY') as Hex
  const account = privateKeyToAccount(pk)
  if (scenario.message.recipient === '0x0000000000000000000000000000000000000000') {
    scenario.message.recipient = account.address
  }

  const originateOn = scenario.originateOn ?? 'spoke'
  const originateNet = originateOn === 'hub' ? hub : spoke
  const originateRpcUrl = requireEnv(originateNet.rpcUrlEnv)

  const adapterProfile =
    process.env.ADAPTER_PROFILE ??
    scenario.adapter ??
    'usdt'
  const vaKey = adapterProfile === 'usdc' ? 'vaultAdapterUsdc' : 'vaultAdapter'
  const vaBlock = json[vaKey] as Record<string, unknown> | undefined
  const requireLzReturnPrefunded = vaBlock?.requireLzReturnPrefunded === true
  const expectedInboundFee = resolveExpectedInboundFee(scenario, vaBlock)

  return {
    hub,
    spoke,
    scenario,
    deployment,
    originateRpcUrl,
    originateNet,
    account,
    expectedInboundFee,
    requireLzReturnPrefunded,
  }
}

interface InboundFeeSpec {
  outboundToken: 'asset' | 'share'
  destination: number | string
  fee: number
}

/** Match inbound fee from vaultAdapter* config to this scenario's outbound route key. */
function resolveExpectedInboundFee(scenario: Scenario, vaBlock: Record<string, unknown> | undefined): string {
  if (scenario.channel !== 'ccip' || !vaBlock) return '0'
  const fees = vaBlock.inboundFees as InboundFeeSpec[] | undefined
  if (!fees?.length) return '0'

  const isRedeem = scenario.useSpokeShareToken === true
  const outboundToken = isRedeem ? 'asset' : 'share'
  const destination = scenario.message.destination

  const match = fees.find(
    (f) => f.outboundToken === outboundToken && String(f.destination) === destination,
  )
  return match ? String(match.fee) : '0'
}

function bigField(rawJson: string, key: string): string {
  const re = new RegExp(`"${key}"\\s*:\\s*(?:"(0x[0-9a-fA-F]+)"|([0-9]+))`)
  const m = rawJson.match(re)
  if (!m) throw new Error(`could not read big-int field "${key}" from config`)
  return m[1] ? BigInt(m[1]).toString() : m[2]
}

function bigFieldInBlock(rawJson: string, blockPath: string, key: string, nested?: string): string {
  const blockRe = new RegExp(`"${blockPath.split('.').pop()}"\\s*:\\s*\\{`, 'g')
  if (blockPath.includes('.')) {
    const parent = blockPath.split('.')[0]
    const parentIdx = rawJson.indexOf(`"${parent}"`)
    if (parentIdx < 0) throw new Error(`could not find block "${blockPath}" in config`)
    const slice = rawJson.slice(parentIdx)
    const child = blockPath.split('.')[1]
    const childIdx = slice.indexOf(`"${child}"`)
    if (childIdx < 0) throw new Error(`could not find block "${blockPath}" in config`)
    return bigFieldInSlice(slice.slice(childIdx), key, nested)
  }
  blockRe.lastIndex = 0
  const m = blockRe.exec(rawJson)
  if (!m) throw new Error(`could not find block "${blockPath}" in config`)
  return bigFieldInSlice(rawJson.slice(m.index), key, nested)
}

function bigFieldInSlice(slice: string, key: string, nested?: string): string {
  const scope = nested
    ? slice.slice(slice.indexOf(`"${nested}"`), slice.indexOf('}', slice.indexOf(`"${nested}"`)) + 200)
    : slice.slice(0, Math.min(slice.length, 4000))
  return bigField(scope, key)
}

function loadDeployment(hubChainId: number): Deployment {
  const path = resolve(repoRoot, 'deployments', 'multibridge', `${hubChainId}.json`)
  try {
    return JSON.parse(readFileSync(path, 'utf-8')) as Deployment
  } catch {
    throw new Error(
      `no deployment found at deployments/multibridge/${hubChainId}.json — run script/multibridge/tenderly/DeployVaultAdapter.s.sol on the hub first (see docs/multibridge/development/TENDERLY_E2E.md).`,
    )
  }
}

function resolveDeployment(hubChainId: number, json: Record<string, unknown>, scenarioKey?: string): Deployment {
  const deployment = loadDeployment(hubChainId)
  const adapters = json.adapters as Record<string, AdapterProfile> | undefined
  const scenarios = json.scenarios as Record<string, Scenario> | undefined
  const profile =
    process.env.ADAPTER_PROFILE ??
    scenarios?.[scenarioKey ?? '']?.adapter ??
    (scenarioKey === 'default' ? undefined : scenarios?.default?.adapter) ??
    'usdt'
  if (adapters?.[profile]?.app) {
    deployment.app = adapters[profile].app
  }
  if (process.env.ADAPTER) {
    deployment.app = process.env.ADAPTER as Address
  }
  if (!deployment.app || deployment.app === '0x0000000000000000000000000000000000000000') {
    throw new Error(
      `adapter app not set for profile "${profile}" — deploy the clone, paste adapters.${profile}.app in config, or set ADAPTER`,
    )
  }
  return deployment
}

function requireEnv(name: string): string {
  const v = process.env[name]
  if (!v) throw new Error(`missing required env var ${name} (see e2e/multibridge/.env.example)`)
  return v
}
