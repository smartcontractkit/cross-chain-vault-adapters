import os from "node:os";
import path from "node:path";
import { existsSync, readFileSync } from "node:fs";

import { EVMChain, SDK_VERSION, SolanaChain, estimateReceiveExecution } from "@chainlink/ccip-sdk";
import { ComputeBudgetProgram, Keypair, PublicKey, Transaction, TransactionMessage, VersionedTransaction } from "@solana/web3.js";
import bs58 from "bs58";

// Importing ./shared also loads e2e/ccip/.env.
import {
  ConfigError,
  assertEnvPresent,
  assertFamily,
  optionalAddressEnv,
  optionalIntegerEnv,
  parseBooleanEnv,
  parseIntegerEnv,
  requireDestAdapterAddress,
  requireEnv,
  resolveNetworkEnv
} from "./shared";

export type SolanaWallet = {
  readonly publicKey: PublicKey;
  signTransaction<T extends Transaction | VersionedTransaction>(tx: T): Promise<T>;
};

export type SolanaRuntime = {
  source: SolanaChain;
  dest: EVMChain;
  sourceWallet: SolanaWallet;
  config: ReturnType<typeof loadSolanaConfig>;
};

export function loadSolanaConfig() {
  assertEnvPresent(
    [
      "E2E_SOLANA_SOURCE_RPC_URL",
      "E2E_DEST_RPC_URL",
      "E2E_SOLANA_SOURCE_ROUTER",
      "E2E_SOLANA_WALLET_SECRET_KEY",
      "E2E_SOLANA_SOURCE_USDC_TOKEN_MINT",
      "E2E_DEST_ADAPTER",
      "E2E_DEST_VAULT",
      "E2E_DEST_ASSET_TOKEN_ADDRESS"
    ],
    "Solana source scripts"
  );

  const sourceChain = resolveNetworkEnv("E2E_SOLANA_SOURCE_CHAIN", "solana-devnet");
  const destChain = resolveNetworkEnv("E2E_DEST_CHAIN", "ethereum-testnet-sepolia");
  assertFamily(sourceChain, "SVM", "E2E_SOLANA_SOURCE_CHAIN");
  assertFamily(destChain, "EVM", "E2E_DEST_CHAIN");

  const returnToSourceChain = parseBooleanEnv(
    "E2E_SOLANA_RETURN_TO_SOURCE_CHAIN",
    parseBooleanEnv("E2E_RETURN_TO_SOURCE_CHAIN", true)
  );
  const destBeneficiary = optionalAddressEnv("E2E_DEST_BENEFICIARY");
  if (!returnToSourceChain && !destBeneficiary) {
    throw new ConfigError(
      "missing required env var E2E_DEST_BENEFICIARY (needed when E2E_SOLANA_RETURN_TO_SOURCE_CHAIN=false: local delivery goes to an EVM address)"
    );
  }

  return {
    sourceRpcUrl: requireEnv("E2E_SOLANA_SOURCE_RPC_URL"),
    destRpcUrl: requireEnv("E2E_DEST_RPC_URL"),
    sourceRouter: requireSolanaAddressEnv("E2E_SOLANA_SOURCE_ROUTER"),
    walletSecretKey: requireEnv("E2E_SOLANA_WALLET_SECRET_KEY"),
    sourceUsdcToken: requireSolanaAddressEnv("E2E_SOLANA_SOURCE_USDC_TOKEN_MINT"),
    /** Only needed by the redeem script / scenario; see {@link getSolanaRedeemSourceToken}. */
    sourceVaultToken: optionalSolanaAddressEnv("E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT"),
    sourceBeneficiary: optionalSolanaAddressEnv("E2E_SOLANA_BENEFICIARY"),
    destAdapter: requireDestAdapterAddress(),
    destVault: requireEvmAddressEnv("E2E_DEST_VAULT"),
    destAssetToken: requireEvmAddressEnv("E2E_DEST_ASSET_TOKEN_ADDRESS"),
    destBeneficiary,
    ccipGasLimitOverride: optionalIntegerEnv("E2E_CCIP_GAS_LIMIT"),
    ccipGasMultiplierBps: parseIntegerEnv("E2E_CCIP_GAS_MULTIPLIER_BPS", 12_000),
    pollMs: parseIntegerEnv("E2E_STATUS_POLL_MS", 15_000),
    timeoutMs: parseIntegerEnv("E2E_STATUS_TIMEOUT_MS", 30 * 60 * 1000),
    depositAmount: process.env.E2E_SOLANA_DEPOSIT_USDC_AMOUNT ?? process.env.E2E_DEPOSIT_USDC_AMOUNT ?? "1",
    depositMinimumOut: process.env.E2E_SOLANA_DEPOSIT_MINIMUM_OUT ?? process.env.E2E_DEPOSIT_MINIMUM_OUT ?? "1",
    redeemAmount: process.env.E2E_SOLANA_REDEEM_VUSDC_AMOUNT ?? process.env.E2E_REDEEM_VAULT_AMOUNT ?? "1",
    redeemMinimumOut: process.env.E2E_SOLANA_REDEEM_MINIMUM_OUT ?? process.env.E2E_REDEEM_MINIMUM_OUT ?? "1",
    returnToSourceChain,
    localRefundAddress: optionalAddressEnv("E2E_LOCAL_REFUND_ADDRESS"),
    sourceChain,
    destChain
  };
}

