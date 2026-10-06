import path from "node:path";

import dotenv from "dotenv";

import {
  type CCIPRequest,
  type NetworkInfo,
  EVMChain,
  estimateReceiveExecution,
  networkInfo
} from "@chainlink/ccip-sdk";
import { PublicKey } from "@solana/web3.js";
import {
  AbiCoder,
  Contract,
  Interface,
  Wallet,
  formatUnits,
  getAddress,
  getBytes,
  hexlify,
  isAddress,
  isHexString,
  parseUnits,
  solidityPacked,
  ZeroAddress,
  zeroPadValue
} from "ethers";

import { ADAPTER_ABI, ADAPTER_ERROR_CODE, CCIP_ROUTER_MIN_ABI, ERC20_ABI } from "./abis";
import { ccipExplorerUrl } from "./report";

/** `.env` always lives next to this file (`e2e/ccip/.env`), regardless of the working directory. */
export const ENV_FILE = path.resolve(__dirname, ".env");
dotenv.config({ path: ENV_FILE, override: true, quiet: true });

const abiCoder = AbiCoder.defaultAbiCoder();
const DEFAULT_SOURCE_CHAIN = "avalanche-testnet-fuji";
const DEFAULT_DEST_CHAIN = "ethereum-testnet-sepolia";
const INVALID_TARGET = "0x0000000000000000000000000000000000000001";

/** Tag + layout must match on-chain `ExtraArgsCodec._getBasicEncodedExtraArgsV3` (NOT ccip-sdk `encodeExtraArgs` V3, which uses a different binary shape). */
const GENERIC_EXTRA_ARGS_V3_TAG = "0xa69dd4aa";

// ---------------------------------------------------------------------------
// Configuration errors and script entrypoint
// ---------------------------------------------------------------------------

/** Thrown for missing or malformed configuration; printed without a stack trace by {@link runMain}. */
export class ConfigError extends Error {
  override name = "ConfigError";
}

/**
 * Standard script entrypoint: configuration problems print a one-line message naming the variable and exit 1;
 * anything else (RPC / contract errors) prints the full error for debugging.
 */
export function runMain(main: () => Promise<void>): void {
  main().catch((error: unknown) => {
    if (error instanceof ConfigError) {
      console.error(`configuration error: ${error.message}`);
      if (error.message.includes("env var")) {
        console.error("Copy e2e/ccip/.env.example to e2e/ccip/.env and fill it in; see e2e/ccip/README.md.");
      }
    } else {
      console.error(error);
    }
    process.exitCode = 1;
  });
}

/** Fail fast, listing every missing required variable at once. */
export function assertEnvPresent(required: readonly string[], context: string): void {
  const missing = required.filter((name) => !process.env[name]?.trim());
  if (missing.length > 0) {
    throw new ConfigError(`missing required env var(s) for ${context}: ${missing.join(", ")}`);
  }
}

/** Resolve a CCIP network by name / chain id / selector from an env var, with a clear error when unknown. */
export function resolveNetworkEnv(name: string, fallback: string): NetworkInfo {
  const value = process.env[name]?.trim() || fallback;
  try {
    return networkInfo(value);
  } catch {
    throw new ConfigError(`env var ${name}=${value} is not a network known to @chainlink/ccip-sdk (use a CCIP chain name, e.g. ${fallback})`);
  }
}

// ---------------------------------------------------------------------------
// EVM source -> EVM destination adapter runtime
// ---------------------------------------------------------------------------

export type Runtime = {
  source: EVMChain;
  dest: EVMChain;
  sourceWallet: Wallet;
  destWallet: Wallet;
  config: ReturnType<typeof loadConfig>;
};

export function loadConfig() {
  assertEnvPresent(
    [
      "E2E_SOURCE_RPC_URL",
      "E2E_DEST_RPC_URL",
      "E2E_PRIVATE_KEY",
      "E2E_SOURCE_ROUTER",
      "E2E_DEST_ADAPTER",
      "E2E_DEST_VAULT",
      "E2E_DEST_ASSET_TOKEN_ADDRESS",
      "E2E_SOURCE_USDC_TOKEN_ADDRESS"
    ],
    "EVM adapter scripts"
  );

  const sourceChain = resolveNetworkEnv("E2E_SOURCE_CHAIN", DEFAULT_SOURCE_CHAIN);
  const destChain = resolveNetworkEnv("E2E_DEST_CHAIN", DEFAULT_DEST_CHAIN);
  assertDistinctChains(sourceChain, destChain);
  assertFamily(sourceChain, "EVM", "E2E_SOURCE_CHAIN");
  assertFamily(destChain, "EVM", "E2E_DEST_CHAIN");

  return {
    sourceRpcUrl: requireEnv("E2E_SOURCE_RPC_URL"),
    destRpcUrl: requireEnv("E2E_DEST_RPC_URL"),
    privateKey: requirePrivateKeyEnv(),
    sourceRouter: requireAddressEnv("E2E_SOURCE_ROUTER"),
    destAdapter: requireDestAdapterAddress(),
    destVault: requireAddressEnv("E2E_DEST_VAULT"),
    destAssetToken: requireAddressEnv("E2E_DEST_ASSET_TOKEN_ADDRESS"),
    sourceUsdcToken: requireAddressEnv("E2E_SOURCE_USDC_TOKEN_ADDRESS"),
    sourceVaultToken: optionalAddressEnv("E2E_SOURCE_VAULT_TOKEN_ADDRESS"),
    sourceVaultTokenDecimals: optionalDecimalsEnv("E2E_SOURCE_VAULT_TOKEN_DECIMALS"),
    beneficiary: optionalAddressEnv("E2E_DEST_BENEFICIARY"),
    ccipGasLimitOverride: optionalIntegerEnv("E2E_CCIP_GAS_LIMIT"),
    ccipGasMultiplierBps: parseIntegerEnv("E2E_CCIP_GAS_MULTIPLIER_BPS", 12_000),
    refundFeeMultiplierBps: parseIntegerEnv("E2E_REFUND_FEE_MULTIPLIER_BPS", 12_000),
    pollMs: parseIntegerEnv("E2E_STATUS_POLL_MS", 15_000),
    timeoutMs: parseIntegerEnv("E2E_STATUS_TIMEOUT_MS", 30 * 60 * 1000),
    depositAmount: process.env.E2E_DEPOSIT_USDC_AMOUNT ?? ".1",
    depositMinimumOut: process.env.E2E_DEPOSIT_MINIMUM_OUT ?? "0",
    invalidDepositAmount: process.env.E2E_INVALID_DEPOSIT_USDC_AMOUNT ?? process.env.E2E_DEPOSIT_USDC_AMOUNT ?? "1",
    invalidDepositMinimumOut:
      process.env.E2E_INVALID_DEPOSIT_MINIMUM_OUT ?? process.env.E2E_DEPOSIT_MINIMUM_OUT ?? "1",
    redeemAmount: process.env.E2E_REDEEM_VAULT_AMOUNT ?? "1",
    redeemMinimumOut: process.env.E2E_REDEEM_MINIMUM_OUT ?? "0",
    returnToSourceChain: parseBooleanEnv("E2E_RETURN_TO_SOURCE_CHAIN", true),
    localRefundAddress: optionalAddressEnv("E2E_LOCAL_REFUND_ADDRESS"),
    /** When set, outbound EVM `ccipSend` uses Solidity-compatible GenericExtraArgsV3 with this `requestedFinality` bytes4. */
    outboundRequestedFinality: optionalFinalityBytes4Env("E2E_OUTBOUND_REQUESTED_FINALITY"),
    sourceChain,
    destChain
  };
}

