import { createDestRuntime, getMessageIdArg, recoverFailedMessageLocally, runMain } from "./shared";

/** `recoverFailedMessageLocally(messageId)`: the payload's `localRefundAddress` pulls the inbound tokens on the destination chain. */
async function main(): Promise<void> {
  const messageId = getMessageIdArg("recover-local");
  const runtime = await createDestRuntime();

  try {
    const { txHash, localRefundAddress } = await recoverFailedMessageLocally(runtime, messageId);

    console.log(`locally recovered failed message: ${messageId}`);
    console.log(`tokens transferred to: ${localRefundAddress}`);
    console.log(`local recovery tx hash: ${txHash}`);
  } finally {
    await runtime.destroy();
  }
}

runMain(main);