/** Source vault-share mint for Solana redeem (`E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT`). */
export function getSolanaRedeemSourceToken(runtime: SolanaRuntime): string {
  const token = runtime.config.sourceVaultToken;
  if (!token) {
    throw new ConfigError("missing required env var E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT for the Solana redeem scenario");
  }
  return token;
}

export async function createSolanaRuntime(opts: { requireRedeemMint?: boolean } = {}): Promise<SolanaRuntime> {
  const config = loadSolanaConfig();
  if (opts.requireRedeemMint && !config.sourceVaultToken) {
    throw new ConfigError("missing required env var E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT for the Solana redeem scenario");
  }
  // Parse the key before opening any connection so a bad key fails fast.
  const sourceWallet = createSolanaWallet(config.walletSecretKey);
  const [source, dest] = await Promise.all([SolanaChain.fromUrl(config.sourceRpcUrl), EVMChain.fromUrl(config.destRpcUrl)]);

  return {
    source,
    dest,
    sourceWallet,
    config
  };
}

export async function destroySolanaRuntime(runtime: SolanaRuntime): Promise<void> {
  await Promise.allSettled([runtime.source.destroy?.(), runtime.dest.destroy?.()]);
}

export function getSolanaPayloadDeliveryOptions(runtime: SolanaRuntime): {
  returnToSourceChain: boolean;
  localRefundAddress?: string;
} {
  return {
    returnToSourceChain: runtime.config.returnToSourceChain,
    localRefundAddress: runtime.config.localRefundAddress
  };
}

export function getSolanaPayloadBeneficiary(runtime: SolanaRuntime): { beneficiary: string; beneficiaryType: "evm" | "svm" } {
  if (runtime.config.returnToSourceChain) {
    return {
      beneficiary: runtime.config.sourceBeneficiary ?? runtime.sourceWallet.publicKey.toBase58(),
      beneficiaryType: "svm"
    };
  }

  if (!runtime.config.destBeneficiary) {
    throw new ConfigError("set E2E_DEST_BENEFICIARY when returnToSourceChain is false (E2E_SOLANA_RETURN_TO_SOURCE_CHAIN=false)");
  }

  return {
    beneficiary: runtime.config.destBeneficiary,
    beneficiaryType: "evm"
  };
}

function summarizeHexData(data: string, maxChars = 46): { preview: string; lengthChars: number } {
  const hex = data.startsWith("0x") ? data : `0x${data}`;
  const preview = hex.length > maxChars ? `${hex.slice(0, maxChars)}…` : hex;
  return { preview, lengthChars: hex.length };
}