export async function createRuntime(opts: { requireRedeemToken?: boolean } = {}): Promise<Runtime> {
  const config = loadConfig();
  if (opts.requireRedeemToken && !config.sourceVaultToken) {
    throw new ConfigError("missing required env var E2E_SOURCE_VAULT_TOKEN_ADDRESS for the redeem scenario");
  }
  const [source, dest] = await Promise.all([
    EVMChain.fromUrl(config.sourceRpcUrl),
    EVMChain.fromUrl(config.destRpcUrl)
  ]);

  const sourceWallet = createWallet(config.privateKey, source);
  const destWallet = createWallet(config.privateKey, dest);

  return {
    source,
    dest,
    sourceWallet,
    destWallet,
    config
  };
}

export async function destroyRuntime(runtime: { source: { destroy?(): unknown }; dest: { destroy?(): unknown } }): Promise<void> {
  await Promise.allSettled([runtime.source.destroy?.(), runtime.dest.destroy?.()]);
}

// ---------------------------------------------------------------------------
// Destination-only runtime (refund / local recovery of an existing message)
// ---------------------------------------------------------------------------

/** What the recovery helpers need: a destination chain, a signer on it and the adapter address. */
export type DestRuntime = {
  dest: EVMChain;
  destWallet: Wallet;
  config: {
    destAdapter: string;
    destChain: NetworkInfo;
    refundFeeMultiplierBps: number;
  };
};

export function loadDestConfig(): DestRuntime["config"] & { destRpcUrl: string; privateKey: string } {
  assertEnvPresent(["E2E_DEST_RPC_URL", "E2E_PRIVATE_KEY", "E2E_DEST_ADAPTER"], "refund / local recovery");
  return {
    destRpcUrl: requireEnv("E2E_DEST_RPC_URL"),
    privateKey: requirePrivateKeyEnv(),
    destAdapter: requireDestAdapterAddress(),
    destChain: resolveNetworkEnv("E2E_DEST_CHAIN", DEFAULT_DEST_CHAIN),
    refundFeeMultiplierBps: parseIntegerEnv("E2E_REFUND_FEE_MULTIPLIER_BPS", 12_000)
  };
}

export async function createDestRuntime(): Promise<DestRuntime & { destroy(): Promise<void> }> {
  const config = loadDestConfig();
  const dest = await EVMChain.fromUrl(config.destRpcUrl);
  return {
    dest,
    destWallet: createWallet(config.privateKey, dest),
    config,
    destroy: async () => {
      await Promise.allSettled([dest.destroy?.()]);
    }
  };
}

/**
 * Message id from the first CLI argument, falling back to `E2E_REFUND_MESSAGE_ID`.
 * Must be a 0x-prefixed bytes32.
 */
export function getMessageIdArg(scriptName: string): string {
  const messageId = process.argv[2]?.trim() || process.env.E2E_REFUND_MESSAGE_ID?.trim();
  if (!messageId) {
    throw new ConfigError(
      `missing message id: run \`pnpm e2e:ccip ${scriptName} <message-id>\` or set E2E_REFUND_MESSAGE_ID`
    );
  }
  if (!isHexString(messageId, 32)) {
    throw new ConfigError(`message id must be a 0x-prefixed 32-byte hex string, got ${messageId}`);
  }
  return messageId;
}

// ---------------------------------------------------------------------------
// Token helpers
// ---------------------------------------------------------------------------

export async function getTokenMetadata(
  chain: { getTokenInfo(token: string): Promise<{ symbol: string; decimals: number }> },
  tokenAddress: string
): Promise<{ symbol: string; decimals: number }> {
  const tokenInfo = await chain.getTokenInfo(tokenAddress);
  return { symbol: tokenInfo.symbol, decimals: Number(tokenInfo.decimals) };
}

/** Read ERC-20 `decimals()` on-chain; CCIP bridged tokens may not support ccip-sdk `getTokenInfo`. */
export async function readErc20Decimals(chain: EVMChain, tokenAddress: string, override?: number): Promise<number> {
  if (override !== undefined) {
    return override;
  }

  const token = new Contract(tokenAddress, ERC20_ABI, chain.provider as never);
  return Number(await token.decimals());
}

