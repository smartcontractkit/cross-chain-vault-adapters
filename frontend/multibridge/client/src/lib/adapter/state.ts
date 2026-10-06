import {
  createPublicClient,
  http,
  getAddress,
  decodeAbiParameters,
  decodeErrorResult,
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
  CHANNEL,
  RAIL,
  SUPPORTED_TYPE_AND_VERSION,
  type Channel,
  type RailName,
} from "./abi";
import { decodeVaultMessage } from "./message";
import { getChainById, type CCIPChain } from "@/config/ccip.config";
import { describeSelector } from "./networks";
import { lzChainByEid } from "@/config/lz.config";

// ----------------------------------------------------------------------------
// Types
// ----------------------------------------------------------------------------

export interface TokenMeta {
  address: Address;
  name: string;
  symbol: string;
  decimals: number;
}

/** The single fixed ERC-4626 vault the adapter serves (share token == vault address). */
export interface VaultInfo {
  vault: Address;
  asset: Address;
  share: { name: string; symbol: string; decimals: number };
  underlying: TokenMeta;
  totalAssets: bigint;
  totalSupply: bigint;
  exchangeRate?: bigint; // convertToAssets(1 share)
}

export type AllowlistKind = "ccipSrc" | "ccipDst" | "lzOft" | "lzDst" | "stargateDst";

export interface AllowlistEntry {
  kind: AllowlistKind;
  /** CCIP selector or LayerZero EID (as string). */
  id: string;
  /** For `lzOft`: the allowlisted local OFT/pool. */
  oft?: Address;
  allowed: boolean;
  label: string;
  family: "EVM" | "SVM" | "UNKNOWN";
}

export interface SvmLane {
  selector: string;
  label: string;
  enabled: boolean;
  computeUnits: number;
  allowOutOfOrderExecution: boolean;
}

export interface RouteRow {
  token: Address;
  destination: string;
  destinationLabel: string;
  enabled: boolean;
  rail: RailName;
  endpoint: Address;
  dstId: string;
}

export interface OftForTokenRow {
  token: Address;
  oft: Address;
}

export interface DstGasRow {
  destination: string;
  destinationLabel: string;
  gasLimit: bigint;
}

export interface InboundFeeRow {
  outboundToken: Address;
  destination: string;
  destinationLabel: string;
  fee: bigint;
}

export interface CollectedFeeRow {
  token: Address;
  amount: bigint;
  symbol?: string;
  decimals?: number;
}

export interface FailedTokenAmount {
  token: Address;
  amount: bigint;
}

export interface FailedMessage {
  guid: Hex;
  channel: Channel;
  srcId: string;
  srcLabel: string;
  sender: Hex;
  tokens: FailedTokenAmount[];
  reason: Hex;
  reasonDecoded?: string;
  /** Decoded from the captured VaultMessage — gates handler-only recovery. */
  failedMessageHandler: Address;
  /** Decoded from the captured VaultMessage — when true, permissionless `refundToSource` is disabled. */
  onlyLocalRefund: boolean;
  /**
   * The captured `Inbound`, reconstructed from `MessageFailed.message`. The adapter stores only its hash,
   * so every recovery call (`refundToSource` / `retryFailedMessage` / `refundLocal`) must pass it back.
   */
  inbound: DecodedInbound | null;
  destination?: string;
  recipient?: Hex;
  minAmountOut?: bigint;
  lzOft?: Address;
  isFailed: boolean;
  isRefunded: boolean;
  blockNumber?: bigint;
  txHash?: Hex;
}

export interface ActivityItem {
  kind: string;
  guid?: Hex;
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
    ccipRouter: Address;
    lzEndpoint: Address;
    explorerUrl: string;
  };
  policy: { requireLzReturnPrefunded: boolean };
  roles: {
    admins: Address[];
    feeSetters: Address[];
    feeCollectors: Address[];
    feeSetterRole: Hex;
    feeCollectorRole: Hex;
  };
  vault: VaultInfo | null;
  allowlists: AllowlistEntry[];
  svmLanes: SvmLane[];
  routes: RouteRow[];
  oftForToken: OftForTokenRow[];
  dstGas: DstGasRow[];
  inboundFees: InboundFeeRow[];
  collectedFees: CollectedFeeRow[];
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
  } catch {
    throw new Error(
      `Could not read typeAndVersion at ${adapter} on ${chain.name}. ` +
        `Confirm the address is a CrossChainVaultAdapter on the selected network.`,
    );
  }
  if (!SUPPORTED_TYPE_AND_VERSION.test(typeAndVersion)) {
    throw new Error(
      `Address is not a CrossChainVaultAdapter ` +
        `(typeAndVersion = "${typeAndVersion}").`,
    );
  }
  return { adapter, hubChainId, chain, client, typeAndVersion };
}

