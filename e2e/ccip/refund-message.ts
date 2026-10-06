import { ccipExplorerUrl } from "./report";
import { createDestRuntime, getMessageIdArg, refundFailedMessage, runMain } from "./shared";

/** `refundFailedMessage(messageId)` on the destination adapter: bridges the inbound tokens back to the original sender. */
async function main(): Promise<void> {
  const messageId = getMessageIdArg("refund");
  const runtime = await createDestRuntime();

  try {
    const { fee, value, txHash, refundMessageId } = await refundFailedMessage(runtime, messageId);

    console.log(`refunded failed message: ${messageId}`);
    console.log(`refund tx hash: ${txHash}`);
    console.log(`refund fee estimate: ${fee} wei (sent ${value} wei; excess returned to the caller)`);
    if (refundMessageId) {
      console.log(`refund CCIP message id: ${refundMessageId}`);
      console.log(`track: ${ccipExplorerUrl(refundMessageId)}`);
    }
  } finally {
    await runtime.destroy();
  }
}

runMain(main);