export async function parseEvmTokenAmount(
  chain: EVMChain,
  tokenAddress: string,
  humanAmount: string,
  decimalsOverride?: number
): Promise<bigint> {
  const decimals = await readErc20Decimals(chain, tokenAddress, decimalsOverride);
  return parseUnits(humanAmount, decimals);
}

export async function getTokenBalance(chain: EVMChain, tokenAddress: string, account: string): Promise<bigint> {
  const token = new Contract(tokenAddress, ERC20_ABI, chain.provider as never);
  return BigInt(await token.balanceOf(account));
}

export async function parseTokenAmount(
  chain: { getTokenInfo(token: string): Promise<{ symbol: string; decimals: number }> },
  tokenAddress: string,
  humanAmount: string
): Promise<bigint> {
  const { decimals } = await getTokenMetadata(chain, tokenAddress);
  return parseUnits(humanAmount, decimals);
}

// ---------------------------------------------------------------------------
// Adapter payload (`CrossChainERC4626Adapter.Payload`, 128 bytes)
// ---------------------------------------------------------------------------

/**
 * `deliveryAndRefund` as decoded by the adapter's `_unpackDeliveryAndRefund`:
 * bit 0 = `returnToSourceChain`, bits 1..160 = `localRefundAddress` (zero disables local recovery).
 */
export function packDeliveryAndRefund(returnToSourceChain: boolean, localRefundAddress?: string): bigint {
  const refund = localRefundAddress ? BigInt(getAddress(localRefundAddress)) : 0n;
  if (refund >= 1n << 160n) {
    throw new Error("localRefundAddress must fit in 160 bits");
  }
  return (refund << 1n) | (returnToSourceChain ? 1n : 0n);
}

export function unpackDeliveryAndRefund(deliveryAndRefund: bigint): {
  returnToSourceChain: boolean;
  localRefundAddress: string;
} {
  const returnToSourceChain = (deliveryAndRefund & 1n) !== 0n;
  const localRefundAddress = getAddress(
    `0x${((deliveryAndRefund >> 1n) & ((1n << 160n) - 1n)).toString(16).padStart(40, "0")}`
  );
  return { returnToSourceChain, localRefundAddress };
}

export type PayloadOptions = {
  target: string;
  beneficiary: string;
  beneficiaryType?: "evm" | "svm";
  minimumOut?: bigint;
  returnToSourceChain?: boolean;
  localRefundAddress?: string;
};

/**
 * `abi.encode(address target, bytes32 beneficiary, uint256 minimumOut, uint256 deliveryAndRefund)`, the adapter
 * `Payload` struct (exactly `CCIP_MESSAGE_PAYLOAD_LENGTH` = 128 bytes). Used for both EVM and SVM sources.
 */
export function encodePayload(opts: PayloadOptions): string {
  const returnToSourceChain = opts.returnToSourceChain ?? false;
  if (!returnToSourceChain && opts.beneficiaryType === "svm") {
    // Local delivery requires a canonical EVM address in `beneficiary` (adapter reverts InvalidEVMAddress otherwise).
    throw new Error("local delivery (returnToSourceChain=false) requires an EVM beneficiary on the destination chain");
  }
  const encoded = abiCoder.encode(
    ["address", "bytes32", "uint256", "uint256"],
    [
      getAddress(opts.target),
      encodeBeneficiary(opts.beneficiary, opts.beneficiaryType),
      opts.minimumOut ?? 1n,
      packDeliveryAndRefund(returnToSourceChain, opts.localRefundAddress)
    ]
  );
  if (getBytes(encoded).length !== 128) {
    throw new Error(`encoded payload must be 128 bytes, got ${getBytes(encoded).length}`);
  }
  return encoded;
}

/** Same as `encodePayload` (128-byte `message.data` for both EVM and SVM sources). */
export function encodeSvmPayload(opts: PayloadOptions): string {
  return encodePayload(opts);
}

export function invalidTargetAddress(): string {
  return INVALID_TARGET;
}

/**
 * Solidity `ExtraArgsCodec._getBasicEncodedExtraArgsV3(gasLimit, requestedFinalityBytes4)` —
 * GenericExtraArgsV3 with empty CCVs / executor / token receiver / token args tails.
 */