// ----------------------------------------------------------------------------
// Chunked log scanning (with localStorage caching)
// ----------------------------------------------------------------------------

const DEFAULT_CHUNK = 9_000n;
const DEFAULT_LOOKBACK = 4_000_000n;

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
    localStorage.setItem(cacheKey(chainId, adapter), JSON.stringify({ fromBlock: fromBlock.toString() }));
  } catch {
    /* ignore quota errors */
  }
}

/** Robust getLogs across RPCs that cap block ranges (single wide query, then chunked fallback). */
export async function scanLogs(
  client: PublicClient,
  address: Address,
  events: AbiEvent[],
  opts: { fromBlock?: bigint; toBlock?: bigint } = {},
): Promise<{ logs: any[]; fromBlock: bigint; toBlock: bigint }> {
  const latest = opts.toBlock ?? (await client.getBlockNumber());
  const from = opts.fromBlock ?? (latest > DEFAULT_LOOKBACK ? latest - DEFAULT_LOOKBACK : 0n);

  try {
    const logs = await client.getLogs({ address, events, fromBlock: from, toBlock: latest });
    return { logs, fromBlock: from, toBlock: latest };
  } catch {
    /* fall through to chunked */
  }

  const all: any[] = [];
  let start = from;
  while (start <= latest) {
    const end = start + DEFAULT_CHUNK > latest ? latest : start + DEFAULT_CHUNK;
    try {
      const logs = await client.getLogs({ address, events, fromBlock: start, toBlock: end });
      all.push(...logs);
    } catch {
      const mid = start + (end - start) / 2n;
      if (mid > start) {
        try {
          all.push(...(await client.getLogs({ address, events, fromBlock: start, toBlock: mid })));
          all.push(...(await client.getLogs({ address, events, fromBlock: mid + 1n, toBlock: end })));
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
    client.readContract({ address, abi: ERC20_ABI, functionName: "name" }).catch(() => "Unknown"),
    client.readContract({ address, abi: ERC20_ABI, functionName: "symbol" }).catch(() => "???"),
    client.readContract({ address, abi: ERC20_ABI, functionName: "decimals" }).catch(() => 18),
  ]);
  return { address, name: name as string, symbol: symbol as string, decimals: Number(decimals) };
}

async function readVaultInfo(client: PublicClient, vault: Address, asset: Address): Promise<VaultInfo | null> {
  try {
    const [vName, vSymbol, vDecimals, totalAssets, totalSupply] = await Promise.all([
      client.readContract({ address: vault, abi: ERC4626_ABI, functionName: "name" }).catch(() => "Vault"),
      client.readContract({ address: vault, abi: ERC4626_ABI, functionName: "symbol" }).catch(() => "vSHARE"),
      client.readContract({ address: vault, abi: ERC4626_ABI, functionName: "decimals" }).catch(() => 18),
      client.readContract({ address: vault, abi: ERC4626_ABI, functionName: "totalAssets" }).catch(() => 0n),
      client.readContract({ address: vault, abi: ERC4626_ABI, functionName: "totalSupply" }).catch(() => 0n),
    ]);
    const underlying = await readTokenMeta(client, asset);
    const oneShare = 10n ** BigInt(Number(vDecimals));
    const exchangeRate = (await client
      .readContract({ address: vault, abi: ERC4626_ABI, functionName: "convertToAssets", args: [oneShare] })
      .catch(() => undefined)) as bigint | undefined;
    return {
      vault,
      asset,
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

/** The base `Inbound` struct as ABI params, to decode `MessageFailed.message`. */
const INBOUND_PARAMS = [
  {
    type: "tuple",
    components: [
      { name: "channel", type: "uint8" },
      { name: "srcId", type: "uint64" },
      { name: "sender", type: "bytes32" },
      { name: "guid", type: "bytes32" },
      {
        name: "tokens",
        type: "tuple[]",
        components: [
          { name: "token", type: "address" },
          { name: "amount", type: "uint256" },
        ],
      },
      { name: "data", type: "bytes" },
      { name: "lzOft", type: "address" },
    ],
  },
] as const;

export interface DecodedInbound {
  channel: number;
  srcId: bigint;
  sender: Hex;
  guid: Hex;
  tokens: { token: Address; amount: bigint }[];
  data: Hex;
  lzOft: Address;
}

function decodeInbound(message: Hex): DecodedInbound | null {
  try {
    const [inb] = decodeAbiParameters(INBOUND_PARAMS as any, message) as unknown as [DecodedInbound];
    return inb;
  } catch {
    return null;
  }
}

/** Decode a captured revert `reason` into a readable custom-error name (best-effort). */
function decodeReason(reason: Hex): string | undefined {
  if (!reason || reason === "0x") return undefined;
  try {
    const err = decodeErrorResult({ abi: ADAPTER_ABI, data: reason });
    const args = (err.args ?? []).map((a) => (typeof a === "bigint" ? a.toString() : String(a)));
    return args.length ? `${err.errorName}(${args.join(", ")})` : err.errorName;
  } catch {
    return undefined;
  }
}

/** Human label for a `destination` route key (0 = local, LZ EID, or CCIP selector). */
function destinationLabel(destination: string): string {
  if (destination === "0") return "Local (hub)";
  const asNum = Number(destination);
  if (asNum > 0 && asNum <= 0xffffffff) {
    const lz = lzChainByEid(asNum);
    return lz ? `${lz.label} (LZ ${asNum})` : `LZ EID ${asNum}`;
  }
  const desc = describeSelector(destination);
  return desc.family === "UNKNOWN" ? `Selector ${destination}` : `${desc.label} (CCIP)`;
}

function selectorLabel(id: string): { label: string; family: "EVM" | "SVM" | "UNKNOWN" } {
  const desc = describeSelector(id);
  return { label: desc.label, family: desc.family };
}

function eidLabel(id: string): { label: string; family: "EVM" | "SVM" | "UNKNOWN" } {
  const lz = lzChainByEid(Number(id));
  return { label: lz ? lz.label : `EID ${id}`, family: "EVM" };
}

// ----------------------------------------------------------------------------
// Top-level loader
// ----------------------------------------------------------------------------

/** All adapter events, used for the single scan pass. */
const ALL_EVENTS = (ADAPTER_ABI as readonly any[]).filter((x) => x.type === "event") as AbiEvent[];

/** Events surfaced in the activity feed. */
const ACTIVITY_KINDS = new Set([
  "TokensReceived",
  "SentViaCcip",
  "SentViaOft",
  "SentViaStargate",
  "MessageProcessed",
  "MessageFailed",
  "MessageRecovered",
  "MessageRefunded",
  "DeliveredValueRefunded",
  "VaultDelivered",
  "InboundFeeCollected",
  "CollectedFeeWithdrawn",
  "NativeRecovered",
]);

export async function readAdapterState(ctx: AdapterContext): Promise<AdapterState> {
  const { client, adapter, chain } = ctx;

  // 1. Scalars + role ids + fixed vault
  const [
    typeAndVersion,
    ccipRouter,
    lzEndpoint,
    vaultAddr,
    assetAddr,
    requireLzReturnPrefunded,
    feeSetterRole,
    feeCollectorRole,
  ] = await Promise.all([
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "typeAndVersion" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_ccipRouter" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_lzEndpoint" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_vault" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_asset" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_requireLzReturnPrefunded" }).catch(() => false),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "FEE_SETTER_ROLE" }),
    client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "FEE_COLLECTOR_ROLE" }),
  ]);

  const vault = await readVaultInfo(client, getAddress(vaultAddr as Address), getAddress(assetAddr as Address));

  // 2. Single event scan pass
  const cachedFrom = getCachedDeployBlock(chain.id, adapter);
  const { logs, fromBlock, toBlock } = await scanLogs(client, adapter, ALL_EVENTS, { fromBlock: cachedFrom });
  rememberScan(chain.id, adapter, fromBlock);
  const byName = (name: string) => logs.filter((l) => l.eventName === name);

  // 3. Roles — replay RoleGranted/RoleRevoked in log order, verify survivors with hasRole
  const roleEvents = logs
    .filter((l) => l.eventName === "RoleGranted" || l.eventName === "RoleRevoked")
    .sort((a, b) =>
      a.blockNumber === b.blockNumber
        ? Number(a.logIndex) - Number(b.logIndex)
        : a.blockNumber > b.blockNumber
          ? 1
          : -1,
    );
  const roleCandidates = new Map<string, Set<string>>();
  for (const l of roleEvents) {
    const role = (l.args.role as string).toLowerCase();
    const account = getAddress(l.args.account as Address);
    if (!roleCandidates.has(role)) roleCandidates.set(role, new Set());
    const set = roleCandidates.get(role)!;
    if (l.eventName === "RoleGranted") set.add(account);
    else set.delete(account);
  }
  const verifyRole = async (role: Hex): Promise<Address[]> => {
    const candidates = [...(roleCandidates.get(role.toLowerCase()) ?? new Set<string>())];
    const checked = await Promise.all(
      candidates.map(async (acct) => {
        const ok = (await client
          .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "hasRole", args: [role, acct as Address] })
          .catch(() => false)) as boolean;
        return ok ? (acct as Address) : null;
      }),
    );
    return checked.filter((a): a is Address => a !== null);
  };
  const [admins, feeSetters, feeCollectors] = await Promise.all([
    verifyRole(DEFAULT_ADMIN_ROLE),
    verifyRole(feeSetterRole as Hex),
    verifyRole(feeCollectorRole as Hex),
  ]);

  // 4. Allowlists — candidate keys from *Set events, verified by getter
  const allowlists: AllowlistEntry[] = [];

  const ccipSrc = new Set<string>();
  for (const l of byName("CcipSourceSet")) ccipSrc.add((l.args.srcSelector as bigint).toString());
  const ccipDst = new Set<string>();
  for (const l of byName("CcipDestSet")) ccipDst.add((l.args.dstSelector as bigint).toString());
  const lzDst = new Set<string>();
  for (const l of byName("LzDestSet")) lzDst.add((l.args.dstEid as number).toString());
  const stargateDst = new Set<string>();
  for (const l of byName("StargateDestSet")) stargateDst.add((l.args.dstEid as number).toString());
  const lzOft = new Map<string, { eid: string; oft: Address }>();
  for (const l of byName("LzOftSet")) {
    const eid = (l.args.srcEid as number).toString();
    const oft = getAddress(l.args.oft as Address);
    lzOft.set(`${eid}:${oft}`, { eid, oft });
  }

  await Promise.all([
    ...[...ccipSrc].map(async (id) => {
      const allowed = (await client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_ccipSourceAllowed", args: [BigInt(id)] }).catch(() => false)) as boolean;
      const { label, family } = selectorLabel(id);
      allowlists.push({ kind: "ccipSrc", id, allowed, label, family });
    }),
    ...[...ccipDst].map(async (id) => {
      const allowed = (await client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_ccipDestAllowed", args: [BigInt(id)] }).catch(() => false)) as boolean;
      const { label, family } = selectorLabel(id);
      allowlists.push({ kind: "ccipDst", id, allowed, label, family });
    }),
    ...[...lzDst].map(async (id) => {
      const allowed = (await client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_lzDestAllowed", args: [Number(id)] }).catch(() => false)) as boolean;
      const { label, family } = eidLabel(id);
      allowlists.push({ kind: "lzDst", id, allowed, label, family });
    }),
    ...[...stargateDst].map(async (id) => {
      const allowed = (await client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_stargateDestAllowed", args: [Number(id)] }).catch(() => false)) as boolean;
      const { label, family } = eidLabel(id);
      allowlists.push({ kind: "stargateDst", id, allowed, label, family });
    }),
    ...[...lzOft.values()].map(async ({ eid, oft }) => {
      const allowed = (await client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_lzOftAllowed", args: [Number(eid), oft] }).catch(() => false)) as boolean;
      const { label, family } = eidLabel(eid);
      allowlists.push({ kind: "lzOft", id: eid, oft, allowed, label, family });
    }),
  ]);

  // 5. SVM lanes (from CcipSvmConfigSet)
  const svmSelectors = new Set<string>();
  for (const l of byName("CcipSvmConfigSet")) svmSelectors.add((l.args.selector as bigint).toString());
  const svmLanes: SvmLane[] = await Promise.all(
    [...svmSelectors].map(async (selector) => {
      const r = (await client
        .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_ccipSvm", args: [BigInt(selector)] })
        .catch(() => [false, 0, false])) as readonly [boolean, number, boolean];
      return {
        selector,
        label: selectorLabel(selector).label,
        enabled: r[0],
        computeUnits: Number(r[1]),
        allowOutOfOrderExecution: r[2],
      };
    }),
  );

  // 6. Routes (from RouteSet)
  const routeKeys = new Map<string, { token: Address; destination: string }>();
  for (const l of byName("RouteSet")) {
    const token = getAddress(l.args.token as Address);
    const destination = (l.args.destination as bigint).toString();
    routeKeys.set(`${token}:${destination}`, { token, destination });
  }
  const routes: RouteRow[] = await Promise.all(
    [...routeKeys.values()].map(async ({ token, destination }) => {
      const r = (await client
        .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_route", args: [token, BigInt(destination)] })
        .catch(() => [false, 0, "0x0000000000000000000000000000000000000000", 0n])) as readonly [boolean, number, Address, bigint];
      return {
        token,
        destination,
        destinationLabel: destinationLabel(destination),
        enabled: r[0],
        rail: RAIL[Number(r[1])] ?? "LZ_OFT",
        endpoint: getAddress(r[2]),
        dstId: (r[3] as bigint).toString(),
      };
    }),
  );

  // 7. OFT-for-token (from OftForTokenSet)
  const oftTokens = new Set<string>();
  for (const l of byName("OftForTokenSet")) oftTokens.add(getAddress(l.args.token as Address));
  const oftForToken: OftForTokenRow[] = (
    await Promise.all(
      [...oftTokens].map(async (token) => {
        const oft = (await client
          .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_oftForToken", args: [token as Address] })
          .catch(() => "0x0000000000000000000000000000000000000000")) as Address;
        return oft === "0x0000000000000000000000000000000000000000"
          ? null
          : { token: token as Address, oft: getAddress(oft) };
      }),
    )
  ).filter((r): r is OftForTokenRow => r !== null);

  // 8. Destination gas (from DestinationGasSet)
  const gasKeys = new Set<string>();
  for (const l of byName("DestinationGasSet")) gasKeys.add((l.args.destination as bigint).toString());
  const dstGas: DstGasRow[] = (
    await Promise.all(
      [...gasKeys].map(async (destination) => {
        const gasLimit = (await client
          .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_dstGas", args: [BigInt(destination)] })
          .catch(() => 0n)) as bigint;
        return gasLimit === 0n
          ? null
          : { destination, destinationLabel: destinationLabel(destination), gasLimit };
      }),
    )
  ).filter((r): r is DstGasRow => r !== null);

  // 9. Inbound fees (from InboundFeeSet)
  const feeKeys = new Map<string, { outboundToken: Address; destination: string }>();
  for (const l of byName("InboundFeeSet")) {
    const outboundToken = getAddress(l.args.outboundToken as Address);
    const destination = (l.args.destination as bigint).toString();
    feeKeys.set(`${outboundToken}:${destination}`, { outboundToken, destination });
  }
  const inboundFees: InboundFeeRow[] = await Promise.all(
    [...feeKeys.values()].map(async ({ outboundToken, destination }) => {
      const fee = (await client
        .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_inboundFees", args: [outboundToken, BigInt(destination)] })
        .catch(() => 0n)) as bigint;
      return { outboundToken, destination, destinationLabel: destinationLabel(destination), fee };
    }),
  );

  // 10. Collected fees (union of asset, share, inbound-fee tokens, withdrawn tokens)
  const feeTokens = new Set<string>();
  if (vault) {
    feeTokens.add(getAddress(vault.asset));
    feeTokens.add(getAddress(vault.vault));
  }
  for (const l of byName("InboundFeeCollected")) feeTokens.add(getAddress(l.args.inboundToken as Address));
  for (const l of byName("CollectedFeeWithdrawn")) feeTokens.add(getAddress(l.args.token as Address));
  const collectedFees: CollectedFeeRow[] = (
    await Promise.all(
      [...feeTokens].map(async (token): Promise<CollectedFeeRow | null> => {
        const amount = (await client
          .readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "s_collectedFees", args: [token as Address] })
          .catch(() => 0n)) as bigint;
        if (amount === 0n) return null;
        const meta =
          vault && getAddress(vault.asset) === token
            ? { symbol: vault.underlying.symbol, decimals: vault.underlying.decimals }
            : vault && getAddress(vault.vault) === token
              ? { symbol: vault.share.symbol, decimals: vault.share.decimals }
              : undefined;
        return { token: token as Address, amount, symbol: meta?.symbol, decimals: meta?.decimals };
      }),
    )
  ).filter((x): x is CollectedFeeRow => x !== null);

  // 11. Failed messages (from MessageFailed; decode Inbound + VaultMessage from the log)
  const failedByGuid = new Map<string, any>();
  for (const l of byName("MessageFailed")) failedByGuid.set(l.args.guid as string, l); // latest wins
  const failedMessages: FailedMessage[] = (
    await Promise.all(
      [...failedByGuid.entries()].map(async ([guid, log]): Promise<FailedMessage | null> => {
        const [isFailed, isRefunded] = await Promise.all([
          client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "isFailed", args: [guid as Hex] }).catch(() => false) as Promise<boolean>,
          client.readContract({ address: adapter, abi: ADAPTER_ABI, functionName: "isRefunded", args: [guid as Hex] }).catch(() => false) as Promise<boolean>,
        ]);
        const inb = decodeInbound(log.args.message as Hex);
        const vm = inb ? decodeVaultMessage(inb.data) : null;
        const channelNum = Number(log.args.channel ?? inb?.channel ?? 0);
        const srcId = (inb?.srcId ?? 0n).toString();
        return {
          guid: guid as Hex,
          channel: CHANNEL[channelNum] ?? "CCIP",
          srcId,
          srcLabel: channelNum === 1 ? eidLabel(srcId).label : selectorLabel(srcId).label,
          sender: (inb?.sender as Hex) ?? "0x",
          tokens: inb?.tokens ?? [],
          reason: (log.args.reason as Hex) ?? "0x",
          reasonDecoded: decodeReason((log.args.reason as Hex) ?? "0x"),
          failedMessageHandler: (vm?.failedMessageHandler as Address) ?? "0x0000000000000000000000000000000000000000",
          onlyLocalRefund: vm?.onlyLocalRefund ?? false,
          inbound: inb,
          destination: vm ? vm.destination.toString() : undefined,
          recipient: vm?.recipient,
          minAmountOut: vm?.minAmountOut,
          lzOft: inb?.lzOft,
          isFailed,
          isRefunded,
          blockNumber: log.blockNumber as bigint,
          txHash: log.transactionHash as Hex,
        };
      }),
    )
  ).filter((m): m is FailedMessage => m !== null);

  // 12. Activity feed (most recent first)
  const activity: ActivityItem[] = logs
    .filter((l) => ACTIVITY_KINDS.has(l.eventName))
    .map((l) => ({
      kind: l.eventName as string,
      guid: (l.args?.guid as Hex) ?? (l.args?.messageId as Hex) ?? undefined,
      blockNumber: l.blockNumber as bigint,
      txHash: l.transactionHash as Hex,
      logIndex: Number(l.logIndex ?? 0),
      args: serializeArgs(l.args ?? {}),
    }))
    .sort((a, b) =>
      a.blockNumber === b.blockNumber ? b.logIndex - a.logIndex : a.blockNumber > b.blockNumber ? -1 : 1,
    );

  return {
    meta: {
      adapter,
      hubChainId: chain.id,
      hubChainName: chain.name,
      typeAndVersion: typeAndVersion as string,
      ccipRouter: getAddress(ccipRouter as Address),
      lzEndpoint: getAddress(lzEndpoint as Address),
      explorerUrl: chain.explorerUrl,
    },
    policy: { requireLzReturnPrefunded: requireLzReturnPrefunded as boolean },
    roles: {
      admins,
      feeSetters,
      feeCollectors,
      feeSetterRole: feeSetterRole as Hex,
      feeCollectorRole: feeCollectorRole as Hex,
    },
    vault,
    allowlists,
    svmLanes,
    routes,
    oftForToken,
    dstGas,
    inboundFees,
    collectedFees,
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
