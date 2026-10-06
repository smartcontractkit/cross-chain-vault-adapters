import {
  createRuntime,
  destroyRuntime,
  encodePayload,
  getBeneficiary,
  getPayloadDeliveryOptions,
  logEvmTokenAmount,
  logSentMessage,
  parseEvmTokenAmount,
  runMain,
  sendMessageWithToken
} from "./shared";

/** EVM deposit: bridge `E2E_SOURCE_USDC_TOKEN_ADDRESS` to the adapter with a valid payload targeting `E2E_DEST_VAULT`. */
async function main(): Promise<void> {
  const runtime = await createRuntime();

  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.depositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.depositMinimumOut);

    await logEvmTokenAmount("bridged USDC amount", runtime.source, runtime.config.sourceUsdcToken, amount);

    const payload = encodePayload({
      target: runtime.config.destVault,
      beneficiary,
      minimumOut,
      ...getPayloadDeliveryOptions(runtime)
    });

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: payload
    });

    logSentMessage(request);
  } finally {
    await destroyRuntime(runtime);
  }
}

runMain(main);
