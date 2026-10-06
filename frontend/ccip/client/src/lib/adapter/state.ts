import {
  createPublicClient,
  http,
  getAddress,
  parseAbiItem,
  type Address,
  type PublicClient,
  type Hex,
  type AbiEvent,
} from "viem";
import {
  ADAPTER_ABI,
  ERC4626_ABI,
  ERC20_ABI,
  DEFAULT_ADMIN_ROLE,
  CHAIN_TYPE,
  ERROR_CODE,
  SUPPORTED_TYPE_AND_VERSION,
  type ChainType,
  type ErrorCode,
} from "./abi";
import { getChainById, type CCIPChain } from "@/config/ccip.config";
import { describeSelector } from "./networks";

// ----------------------------------------------------------------------------
// Types
// ----------------------------------------------------------------------------

export interface TokenMeta {
  address: Address;
  name: string;
  symbol: string;
  decimals: number;
}

export interface VaultInfo {
  target: Address;
  enabled: boolean;
  share: { name: string; symbol: string; decimals: number };
  underlying: TokenMeta;
  totalAssets: bigint;
  totalSupply: bigint;
  exchangeRate?: bigint; // convertToAssets(1 share)
}

export interface ConfiguredChain {
  selector: string;
  type: ChainType;
  label: string;
  family: "EVM" | "SVM" | "UNKNOWN";
}

export interface AssetFeeRow {
  destinationChainSelector: string;
  bridgedToken: Address;
  fee: bigint;
}

export interface CollectedFeeRow {
  asset: Address;
  amount: bigint;
  symbol?: string;
  decimals?: number;
}

export interface CcvRow {
  sourceChainSelector: string;
  requiredCCVs: Address[];
  optionalCCVs: Address[];
  optionalThreshold: number;
  allowedFinalityConfig: Hex;
}

export interface FailedTokenAmount {
  token: Address;
  amount: bigint;
}

export interface FailedMessage {
  messageId: Hex;
  errorCode: ErrorCode;
  sourceChainSelector: string;
  sourceLabel: string;
  sender: Hex;
  localRefundAddress: Address;
  destTokenAmounts: FailedTokenAmount[];
  canRefund: boolean;
  requiredRefundFee?: bigint;
  canRecoverLocally: boolean;
  localRecoveryAddress?: Address;
  blockNumber?: bigint;
  txHash?: Hex;
}

export interface ActivityItem {
  kind: string;
  messageId?: Hex;
  blockNumber: bigint;
  txHash: Hex;
  logIndex: number;
  args: Record<string, unknown>;
}

export interface AdapterState {
  meta: {
    adapter: Address;
    hubChainId: number;
    hubChainName: string;
    typeAndVersion: string;
    router: Address;
    explorerUrl: string;
  };
  processing: { depositsEnabled: boolean; redeemsEnabled: boolean };
  roles: {
    admins: Address[];
    feeSetters: Address[];
    feeCollectors: Address[];
    feeSetterRole: Hex;
    feeCollectorRole: Hex;
  };
  vaults: VaultInfo[];
  chains: ConfiguredChain[];
  assetFees: AssetFeeRow[];
  collectedFees: CollectedFeeRow[];
  ccv: CcvRow[];
  failedMessages: FailedMessage[];
  activity: ActivityItem[];
  scan: { fromBlock: bigint; toBlock: bigint };
}

// ----------------------------------------------------------------------------
// Client + verification
// ----------------------------------------------------------------------------

export function buildHubClient(chain: CCIPChain): PublicClient {
  return createPublicClient({
    chain: {
      id: chain.id,
      name: chain.name,
      nativeCurrency: chain.nativeCurrency,
      rpcUrls: { default: { http: [chain.rpcUrl] } },
      blockExplorers: { default: { name: "Explorer", url: chain.explorerUrl } },
    },
    transport: http(chain.rpcUrl),
  });
}

export interface AdapterContext {
  adapter: Address;
  hubChainId: number;
  chain: CCIPChain;
  client: PublicClient;
  typeAndVersion: string;
}