export function encodeSolidityBasicGenericExtraArgsV3(gasLimit: number, requestedFinalityHex: `0x${string}`): string {
  if (!Number.isInteger(gasLimit) || gasLimit < 0 || gasLimit > 0xffffffff) {
    throw new Error(`gasLimit must fit uint32, got ${gasLimit}`);
  }
  const fin = getBytes(requestedFinalityHex);
  if (fin.length !== 4) {
    throw new Error(`requestedFinality must be exactly 4 bytes, got ${fin.length}`);
  }

  return solidityPacked(
    ["bytes4", "uint32", "bytes4", "bytes7"],
    [GENERIC_EXTRA_ARGS_V3_TAG, gasLimit, hexlify(fin), "0x00000000000000"]
  );
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/**
 * Same chain pair / router / adapter wiring as {@link sendMessageWithToken}, but uses an explicit destination
 * execution `gasLimit` on the outbound CCIP message (from {@link resolveCcipGasLimit}).
 */
async function deliverSendMessageWithToken(
  runtime: Runtime,
  params: {
    sourceToken: string;
    amount: bigint;
    data: string;
  },
  destinationExecutionGasLimit: number
): Promise<CCIPRequest> {
  if (!Number.isInteger(destinationExecutionGasLimit) || destinationExecutionGasLimit < 0 || destinationExecutionGasLimit > 0xffffffff) {
    throw new Error(`destinationExecutionGasLimit must be a uint32, got ${destinationExecutionGasLimit}`);
  }

  if (runtime.config.outboundRequestedFinality) {
    return sendMessageWithTokenSolidityFinality(
      runtime,
      params,
      destinationExecutionGasLimit,
      runtime.config.outboundRequestedFinality
    );
  }

  const request = await runtime.source.sendMessage({
    router: runtime.config.sourceRouter,
    destChainSelector: runtime.config.destChain.chainSelector,
    wallet: runtime.sourceWallet,
    message: {
      receiver: runtime.config.destAdapter,
      data: params.data,
      tokenAmounts: [
        {
          token: params.sourceToken,
          amount: params.amount
        }
      ],
      extraArgs: {
        gasLimit: BigInt(destinationExecutionGasLimit),
        allowOutOfOrderExecution: true
      }
    }
  });

  assertSingleTokenTransfer(request);
  return request;
}

export async function sendMessageWithToken(
  runtime: Runtime,
  params: {
    sourceToken: string;
    amount: bigint;
    data: string;
  }
) {
  const gasLimit = await resolveCcipGasLimit(runtime, params);
  console.log(`sending token ${params.sourceToken} amount ${params.amount.toString()} with gasLimit ${gasLimit}`);

  return deliverSendMessageWithToken(runtime, params, gasLimit);
}

/** Print the send result and where to track it. */
export function logSentMessage(request: CCIPRequest): void {
  console.log(`send tx hash: ${request.tx.hash}`);
  console.log(`message id: ${request.message.messageId}`);
  console.log(`track: ${ccipExplorerUrl(request.message.messageId)}`);
}

/** Config for **`createBridgeVaultRuntime`**: bare CCIP tokens-only bridge (no adapter `data`). */
export type BridgeVaultOnlyConfig = {
  sourceRpcUrl: string;
  destRpcUrl: string;
  sourceRouter: string;
  sourceVaultToken: string;
  beneficiary: string;
  bridgeAmountHuman: string;
  outboundRequestedFinality: `0x${string}` | undefined;
  sourceChain: NetworkInfo;
  destChain: NetworkInfo;
};

export type BridgeVaultRuntime = {
  source: EVMChain;
  dest: EVMChain;
  sourceWallet: Wallet;
  config: BridgeVaultOnlyConfig;
};

export function loadBridgeVaultOnlyConfig(): BridgeVaultOnlyConfig {
  assertEnvPresent(
    [
      "E2E_SOURCE_RPC_URL",
      "E2E_DEST_RPC_URL",
      "E2E_PRIVATE_KEY",
      "E2E_SOURCE_ROUTER",
      "E2E_SOURCE_VAULT_TOKEN_ADDRESS",
      "E2E_DEST_BENEFICIARY"
    ],
    "bridge-vault"
  );

  const sourceChain = resolveNetworkEnv("E2E_SOURCE_CHAIN", DEFAULT_SOURCE_CHAIN);
  const destChain = resolveNetworkEnv("E2E_DEST_CHAIN", DEFAULT_DEST_CHAIN);
  assertDistinctChains(sourceChain, destChain);
  assertFamily(sourceChain, "EVM", "E2E_SOURCE_CHAIN");
  assertFamily(destChain, "EVM", "E2E_DEST_CHAIN");

  return {
    sourceRpcUrl: requireEnv("E2E_SOURCE_RPC_URL"),
    destRpcUrl: requireEnv("E2E_DEST_RPC_URL"),
    sourceRouter: requireAddressEnv("E2E_SOURCE_ROUTER"),
    sourceVaultToken: requireAddressEnv("E2E_SOURCE_VAULT_TOKEN_ADDRESS"),
    beneficiary: requireAddressEnv("E2E_DEST_BENEFICIARY"),
    bridgeAmountHuman: process.env.E2E_BRIDGE_VAULT_AMOUNT ?? process.env.E2E_REDEEM_VAULT_AMOUNT ?? "1",
    outboundRequestedFinality: optionalFinalityBytes4Env("E2E_OUTBOUND_REQUESTED_FINALITY"),
    sourceChain,
    destChain
  };
}

export async function createBridgeVaultRuntime(): Promise<BridgeVaultRuntime> {
  const config = loadBridgeVaultOnlyConfig();
  const privateKey = requirePrivateKeyEnv();
  // Validate the destination gas limit before touching the network.
  bridgeDestinationExecutionGasLimitFromEnv();
  const [source, dest] = await Promise.all([EVMChain.fromUrl(config.sourceRpcUrl), EVMChain.fromUrl(config.destRpcUrl)]);
  const sourceWallet = createWallet(privateKey, source);
  return { source, dest, sourceWallet, config };
}

export async function destroyBridgeVaultRuntime(runtime: BridgeVaultRuntime): Promise<void> {
  await destroyRuntime(runtime);
}

/**
 * CCIP bridge: one token transfer to **`E2E_DEST_BENEFICIARY`** on **`E2E_DEST_CHAIN`**, **`data` empty** (no adapter / no custom payload).
 * Destination execution `gasLimit` defaults to **0** (`E2E_BRIDGE_CCIP_GAS_LIMIT` to override).
 */
export async function bridgeVaultTokensOnlyToBeneficiary(
  runtime: BridgeVaultRuntime,
  amount: bigint,
  destinationExecutionGasLimit?: number,
  manualNativeFee?: bigint
): Promise<CCIPRequest> {
  const gasLimit =
    destinationExecutionGasLimit !== undefined
      ? destinationExecutionGasLimit
      : bridgeDestinationExecutionGasLimitFromEnv();

  if (!Number.isInteger(gasLimit) || gasLimit < 0 || gasLimit > 0xffffffff) {
    throw new Error(`destinationExecutionGasLimit must be a uint32, got ${gasLimit}`);
  }

  const receiver = zeroPadValue(getAddress(runtime.config.beneficiary), 32);
  const data = "0x";
  const sourceToken = runtime.config.sourceVaultToken;

  console.log(
    `bridge tokens-only: token ${sourceToken} amount ${amount.toString()} -> beneficiary ${runtime.config.beneficiary} (${receiver}) destinationExecutionGasLimit ${gasLimit} data empty`
  );

  if (runtime.config.outboundRequestedFinality) {
    return ccipRouterSolidityFinalitySend({
      source: runtime.source,
      sourceWallet: runtime.sourceWallet,
      sourceRouter: runtime.config.sourceRouter,
      destChainSelector: runtime.config.destChain.chainSelector,
      receiver,
      data,
      sourceToken,
      amount,
      gasLimit,
      requestedFinalityHex: runtime.config.outboundRequestedFinality,
      manualNativeFee
    });
  }

  const request = await runtime.source.sendMessage({
    router: runtime.config.sourceRouter,
    destChainSelector: runtime.config.destChain.chainSelector,
    wallet: runtime.sourceWallet,
    message: {
      receiver,
      data,
      tokenAmounts: [{ token: sourceToken, amount }],
      extraArgs: {
        gasLimit: BigInt(gasLimit),
        allowOutOfOrderExecution: true
      }
    }
  });

  assertSingleTokenTransfer(request);
  return request;
}

/**
 * When `E2E_OUTBOUND_REQUESTED_FINALITY` is set we cannot use `@chainlink/ccip-sdk` `sendMessage` alone: its V3
 * `encodeExtraArgs` wire format does not match on-chain `ExtraArgsCodec` (bytes4 finality + 7-byte static tail).
 * This path calls `Router.ccipSend` / `getFee` with Solidity-compatible `extraArgs` bytes.
 */
async function sendMessageWithTokenSolidityFinality(
  runtime: Runtime,
  params: { sourceToken: string; amount: bigint; data: string },
  gasLimit: number,
  requestedFinalityHex: `0x${string}`
): Promise<CCIPRequest> {
  const receiver = zeroPadValue(getAddress(runtime.config.destAdapter), 32);
  const data = params.data.startsWith("0x") ? params.data : `0x${params.data}`;
  return ccipRouterSolidityFinalitySend({
    source: runtime.source,
    sourceWallet: runtime.sourceWallet,
    sourceRouter: runtime.config.sourceRouter,
    destChainSelector: runtime.config.destChain.chainSelector,
    receiver,
    data,
    sourceToken: params.sourceToken,
    amount: params.amount,
    gasLimit,
    requestedFinalityHex
  });
}

async function ccipRouterSolidityFinalitySend(opts: {
  source: EVMChain;
  sourceWallet: Wallet;
  sourceRouter: string;
  destChainSelector: bigint;
  receiver: string;
  data: string;
  sourceToken: string;
  amount: bigint;
  gasLimit: number;
  requestedFinalityHex: `0x${string}`;
  manualNativeFee?: bigint;
}): Promise<CCIPRequest> {
  const extraArgs = encodeSolidityBasicGenericExtraArgsV3(opts.gasLimit, opts.requestedFinalityHex);
  console.log(
    `using Solidity GenericExtraArgsV3 extraArgs (bytes4 finality ${opts.requestedFinalityHex}): ${extraArgs}`
  );

  const sender = await opts.sourceWallet.getAddress();

  const message = {
    receiver: opts.receiver,
    data: opts.data,
    tokenAmounts: [{ token: getAddress(opts.sourceToken), amount: opts.amount }],
    feeToken: ZeroAddress,
    extraArgs
  };

  const router = new Contract(opts.sourceRouter, CCIP_ROUTER_MIN_ABI, opts.sourceWallet);
  const fee =
    opts.manualNativeFee !== undefined
      ? (() => {
          if (opts.manualNativeFee < 0n) {
            throw new Error(`manualNativeFee must be nonnegative, got ${opts.manualNativeFee.toString()}`);
          }
          console.log(`skipping getFee; using manual native fee ${opts.manualNativeFee.toString()} wei`);
          return opts.manualNativeFee;
        })()
      : await router.getFee(opts.destChainSelector, message);

  const token = new Contract(opts.sourceToken, ERC20_ABI, opts.sourceWallet);
  const allowance = await token.allowance(sender, opts.sourceRouter);
  if (allowance < opts.amount) {
    const approveTx = await token.approve(opts.sourceRouter, opts.amount, {
      nonce: await opts.source.nextNonce(sender)
    });
    await approveTx.wait(1, 60_000);
  }

  const sendTx = await router.ccipSend(opts.destChainSelector, message, {
    value: fee,
    nonce: await opts.source.nextNonce(sender)
  });
  const receipt = await sendTx.wait(1, 60_000);
  if (!receipt) {
    throw new Error("ccipSend transaction produced no receipt");
  }

  const chainTx = await opts.source.getTransaction(receipt);
  const requests = await opts.source.getMessagesInTx(chainTx);
  if (requests.length < 1) {
    throw new Error("ccipSend confirmed but no CCIP message was parsed from transaction logs");
  }
  return requests[0]!;
}

function assertSingleTokenTransfer(request: CCIPRequest): void {
  const requestTokenAmounts = request.message.tokenAmounts ?? [];
  if (requestTokenAmounts.length !== 1) {
    throw new Error(
      `CCIP source tx was sent without exactly one token transfer; received tokenAmounts=${JSON.stringify(
        requestTokenAmounts,
        (_key, value) => typeof value === "bigint" ? value.toString() : value
      )}`
    );
  }
}

// ---------------------------------------------------------------------------
// Tracking
// ---------------------------------------------------------------------------

/** Anything that can look a message up through the CCIP API and knows the polling settings. */
export type StatusPoller = {
  source: { getMessageById(messageId: string): Promise<CCIPRequest> };
  config: { pollMs: number; timeoutMs: number };
};

/**
 * Poll the CCIP API (via the source chain) until the message reaches one of `acceptedStatuses`
 * (`MessageStatus` values from `@chainlink/ccip-sdk`, e.g. `MessageStatus.Success`).
 */
export async function waitForMessageStatus(
  runtime: StatusPoller,
  messageId: string,
  acceptedStatuses: readonly string[]
): Promise<CCIPRequest> {
  const startedAt = Date.now();
  let lastStatus = "UNKNOWN";
  let lastError: unknown;

  while (Date.now() - startedAt < runtime.config.timeoutMs) {
    try {
      const request = await runtime.source.getMessageById(messageId);
      const status = request.metadata?.status;

      if (status) {
        lastStatus = status;
        console.log(`message ${messageId} status: ${status}`);
        if (acceptedStatuses.includes(status)) {
          return request;
        }
      } else {
        console.log(`message ${messageId} found, waiting for API metadata`);
      }
    } catch (error) {
      lastError = error;
      console.log(`message ${messageId} status lookup pending: ${stringifyError(error)}`);
    }

    await sleep(runtime.config.pollMs);
  }

  throw new Error(
    `timed out waiting for message ${messageId}; last status=${lastStatus}; last error=${stringifyError(lastError)}`
  );
}

export type AdapterMessageState = keyof typeof ADAPTER_ERROR_CODE;

/**
 * Read `messageErrorCode(messageId)` on the destination adapter. Because `ccipReceive` wraps processing in
 * try/catch, a business-logic failure still shows as CCIP `SUCCESS`; the adapter state is the source of truth:
 * `NONE` = processed (or not yet executed), `BASIC` = failed and recoverable, `RESOLVED` = refunded / recovered.
 */
export async function readAdapterMessageState(
  dest: EVMChain,
  adapterAddress: string,
  messageId: string
): Promise<AdapterMessageState> {
  const adapter = new Contract(adapterAddress, ADAPTER_ABI, dest.provider as never);
  const code = Number(await adapter.messageErrorCode(messageId));
  const entry = Object.entries(ADAPTER_ERROR_CODE).find(([, value]) => value === code);
  if (!entry) {
    throw new Error(`adapter returned unknown messageErrorCode ${code} for ${messageId}`);
  }
  return entry[0] as AdapterMessageState;
}

export type AdapterOutcome = {
  /** `succeeded` = `MessageSucceeded`, `failed` = `MessageFailed` (tokens held for refund / local recovery). */
  outcome: "succeeded" | "failed" | "unknown";
  /** Current `messageErrorCode` on the adapter. */
  state: AdapterMessageState;
  /** Destination execution tx reported by the CCIP API, when available. */
  executionTxHash?: string;
};

type ReceiptLike = { logs: readonly { address: string; topics: readonly string[]; data: string }[] };

/**
 * Determine what the adapter did with an executed message. Prefers the adapter's `MessageSucceeded` /
 * `MessageFailed` event in the destination execution receipt (`metadata.receiptTransactionHash` from the CCIP API),
 * and falls back to `messageErrorCode` (`BASIC` / `RESOLVED` imply the message failed in the adapter).
 */
export async function resolveAdapterOutcome(
  dest: EVMChain,
  adapterAddress: string,
  request: CCIPRequest,
  pollMs: number
): Promise<AdapterOutcome> {
  const messageId = request.message.messageId;
  const executionTxHash = request.metadata?.receiptTransactionHash;
  let outcome: AdapterOutcome["outcome"] = "unknown";

  if (executionTxHash) {
    const provider = dest.provider as unknown as { getTransactionReceipt(hash: string): Promise<ReceiptLike | null> };
    const iface = new Interface(ADAPTER_ABI);
    let receipt: ReceiptLike | null = null;
    for (let attempt = 0; attempt < 8 && !receipt; attempt++) {
      receipt = await provider.getTransactionReceipt(executionTxHash);
      if (!receipt) {
        await sleep(Math.min(pollMs, 5_000));
      }
    }
    for (const log of receipt?.logs ?? []) {
      if (getAddress(log.address) !== getAddress(adapterAddress)) {
        continue;
      }
      const parsed = iface.parseLog({ topics: [...log.topics], data: log.data });
      if (!parsed || String(parsed.args[0]).toLowerCase() !== messageId.toLowerCase()) {
        continue;
      }
      if (parsed.name === "MessageSucceeded") {
        outcome = "succeeded";
      } else if (parsed.name === "MessageFailed") {
        outcome = "failed";
      }
    }
  }

  const state = await readAdapterMessageState(dest, adapterAddress, messageId);
  if (outcome === "unknown" && state !== "NONE") {
    outcome = "failed";
  }
  return { outcome, state, executionTxHash };
}

export async function waitForBalanceAtLeast(
  chain: EVMChain,
  tokenAddress: string,
  account: string,
  minimumBalance: bigint,
  pollMs: number,
  timeoutMs: number
): Promise<bigint> {
  const startedAt = Date.now();

  while (Date.now() - startedAt < timeoutMs) {
    const currentBalance = await getTokenBalance(chain, tokenAddress, account);
    if (currentBalance >= minimumBalance) {
      return currentBalance;
    }
    await sleep(pollMs);
  }

  throw new Error(`timed out waiting for ${account} balance on ${tokenAddress} to reach ${minimumBalance}`);
}

// ---------------------------------------------------------------------------
// Failed-message recovery
// ---------------------------------------------------------------------------

/**
 * Cross-chain refund: `refundFailedMessage(messageId)` bridges the inbound tokens back to the original sender on
 * the source chain. Checks `checkRefundEligibility` first, pays `estimateRefundFee` padded by
 * `E2E_REFUND_FEE_MULTIPLIER_BPS` (the adapter returns any excess to the caller), and reports the outbound CCIP
 * message id of the refund leg when it can be parsed from the receipt.
 */
export async function refundFailedMessage(
  runtime: DestRuntime,
  messageId: string
): Promise<{ fee: bigint; value: bigint; txHash: string; refundMessageId?: string }> {
  const adapter = new Contract(runtime.config.destAdapter, ADAPTER_ABI, runtime.destWallet);

  const state = await readAdapterMessageState(runtime.dest, runtime.config.destAdapter, messageId);
  if (state !== "BASIC") {
    throw new Error(
      `message ${messageId} is not refundable: adapter messageErrorCode=${state} (expected BASIC). ` +
        (state === "NONE"
          ? "It was processed successfully or has not executed on the destination yet."
          : "It was already refunded or recovered locally.")
    );
  }

  const eligibility = await adapter.checkRefundEligibility(messageId);
  if (!eligibility.canRefund) {
    throw new Error(
      `checkRefundEligibility(${messageId}) returned canRefund=false (unsupported sender encoding or no refundable amount)`
    );
  }
  console.log(
    `refund eligible: token ${eligibility.token} amount ${eligibility.tokenAmount} -> original sender ${eligibility.originalSender}`
  );

  const estimatedFee = BigInt(await adapter.estimateRefundFee(messageId));
  const value = (estimatedFee * BigInt(runtime.config.refundFeeMultiplierBps) + 9_999n) / 10_000n;
  console.log(
    `estimated refund fee ${estimatedFee} wei; sending ${value} wei (${runtime.config.refundFeeMultiplierBps} bps, excess is returned by the adapter)`
  );

  const tx = await adapter.refundFailedMessage(messageId, { value });
  console.log(`refund tx submitted: ${tx.hash}`);
  await tx.wait();

  let refundMessageId: string | undefined;
  try {
    const requests = await runtime.dest.getMessagesInTx(tx.hash);
    refundMessageId = requests[0]?.message.messageId;
  } catch (error) {
    console.log(`could not parse refund CCIP message from receipt: ${stringifyError(error)}`);
  }

  return { fee: estimatedFee, value, txHash: tx.hash, refundMessageId };
}

/**
 * Local recovery: `recoverFailedMessageLocally(messageId)` transfers the inbound tokens to the payload
 * `localRefundAddress` on the destination chain. The signer must be that address.
 */
export async function recoverFailedMessageLocally(
  runtime: DestRuntime,
  messageId: string
): Promise<{ txHash: string; localRefundAddress: string }> {
  const adapter = new Contract(runtime.config.destAdapter, ADAPTER_ABI, runtime.destWallet);

  const state = await readAdapterMessageState(runtime.dest, runtime.config.destAdapter, messageId);
  if (state !== "BASIC") {
    throw new Error(`message ${messageId} cannot be recovered: adapter messageErrorCode=${state} (expected BASIC)`);
  }

  const eligibility = await adapter.checkLocalRecoveryEligibility(messageId);
  if (!eligibility.canRecover) {
    throw new Error(
      `checkLocalRecoveryEligibility(${messageId}) returned canRecover=false: the payload had no localRefundAddress ` +
        "(bits 1..160 of deliveryAndRefund were zero) or no refundable amount. Use the cross-chain refund instead."
    );
  }
  const localRefundAddress = getAddress(eligibility.localRefundAddress);
  const caller = getAddress(runtime.destWallet.address);
  if (caller !== localRefundAddress) {
    throw new Error(
      `local recovery must be sent by localRefundAddress ${localRefundAddress}; the E2E_PRIVATE_KEY signer is ${caller}`
    );
  }

  const tx = await adapter.recoverFailedMessageLocally(messageId);
  console.log(`local recovery tx submitted: ${tx.hash}`);
  await tx.wait();

  return { txHash: tx.hash, localRefundAddress };
}

export async function logTokenAmount(
  label: string,
  chain: { getTokenInfo(token: string): Promise<{ symbol: string; decimals: number }> },
  tokenAddress: string,
  amount: bigint
): Promise<void> {
  const { symbol, decimals } = await getTokenMetadata(chain, tokenAddress);
  console.log(`${label}: ${formatUnits(amount, decimals)} ${symbol}`);
}

export async function logEvmTokenAmount(
  label: string,
  chain: EVMChain,
  tokenAddress: string,
  amount: bigint,
  decimalsOverride?: number
): Promise<void> {
  const decimals = await readErc20Decimals(chain, tokenAddress, decimalsOverride);
  let symbol = tokenAddress;
  try {
    symbol = (await getTokenMetadata(chain, tokenAddress)).symbol;
  } catch {
    // bridged CCIP tokens may not expose symbol via the SDK path
  }
  console.log(`${label}: ${formatUnits(amount, decimals)} ${symbol}`);
}

// ---------------------------------------------------------------------------
// Env parsing helpers (shared with solana-shared.ts)
// ---------------------------------------------------------------------------

export function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) {
    throw new ConfigError(`missing required env var ${name}`);
  }
  return value;
}

