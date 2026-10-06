import {
  bridgeVaultTokensOnlyToBeneficiary,
  createBridgeVaultRuntime,
  destroyBridgeVaultRuntime,
  logSentMessage,
  logTokenAmount,
  parseTokenAmount,
  runMain
} from "./shared";

/**
 * Tokens-only CCIP bridge: `E2E_SOURCE_VAULT_TOKEN_ADDRESS` from **`E2E_SOURCE_CHAIN`** to
 * **`E2E_DEST_BENEFICIARY`** on **`E2E_DEST_CHAIN`** (no adapter receiver, **empty `message.data`**).
 *
 * Does not require **`E2E_DEST_ADAPTER`**, vault, or USDC env vars. Destination execution `gasLimit` defaults to **0**
 * (`E2E_BRIDGE_CCIP_GAS_LIMIT` to override).
 */
async function main(): Promise<void> {
  const runtime = await createBridgeVaultRuntime();

  try {
    const { sourceVaultToken } = runtime.config;
    const amount = await parseTokenAmount(runtime.source, sourceVaultToken, runtime.config.bridgeAmountHuman);

    await logTokenAmount("bridge vault token amount", runtime.source, sourceVaultToken, amount);

    const request = await bridgeVaultTokensOnlyToBeneficiary(runtime, amount);

    logSentMessage(request);
  } finally {
    await destroyBridgeVaultRuntime(runtime);
  }
}

runMain(main);