export async function loadAdapterContext(
  adapterAddress: string,
  hubChainId: number,
): Promise<AdapterContext> {
  const chain = getChainById(hubChainId);
  if (!chain) throw new Error(`Unknown hub chain id ${hubChainId}`);
  const adapter = getAddress(adapterAddress);
  const client = buildHubClient(chain);

  let typeAndVersion: string;
  try {
    typeAndVersion = (await client.readContract({
      address: adapter,
      abi: ADAPTER_ABI,
      functionName: "typeAndVersion",
    })) as string;
  } catch (e) {
    throw new Error(
      `Could not read typeAndVersion at ${adapter} on ${chain.name}. ` +
        `Confirm the address is a CrossChainERC4626Adapter on the selected network.`,
    );
  }
  if (!SUPPORTED_TYPE_AND_VERSION.test(typeAndVersion)) {
    throw new Error(
      `Address is not a CrossChainERC4626Adapter (typeAndVersion = "${typeAndVersion}").`,
    );
  }
  return { adapter, hubChainId, chain, client, typeAndVersion };
}

// ----------------------------------------------------------------------------
// Chunked log scanning (with localStorage caching)
// ----------------------------------------------------------------------------

const DEFAULT_CHUNK = 9_000n;
const DEFAULT_LOOKBACK = 4_000_000n; // bounded deep scan window

function cacheKey(chainId: number, adapter: string) {
  return `vault-scan:${chainId}:${adapter.toLowerCase()}`;
}

export function getCachedDeployBlock(chainId: number, adapter: string): bigint | undefined {
  try {
    const raw = localStorage.getItem(cacheKey(chainId, adapter));
    if (!raw) return undefined;
    const parsed = JSON.parse(raw);
    return parsed.fromBlock ? BigInt(parsed.fromBlock) : undefined;
  } catch {
    return undefined;
  }
}

function rememberScan(chainId: number, adapter: string, fromBlock: bigint) {
  try {
    localStorage.setItem(
      cacheKey(chainId, adapter),
      JSON.stringify({ fromBlock: fromBlock.toString() }),
    );
  } catch {
    /* ignore quota errors */
  }
}

/**
 * Robust getLogs across RPCs that cap block ranges. Tries a single wide query first;
 * on failure falls back to chunked scanning from a bounded lookback to `latest`.
 */
export async function scanLogs(
  client: PublicClient,
  address: Address,
  events: AbiEvent[],
  opts: { fromBlock?: bigint; toBlock?: bigint } = {},
): Promise<{ logs: any[]; fromBlock: bigint; toBlock: bigint }> {
  const latest = opts.toBlock ?? (await client.getBlockNumber());
  let from = opts.fromBlock ?? (latest > DEFAULT_LOOKBACK ? latest - DEFAULT_LOOKBACK : 0n);

  // Attempt single wide query.
  try {
    const logs = await client.getLogs({ address, events, fromBlock: from, toBlock: latest });
    return { logs, fromBlock: from, toBlock: latest };
  } catch {
    // fall through to chunked
  }

  const all: any[] = [];
  let start = from;
  while (start <= latest) {
    const end = start + DEFAULT_CHUNK > latest ? latest : start + DEFAULT_CHUNK;
    try {
      const logs = await client.getLogs({ address, events, fromBlock: start, toBlock: end });
      all.push(...logs);
    } catch {
      // shrink chunk on failure
      const mid = start + (end - start) / 2n;
      if (mid > start) {
        try {
          all.push(
            ...(await client.getLogs({ address, events, fromBlock: start, toBlock: mid })),
          );
          all.push(
            ...(await client.getLogs({ address, events, fromBlock: mid + 1n, toBlock: end })),
          );
        } catch {
          /* give up on this window */
        }
      }
    }
    start = end + 1n;
  }
  return { logs: all, fromBlock: from, toBlock: latest };
}

// ----------------------------------------------------------------------------
// Reads
// ----------------------------------------------------------------------------