function requireAddressEnv(name: string): string {
  return normalizeEvmAddressEnv(name, requireEnv(name));
}

/** `E2E_DEST_ADAPTER`: the `CrossChainERC4626Adapter` (CCIP receiver) on the destination chain. */
export function requireDestAdapterAddress(): string {
  return requireAddressEnv("E2E_DEST_ADAPTER");
}

export function optionalAddressEnv(name: string): string | undefined {
  const value = process.env[name]?.trim();
  if (!value) {
    return undefined;
  }
  return normalizeEvmAddressEnv(name, value);
}

export function normalizeEvmAddressEnv(name: string, value: string): string {
  if (!isAddress(value)) {
    throw new ConfigError(`env var ${name} must be a valid EVM address, got ${value}`);
  }
  return getAddress(value);
}

export function parseIntegerEnv(name: string, fallback: number): number {
  const value = process.env[name]?.trim();
  if (!value) {
    return fallback;
  }
  return parsePositiveInteger(name, value);
}

export function optionalIntegerEnv(name: string): number | undefined {
  const value = process.env[name]?.trim();
  if (!value) {
    return undefined;
  }
  return parsePositiveInteger(name, value);
}

function parsePositiveInteger(name: string, value: string): number {
  if (!/^\d+$/.test(value) || Number(value) <= 0 || !Number.isSafeInteger(Number(value))) {
    throw new ConfigError(`env var ${name} must be a positive integer, got ${value}`);
  }
  return Number(value);
}

