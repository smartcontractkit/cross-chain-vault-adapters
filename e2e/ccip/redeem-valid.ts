import {
  createRuntime,
  destroyRuntime,
  encodePayload,
  getBeneficiary,
  getPayloadDeliveryOptions,
  getRedeemSourceVaultToken,
  logEvmTokenAmount,
  logSentMessage,
  parseEvmTokenAmount,
  runMain,
  sendMessageWithToken
} from "./shared";

/** EVM redeem: bridge vault shares (`E2E_SOURCE_VAULT_TOKEN_ADDRESS`) to the adapter; it redeems them on `E2E_DEST_VAULT`. */
async function main(): Promise<void> {
  const runtime = await createRuntime({ requireRedeemToken: true });

  try {
    const beneficiary = getBeneficiary(runtime);
    const sourceVaultToken = getRedeemSourceVaultToken(runtime);
    const amount = await parseEvmTokenAmount(
      runtime.source,
      sourceVaultToken,
      runtime.config.redeemAmount,
      runtime.config.sourceVaultTokenDecimals
    );
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destAssetToken, runtime.config.redeemMinimumOut);

    await logEvmTokenAmount("bridged vault token amount", runtime.source, sourceVaultToken, amount, runtime.config.sourceVaultTokenDecimals);

    const payload = encodePayload({
      target: runtime.config.destVault,
      beneficiary,
      minimumOut,
      ...getPayloadDeliveryOptions(runtime)
    });

    const request = await sendMessageWithToken(runtime, {
      sourceToken: sourceVaultToken,
      amount,
      data: payload
    });

    logSentMessage(request);
  } finally {
    await destroyRuntime(runtime);
  }
}

runMain(main);