async function readTokenMeta(client: PublicClient, address: Address): Promise<TokenMeta> {
  const [name, symbol, decimals] = await Promise.all([
    client
      .readContract({ address, abi: ERC20_ABI, functionName: "name" })
      .catch(() => "Unknown"),
    client
      .readContract({ address, abi: ERC20_ABI, functionName: "symbol" })
      .catch(() => "???"),
    client
      .readContract({ address, abi: ERC20_ABI, functionName: "decimals" })
      .catch(() => 18),
  ]);
  return { address, name: name as string, symbol: symbol as string, decimals: Number(decimals) };
}

async function readVaultInfo(
  client: PublicClient,
  target: Address,
  enabled: boolean,
): Promise<VaultInfo | null> {
  try {
    const asset = (await client.readContract({
      address: target,
      abi: ERC4626_ABI,
      functionName: "asset",
    })) as Address;

    const [vName, vSymbol, vDecimals, totalAssets, totalSupply] = await Promise.all([
      client.readContract({ address: target, abi: ERC4626_ABI, functionName: "name" }).catch(() => "Vault"),
      client.readContract({ address: target, abi: ERC4626_ABI, functionName: "symbol" }).catch(() => "vSHARE"),
      client.readContract({ address: target, abi: ERC4626_ABI, functionName: "decimals" }).catch(() => 18),
      client.readContract({ address: target, abi: ERC4626_ABI, functionName: "totalAssets" }).catch(() => 0n),
      client.readContract({ address: target, abi: ERC4626_ABI, functionName: "totalSupply" }).catch(() => 0n),
    ]);

    const underlying = await readTokenMeta(client, asset);
    const oneShare = 10n ** BigInt(Number(vDecimals));
    const exchangeRate = (await client
      .readContract({
        address: target,
        abi: ERC4626_ABI,
        functionName: "convertToAssets",
        args: [oneShare],
      })
      .catch(() => undefined)) as bigint | undefined;

    return {
      target,
      enabled,
      share: { name: vName as string, symbol: vSymbol as string, decimals: Number(vDecimals) },
      underlying,
      totalAssets: totalAssets as bigint,
      totalSupply: totalSupply as bigint,
      exchangeRate,
    };
  } catch {
    return null;
  }
}

const EV_TargetEnabled = parseAbiItem(
  "event TargetEnabled(address indexed target, bool enabled)",
) as AbiEvent;
const EV_ChainTypeSet = parseAbiItem(
  "event ChainTypeSet(uint64 indexed chainSelector, uint8 chainType)",
) as AbiEvent;
const EV_AssetFeeSet = parseAbiItem(
  "event AssetFeeSet(uint64 indexed destinationChainSelector, address indexed bridgedToken, uint256 fee)",
) as AbiEvent;
const EV_CCVsConfigSet = parseAbiItem(
  "event CCVsConfigSet(uint64 indexed sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold)",
) as AbiEvent;
const EV_FeeWithdrawn = parseAbiItem(
  "event FeeWithdrawn(address indexed asset, address indexed recipient, uint256 amount)",
) as AbiEvent;

const ACTIVITY_EVENTS: AbiEvent[] = [
  parseAbiItem("event MessageSucceeded(bytes32 indexed messageId)"),
  parseAbiItem("event MessageFailed(bytes32 indexed messageId)"),
  parseAbiItem(
    "event TargetProcessed(bytes32 indexed messageId, address indexed target, address indexed inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount)",
  ),
  parseAbiItem(
    "event MessageSent(bytes32 indexed messageId, uint64 indexed destinationChainSelector, uint8 indexed chainType, bytes32 beneficiary, address token, uint256 amount, uint256 fee)",
  ),
  parseAbiItem(
    "event LocalTokenDelivered(bytes32 indexed messageId, address indexed token, address indexed beneficiary, uint256 amount)",
  ),
  parseAbiItem(
    "event MessageRefunded(bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary)",
  ),
  parseAbiItem(
    "event MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress)",
  ),
] as AbiEvent[];

