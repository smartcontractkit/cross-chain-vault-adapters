import {
  createRuntime,
  destroyRuntime,
  encodePayload,
  getBeneficiary,
  getLocalRefundAddress,
  getPayloadDeliveryOptions,
  invalidTargetAddress,
  logEvmTokenAmount,
  logSentMessage,
  parseEvmTokenAmount,
  runMain,
  sendMessageWithToken
} from "./shared";

/**
 * Failure send: same as `deposit-valid.ts` but with a target the adapter has not enabled, so `processMessage`
 * reverts `InvalidTarget`. `ccipReceive` catches it, so CCIP shows SUCCESS while the adapter stores the message as
 * failed (`messageErrorCode == BASIC`) and emits `MessageFailed`. Recover with `refund` or `recover-local`.
 */
async function main(): Promise<void> {
  const runtime = await createRuntime();

  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.invalidDepositAmount);
    const minimumOut = await parseEvmTokenAmount(
      runtime.dest,
      runtime.config.destVault,
      runtime.config.invalidDepositMinimumOut
    );

    await logEvmTokenAmount("bridged USDC amount", runtime.source, runtime.config.sourceUsdcToken, amount);

    const payload = encodePayload({
      target: invalidTargetAddress(),
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
    console.log("once the message has executed on the destination (CCIP status SUCCESS, adapter emits MessageFailed):");
    console.log(`- cross-chain refund: pnpm e2e:ccip refund ${request.message.messageId}`);
    if (getLocalRefundAddress(runtime)) {
      console.log(
        `- local recovery (signer must be E2E_LOCAL_REFUND_ADDRESS): pnpm e2e:ccip recover-local ${request.message.messageId}`
      );
    }
  } finally {
    await destroyRuntime(runtime);
  }
}

runMain(main);