export function parseBooleanEnv(name: string, fallback: boolean): boolean {
  const value = process.env[name]?.trim();
  if (!value) {
    return fallback;
  }

  const normalized = value.toLowerCase();
  if (normalized === "true") {
    return true;
  }
  if (normalized === "false") {
    return false;
  }

  throw new ConfigError(`env var ${name} must be 'true' or 'false', got ${value}`);
}

/** Default **0**; nonnegative uint32 for {@link bridgeVaultTokensOnlyToBeneficiary} (not {@link sendMessageWithToken}). */
function bridgeDestinationExecutionGasLimitFromEnv(): number {
  const raw = process.env.E2E_BRIDGE_CCIP_GAS_LIMIT?.trim();
  if (raw === undefined || raw === "") {
    return 0;
  }
  const parsed = Number(raw);
  if (!/^\d+$/.test(raw) || parsed > 0xffffffff) {
    throw new ConfigError(`env var E2E_BRIDGE_CCIP_GAS_LIMIT must be a uint32, got ${raw}`);
  }
  return parsed;
}

export function optionalFinalityBytes4Env(name: string): `0x${string}` | undefined {
  const raw = process.env[name]?.trim();
  if (!raw) {
    return undefined;
  }
  const hex = (raw.startsWith("0x") ? raw : `0x${raw}`) as `0x${string}`;
  if (!isHexString(hex, 4)) {
    throw new ConfigError(`env var ${name} must be exactly 4 bytes of hex (8 hex digits, optionally 0x-prefixed), got ${raw}`);
  }
  const normalized = hexlify(getBytes(hex)) as `0x${string}`;
  // All-zero finality is treated as unset so CCIP V1 lanes keep the SDK's default extraArgs.
  if (normalized === "0x00000000") {
    return undefined;
  }
  return normalized;
}