async function enrichFailedMessage(
  client: PublicClient,
  adapter: Address,
  messageId: Hex,
  blockNumber?: bigint,
  txHash?: Hex,
): Promise<FailedMessage | null> {
  const code = Number(
    await client.readContract({
      address: adapter,
      abi: ADAPTER_ABI,
      functionName: "messageErrorCode",
      args: [messageId],
    }),
  );
  const errorCode = ERROR_CODE[code] ?? "NONE";

  let record: any;
  try {
    record = await client.readContract({
      address: adapter,
      abi: ADAPTER_ABI,
      functionName: "getFailedMessageRecord",
      args: [messageId],
    });
  } catch {
    record = undefined;
  }

  const sourceChainSelector = record?.sourceChainSelector?.toString() ?? "0";
  const desc = describeSelector(sourceChainSelector);

  // Non-reverting preflights — wrap defensively (checkRefundEligibility can revert).
  let canRefund = false;
  let requiredRefundFee: bigint | undefined;
  try {
    const r = (await client.readContract({
      address: adapter,
      abi: ADAPTER_ABI,
      functionName: "checkRefundEligibility",
      args: [messageId],
    })) as readonly [boolean, Hex, Address, bigint, bigint];
    canRefund = r[0];
    requiredRefundFee = r[4];
  } catch {
    canRefund = false;
  }

  let canRecoverLocally = false;
  let localRecoveryAddress: Address | undefined;
  try {
    const r = (await client.readContract({
      address: adapter,
      abi: ADAPTER_ABI,
      functionName: "checkLocalRecoveryEligibility",
      args: [messageId],
    })) as readonly [boolean, Address, Address, bigint];
    canRecoverLocally = r[0];
    localRecoveryAddress = r[1];
  } catch {
    canRecoverLocally = false;
  }

  const destTokenAmounts: FailedTokenAmount[] =
    record?.destTokenAmounts?.map((t: any) => ({ token: t.token as Address, amount: t.amount as bigint })) ?? [];

  return {
    messageId,
    errorCode,
    sourceChainSelector,
    sourceLabel: desc.label,
    sender: (record?.sender as Hex) ?? "0x",
    localRefundAddress: (record?.localRefundAddress as Address) ?? "0x0000000000000000000000000000000000000000",
    destTokenAmounts,
    canRefund,
    requiredRefundFee,
    canRecoverLocally,
    localRecoveryAddress,
    blockNumber,
    txHash,
  };
}

async function roleMembers(
  client: PublicClient,
  adapter: Address,
  role: Hex,
): Promise<Address[]> {
  try {
    const count = Number(
      await client.readContract({
        address: adapter,
        abi: ADAPTER_ABI,
        functionName: "getRoleMemberCount",
        args: [role],
      }),
    );
    const members = await Promise.all(
      Array.from({ length: count }, (_, i) =>
        client.readContract({
          address: adapter,
          abi: ADAPTER_ABI,
          functionName: "getRoleMember",
          args: [role, BigInt(i)],
        }),
      ),
    );
    return members as Address[];
  } catch {
    return [];
  }
}

// ----------------------------------------------------------------------------
// Top-level loader
// ----------------------------------------------------------------------------

