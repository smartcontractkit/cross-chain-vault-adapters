import { encodeSvmPayload, logSentMessage, logTokenAmount, parseTokenAmount, runMain } from "./shared";
import {
  createSolanaRuntime,
  destroySolanaRuntime,
  getSolanaPayloadBeneficiary,
  getSolanaPayloadDeliveryOptions,
  getSolanaRedeemSourceToken,
  sendMessageFromSolanaWithToken
} from "./solana-shared";

/** Solana redeem: bridge vault shares (`E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT`) from Solana to the EVM adapter. */
async function main(): Promise<void> {
  const runtime = await createSolanaRuntime({ requireRedeemMint: true });

  try {
    const { beneficiary, beneficiaryType } = getSolanaPayloadBeneficiary(runtime);
    const sourceVaultToken = getSolanaRedeemSourceToken(runtime);
    const amount = await parseTokenAmount(runtime.source, sourceVaultToken, runtime.config.redeemAmount);
    const minimumOut = await parseTokenAmount(runtime.dest, runtime.config.destAssetToken, runtime.config.redeemMinimumOut);

    await logTokenAmount("bridged Solana vault share amount", runtime.source, sourceVaultToken, amount);

    const data = encodeSvmPayload({
      target: runtime.config.destVault,
      beneficiary,
      beneficiaryType,
      minimumOut,
      ...getSolanaPayloadDeliveryOptions(runtime)
    });

    const request = await sendMessageFromSolanaWithToken(runtime, {
      sourceToken: sourceVaultToken,
      amount,
      data
    });

    logSentMessage(request);
  } finally {
    await destroySolanaRuntime(runtime);
  }
}

runMain(main);