function optionalDecimalsEnv(name: string): number | undefined {
  const raw = process.env[name]?.trim();
  if (!raw) {
    return undefined;
  }
  const parsed = Number(raw);
  if (!/^\d+$/.test(raw) || parsed > 36) {
    throw new ConfigError(`env var ${name} must be an integer between 0 and 36, got ${raw}`);
  }
  return parsed;
}

function assertDistinctChains(sourceChain: NetworkInfo, destChain: NetworkInfo): void {
  if (sourceChain.chainSelector === destChain.chainSelector) {
    throw new ConfigError(`source and destination chains must be different (both resolve to ${sourceChain.name})`);
  }
}

export function assertFamily(chain: NetworkInfo, family: string, envName: string): void {
  if (chain.family !== family) {
    throw new ConfigError(`env var ${envName} must be an ${family} chain for this script, got ${chain.name} (${chain.family})`);
  }
}

/** `E2E_PRIVATE_KEY`, validated before any network access. The value is never echoed. */
function requirePrivateKeyEnv(): string {
  const raw = requireEnv("E2E_PRIVATE_KEY");
  const key = raw.startsWith("0x") ? raw : `0x${raw}`;
  if (!isHexString(key, 32)) {
    throw new ConfigError("env var E2E_PRIVATE_KEY must be a 32-byte hex private key (64 hex digits, optionally 0x-prefixed)");
  }
  return key;
}