/** Same packing as @chainlink/ccip-sdk `simulateTransaction`: compute budget ix + CCIP ixs, v0 + ALTs. */
async function buildCcipSendTxDiagnostics(
  runtime: SolanaRuntime,
  gasLimit: number,
  params: { sourceToken: string; amount: bigint; data: string }
): Promise<Record<string, unknown>> {
  const unsigned = await runtime.source.generateUnsignedSendMessage({
    router: runtime.config.sourceRouter,
    destChainSelector: runtime.config.destChain.chainSelector,
    sender: runtime.sourceWallet.publicKey.toBase58(),
    message: {
      receiver: runtime.config.destAdapter,
      data: params.data,
      tokenAmounts: [{ token: params.sourceToken, amount: params.amount }],
      extraArgs: {
        gasLimit: BigInt(gasLimit),
        allowOutOfOrderExecution: true
      }
    }
  });

  const uniqueKeys = new Set<string>();
  let accountMetasTotal = 0;
  const perInstruction = unsigned.instructions.map((ix, index) => {
    accountMetasTotal += ix.keys.length;
    uniqueKeys.add(ix.programId.toBase58());
    for (const k of ix.keys) {
      uniqueKeys.add(k.pubkey.toBase58());
    }
    return { index, programId: ix.programId.toBase58(), accountMetas: ix.keys.length };
  });
  uniqueKeys.add(runtime.sourceWallet.publicKey.toBase58());

  const maxComputeUnits = 1_400_000;
  const computeBudgetIx = ComputeBudgetProgram.setComputeUnitLimit({ units: maxComputeUnits });
  const recentBlockhash = "11111111111111111111111111111112";
  const txMsg = new TransactionMessage({
    payerKey: runtime.sourceWallet.publicKey,
    recentBlockhash,
    instructions: [computeBudgetIx, ...unsigned.instructions]
  });
  const messageV0 = txMsg.compileToV0Message(unsigned.lookupTables);
  const vt = new VersionedTransaction(messageV0);
  const signed = await runtime.sourceWallet.signTransaction(vt);

  return {
    note: "Packed like ccip-sdk simulateTransaction (compute budget + all unsigned ixs, compileToV0Message(lookupTables))",
    instructionCount: unsigned.instructions.length,
    mainInstructionIndex: unsigned.mainIndex ?? null,
    perInstructionAccountMetas: perInstruction,
    accountMetasSum: accountMetasTotal,
    uniquePubkeysInInstructionsPlusPayer: uniqueKeys.size,
    compiledStaticAccountKeys: messageV0.staticAccountKeys.length,
    addressLookupTableAccountCount: unsigned.lookupTables?.length ?? 0,
    compiledMessageBytes: messageV0.serialize().length,
    signedSerializedTxBytes: signed.serialize().length,
    solanaRawTxSizeLimitBytes: 1232
  };
}

/** Paste-friendly block for @chainlink/ccip-sdk support (e.g. tx size / simulation issues). */
async function logCcipSendSupportSnippet(
  label: string,
  runtime: SolanaRuntime,
  gasLimit: number,
  params: { sourceToken: string; amount: bigint; data: string }
): Promise<void> {
  const { preview, lengthChars } = summarizeHexData(params.data);
  let txDiagnostics: Record<string, unknown>;
  try {
    txDiagnostics = await buildCcipSendTxDiagnostics(runtime, gasLimit, params);
  } catch (e) {
    txDiagnostics = {
      error: e instanceof Error ? e.message : String(e)
    };
  }

  const snippet = {
    label,
    ccipSdk: `@chainlink/ccip-sdk@${SDK_VERSION}`,
    call: "SolanaChain.sendMessage() → Router program ccipSend (Anchor)",
    lanes: {
      source: {
        name: runtime.config.sourceChain.name,
        chainSelector: runtime.config.sourceChain.chainSelector.toString()
      },
      dest: {
        name: runtime.config.destChain.name,
        chainSelector: runtime.config.destChain.chainSelector.toString()
      }
    },
    router: runtime.config.sourceRouter,
    feePayer: runtime.sourceWallet.publicKey.toBase58(),
    sendMessageArgs: {
      destChainSelector: runtime.config.destChain.chainSelector.toString(),
      message: {
        receiver: runtime.config.destAdapter,
        dataPreview: preview,
        dataLengthChars: lengthChars,
        tokenAmounts: [{ token: params.sourceToken, amount: params.amount.toString() }],
        extraArgs: { gasLimit, allowOutOfOrderExecution: true }
      }
    },
    txDiagnostics
  };

  console.log(`\n--- CCIP SDK support snippet ---\n${JSON.stringify(snippet, null, 2)}\n--- end snippet ---\n`);
}