export async function readAdapterState(ctx: AdapterContext): Promise<AdapterState> {
  const { client, adapter, chain } = ctx;

  // 1. Scalars + role ids
  const [
    typeAndVersion,
    router,
    depositsEnabled,
    redeemsEnabled,
    feeSetterRole,
    feeCollectorRole,
  ] = await Promise.all([
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "typeAndVersion" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "ROUTER" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "depositsEnabled" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "redeemsEnabled" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "FEE_SETTER_ROLE" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "FEE_COLLECTOR_ROLE" }),
  ]);

  // 2. Event scan (single pass over discovery + activity events)
  const allEvents: AbiEvent[] = [
    EV_TargetEnabled,
    EV_ChainTypeSet,
    EV_AssetFeeSet,
    EV_CCVsConfigSet,
    EV_FeeWithdrawn,
    ...ACTIVITY_EVENTS,
  ];
  const cachedFrom = getCachedDeployBlock(chain.id, adapter);
  const { logs, fromBlock, toBlock } = await scanLogs(client, adapter, allEvents, {
    fromBlock: cachedFrom,
  });
  rememberScan(chain.id, adapter, fromBlock);

  const byName = (name: string) => logs.filter((l) => l.eventName === name);

  // 3. Vaults (latest TargetEnabled state per target, then verify + metadata)
  const targetLatest = new Map<string, boolean>();
  for (const log of byName("TargetEnabled")) {
    targetLatest.set(getAddress(log.args.target as Address), Boolean(log.args.enabled));
  }
  const vaultEntries = await Promise.all(
    [...targetLatest.entries()].map(async ([target, _enabledFromLog]) => {
      const enabled = (await client
        .readContract({
          address: adapter,
          abi: ADAPTER_ABI,
          functionName: "enabledTargets",
          args: [target as Address],
        })
        .catch(() => false)) as boolean;
      return readVaultInfo(client, target as Address, enabled);
    }),
  );
  const vaults = vaultEntries.filter((v): v is VaultInfo => v !== null);

  // 4. Configured chains (latest ChainTypeSet per selector, verify via chains())
  const chainLatest = new Map<string, number>();
  for (const log of byName("ChainTypeSet")) {
    chainLatest.set((log.args.chainSelector as bigint).toString(), Number(log.args.chainType));
  }
  const chains: ConfiguredChain[] = await Promise.all(
    [...chainLatest.keys()].map(async (selector) => {
      const t = Number(
        await client
          .readContract({
            address: adapter,
            abi: ADAPTER_ABI,
            functionName: "chains",
            args: [BigInt(selector)],
          })
          .catch(() => 0),
      );
      const desc = describeSelector(selector);
      return {
        selector,
        type: CHAIN_TYPE[t] ?? "NONE",
        label: desc.label,
        family: desc.family,
      };
    }),
  );

  // 5. Asset fees (latest per (selector, token))
  const feeLatest = new Map<string, { selector: string; token: Address }>();
  for (const log of byName("AssetFeeSet")) {
    const selector = (log.args.destinationChainSelector as bigint).toString();
    const token = getAddress(log.args.bridgedToken as Address);
    feeLatest.set(`${selector}:${token}`, { selector, token });
  }
  const assetFees: AssetFeeRow[] = await Promise.all(
    [...feeLatest.values()].map(async ({ selector, token }) => {
      const fee = (await client
        .readContract({
          address: adapter,
          abi: ADAPTER_ABI,
          functionName: "assetFees",
          args: [BigInt(selector), token],
        })
        .catch(() => 0n)) as bigint;
      return { destinationChainSelector: selector, bridgedToken: token, fee };
    }),
  );

  // 6. Collected fees (union of vault underlyings + share tokens + fee-withdrawn assets)
  const feeAssets = new Set<string>();
  for (const v of vaults) {
    feeAssets.add(getAddress(v.underlying.address));
    feeAssets.add(getAddress(v.target));
  }
  for (const log of byName("FeeWithdrawn")) feeAssets.add(getAddress(log.args.asset as Address));
  for (const f of assetFees) feeAssets.add(getAddress(f.bridgedToken));
  const collectedFees: CollectedFeeRow[] = (
    await Promise.all(
      [...feeAssets].map(async (asset): Promise<CollectedFeeRow | null> => {
        const amount = (await client
          .readContract({
            address: adapter,
            abi: ADAPTER_ABI,
            functionName: "collectedFees",
            args: [asset as Address],
          })
          .catch(() => 0n)) as bigint;
        if (amount === 0n) return null;
        const meta = vaults.find(
          (v) => getAddress(v.underlying.address) === asset || getAddress(v.target) === asset,
        );
        const isUnderlying = meta ? getAddress(meta.underlying.address) === asset : false;
        return {
          asset: asset as Address,
          amount,
          symbol: meta ? (isUnderlying ? meta.underlying.symbol : meta.share.symbol) : undefined,
          decimals: meta ? (isUnderlying ? meta.underlying.decimals : meta.share.decimals) : undefined,
        };
      }),
    )
  ).filter((x): x is CollectedFeeRow => x !== null);

  // 7. CCV config (per source selector from CCVsConfigSet)
  const ccvSelectors = new Set<string>();
  for (const log of byName("CCVsConfigSet"))
    ccvSelectors.add((log.args.sourceChainSelector as bigint).toString());
  const ccv: CcvRow[] = (
    await Promise.all(
      [...ccvSelectors].map(async (selector) => {
        try {
          const r = (await client.readContract({
            address: adapter,
            abi: ADAPTER_ABI,
            functionName: "getCCVsAndFinalityConfig",
            args: [BigInt(selector), "0x"],
          })) as readonly [Address[], Address[], number, Hex];
          return {
            sourceChainSelector: selector,
            requiredCCVs: r[0] as Address[],
            optionalCCVs: r[1] as Address[],
            optionalThreshold: Number(r[2]),
            allowedFinalityConfig: r[3],
          };
        } catch {
          return null;
        }
      }),
    )
  ).filter((x): x is CcvRow => x !== null);

  // 8. Failed messages: every MessageFailed id that is still BASIC
  const failedIds = new Map<string, { blockNumber: bigint; txHash: Hex }>();
  for (const log of byName("MessageFailed")) {
    failedIds.set(log.args.messageId as string, {
      blockNumber: log.blockNumber as bigint,
      txHash: log.transactionHash as Hex,
    });
  }
  const failedMessages = (
    await Promise.all(
      [...failedIds.entries()].map(([id, info]) =>
        enrichFailedMessage(client, adapter, id as Hex, info.blockNumber, info.txHash),
      ),
    )
  ).filter((m): m is FailedMessage => m !== null);

  // 9. Roles
  const [admins, feeSetters, feeCollectors] = await Promise.all([
    roleMembers(client, adapter, DEFAULT_ADMIN_ROLE),
    roleMembers(client, adapter, feeSetterRole as Hex),
    roleMembers(client, adapter, feeCollectorRole as Hex),
  ]);

  // 10. Activity feed (most recent first)
  const activityKinds = new Set(ACTIVITY_EVENTS.map((e) => e.name).concat(["FeeWithdrawn"]));
  const activity: ActivityItem[] = logs
    .filter((l) => activityKinds.has(l.eventName))
    .map((l) => ({
      kind: l.eventName as string,
      messageId: (l.args?.messageId as Hex) ?? undefined,
      blockNumber: l.blockNumber as bigint,
      txHash: l.transactionHash as Hex,
      logIndex: Number(l.logIndex ?? 0),
      args: serializeArgs(l.args ?? {}),
    }))
    .sort((a, b) =>
      a.blockNumber === b.blockNumber
        ? b.logIndex - a.logIndex
        : a.blockNumber > b.blockNumber
          ? -1
          : 1,
    );

  return {
    meta: {
      adapter,
      hubChainId: chain.id,
      hubChainName: chain.name,
      typeAndVersion: typeAndVersion as string,
      router: router as Address,
      explorerUrl: chain.explorerUrl,
    },
    processing: {
      depositsEnabled: depositsEnabled as boolean,
      redeemsEnabled: redeemsEnabled as boolean,
    },
    roles: {
      admins,
      feeSetters,
      feeCollectors,
      feeSetterRole: feeSetterRole as Hex,
      feeCollectorRole: feeCollectorRole as Hex,
    },
    vaults,
    chains,
    assetFees,
    collectedFees,
    ccv,
    failedMessages,
    activity,
    scan: { fromBlock, toBlock },
  };
}

function serializeArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = typeof v === "bigint" ? v.toString() : v;
  }
  return out;
}