function createWallet(privateKey: string, chain: EVMChain): Wallet {
  try {
    return new Wallet(privateKey, chain.provider as never);
  } catch {
    // Never echo the key itself.
    throw new ConfigError("env var E2E_PRIVATE_KEY is not a valid 32-byte hex private key");
  }
}

// ---------------------------------------------------------------------------
// Misc
// ---------------------------------------------------------------------------

export function getBeneficiary(runtime: Runtime): string {
  return runtime.config.beneficiary ?? runtime.destWallet.address;
}

/** Optional destination-chain EVM address from `E2E_LOCAL_REFUND_ADDRESS` for packed `deliveryAndRefund`. */
export function getLocalRefundAddress(runtime: Pick<Runtime, "config">): string | undefined {
  return runtime.config.localRefundAddress;
}

/** Shared payload flags for adapter `deliveryAndRefund` encoding. */
export function getPayloadDeliveryOptions(runtime: Pick<Runtime, "config">): {
  returnToSourceChain: boolean;
  localRefundAddress?: string;
} {
  return {
    returnToSourceChain: runtime.config.returnToSourceChain,
    localRefundAddress: runtime.config.localRefundAddress
  };
}

export function getRedeemSourceVaultToken(runtime: Runtime): string {
  const token = runtime.config.sourceVaultToken;
  if (!token) {
    throw new ConfigError("missing required env var E2E_SOURCE_VAULT_TOKEN_ADDRESS for the redeem scenario");
  }
  return token;
}

function encodeBeneficiary(beneficiary: string, beneficiaryType: "evm" | "svm" = "evm"): string {
  if (beneficiaryType === "svm") {
    return `0x${Buffer.from(new PublicKey(beneficiary).toBytes()).toString("hex")}`;
  }

  return zeroPadValue(getAddress(beneficiary), 32);
}

async function resolveCcipGasLimit(
  runtime: Runtime,
  params: {
    sourceToken: string;
    amount: bigint;
    data: string;
  }
): Promise<number> {
  if (runtime.config.ccipGasLimitOverride) {
    console.log(`using manual CCIP gas limit override: ${runtime.config.ccipGasLimitOverride}`);
    return runtime.config.ccipGasLimitOverride;
  }

  const estimatedGasLimit = await estimateReceiveExecution({
    source: runtime.source,
    dest: runtime.dest,
    routerOrRamp: runtime.config.sourceRouter,
    message: {
      sender: runtime.sourceWallet.address,
      receiver: runtime.config.destAdapter,
      data: params.data,
      tokenAmounts: [
        {
          token: params.sourceToken,
          amount: params.amount
        }
      ]
    }
  });

  const gasLimit = Math.ceil((estimatedGasLimit * runtime.config.ccipGasMultiplierBps) / 10_000);
  console.log(
    `estimated CCIP receive gas: ${estimatedGasLimit}; applying multiplier ${runtime.config.ccipGasMultiplierBps} bps -> ${gasLimit}`
  );

  return gasLimit;
}

export function stringifyError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  return String(error);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