export async function sendMessageFromSolanaWithToken(
  runtime: SolanaRuntime,
  params: {
    sourceToken: string;
    amount: bigint;
    data: string;
  },
  options?: { logSupportSnippet?: boolean; supportSnippetLabel?: string }
) {
  const gasLimit = await resolveCcipGasLimit(runtime, params);
  console.log(`sending Solana token ${params.sourceToken} amount ${params.amount.toString()} with gasLimit ${gasLimit}`);

  if (options?.logSupportSnippet) {
    await logCcipSendSupportSnippet(options.supportSnippetLabel ?? "solana-send", runtime, gasLimit, params);
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
        gasLimit: BigInt(gasLimit),
        allowOutOfOrderExecution: true
      }
    }
  });

  const requestTokenAmounts = request.message.tokenAmounts ?? [];
  if (requestTokenAmounts.length !== 1) {
    throw new Error(
      `CCIP source tx was sent without exactly one token transfer; received tokenAmounts=${JSON.stringify(
        requestTokenAmounts,
        (_key, value) => typeof value === "bigint" ? value.toString() : value
      )}`
    );
  }

  return request;
}

function createSolanaWallet(secretKey: string): SolanaWallet {
  let keypair: Keypair;
  try {
    keypair = Keypair.fromSecretKey(parseSecretKey(secretKey));
  } catch (error) {
    if (error instanceof ConfigError) {
      throw error;
    }
    // Never echo the key itself.
    throw new ConfigError(
      "env var E2E_SOLANA_WALLET_SECRET_KEY must be a keypair file path, a base58 secret key or a JSON byte array (64 bytes)"
    );
  }

  return {
    publicKey: keypair.publicKey,
    async signTransaction<T extends Transaction | VersionedTransaction>(tx: T): Promise<T> {
      if (tx instanceof VersionedTransaction) {
        tx.sign([keypair]);
      } else {
        tx.partialSign(keypair);
      }
      return tx;
    }
  };
}

function parseSecretKey(secretKey: string): Uint8Array {
  const trimmed = resolveSecretKeyInput(secretKey).trim();

  if (trimmed.startsWith("[")) {
    const parsed: unknown = JSON.parse(trimmed);
    if (!Array.isArray(parsed)) {
      throw new ConfigError("E2E_SOLANA_WALLET_SECRET_KEY JSON form must be an array of bytes");
    }
    return Uint8Array.from(parsed as number[]);
  }

  return Uint8Array.from(bs58.decode(trimmed));
}

/** Accepts a keypair file path (a leading `~` expands to the home directory) or the key material itself. */
function resolveSecretKeyInput(secretKey: string): string {
  const trimmed = secretKey.trim();
  const expanded = trimmed === "~" || trimmed.startsWith("~/") ? path.join(os.homedir(), trimmed.slice(1)) : trimmed;
  if (existsSync(expanded)) {
    return readFileSync(expanded, "utf8");
  }
  if (trimmed.endsWith(".json") || trimmed.includes("/")) {
    throw new ConfigError(`E2E_SOLANA_WALLET_SECRET_KEY looks like a file path but ${expanded} does not exist`);
  }
  return trimmed;
}

async function resolveCcipGasLimit(
  runtime: SolanaRuntime,
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
      sender: runtime.sourceWallet.publicKey.toBase58(),
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

function requireEvmAddressEnv(name: string): string {
  const value = optionalAddressEnv(name);
  if (!value) {
    throw new ConfigError(`missing required env var ${name}`);
  }
  return value;
}

function requireSolanaAddressEnv(name: string): string {
  return normalizeSolanaAddress(name, requireEnv(name));
}

function optionalSolanaAddressEnv(name: string): string | undefined {
  const value = process.env[name]?.trim();
  if (!value) {
    return undefined;
  }
  return normalizeSolanaAddress(name, value);
}

function normalizeSolanaAddress(name: string, value: string): string {
  try {
    return new PublicKey(value).toBase58();
  } catch {
    throw new ConfigError(`env var ${name} must be a valid Solana address, got ${value}`);
  }
}
