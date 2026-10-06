import { encodeSvmPayload, logSentMessage, logTokenAmount, parseTokenAmount, runMain } from "./shared";
import {
  createSolanaRuntime,
  destroySolanaRuntime,
  getSolanaPayloadBeneficiary,
  getSolanaPayloadDeliveryOptions,
  sendMessageFromSolanaWithToken
} from "./solana-shared";

/** Solana deposit: bridge `E2E_SOLANA_SOURCE_USDC_TOKEN_MINT` from Solana to the EVM adapter targeting `E2E_DEST_VAULT`. */
async function main(): Promise<void> {
  const runtime = await createSolanaRuntime();

  try {
    const amount = await parseTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.depositAmount);

    await logTokenAmount("bridged Solana USDC amount", runtime.source, runtime.config.sourceUsdcToken, amount);

    const { beneficiary, beneficiaryType } = getSolanaPayloadBeneficiary(runtime);
    const minimumOut = await parseTokenAmount(
      runtime.dest,
      runtime.config.destVault,
      runtime.config.depositMinimumOut
    );

    const data = encodeSvmPayload({
      target: runtime.config.destVault,
      beneficiary,
      beneficiaryType,
      minimumOut,
      ...getSolanaPayloadDeliveryOptions(runtime)
    });

    const request = await sendMessageFromSolanaWithToken(
      runtime,
      {
        sourceToken: runtime.config.sourceUsdcToken,
        amount,
        data
      },
      { logSupportSnippet: true, supportSnippetLabel: "solana-deposit (e2e)" }
    );

    logSentMessage(request);
  } finally {
    await destroySolanaRuntime(runtime);
  }
}

runMain(main);
