import { type CCIPRequest, type EVMChain, MessageStatus } from "@chainlink/ccip-sdk";

import {
  type Runtime,
  type StatusPoller,
  createRuntime,
  destroyRuntime,
  encodePayload,
  encodeSvmPayload,
  getBeneficiary,
  getLocalRefundAddress,
  getPayloadDeliveryOptions,
  getRedeemSourceVaultToken,
  invalidTargetAddress,
  logEvmTokenAmount,
  logTokenAmount,
  parseEvmTokenAmount,
  parseTokenAmount,
  readErc20Decimals,
  recoverFailedMessageLocally,
  refundFailedMessage,
  resolveAdapterOutcome,
  sendMessageWithToken,
  waitForMessageStatus
} from "./shared";
import {
  createSolanaRuntime,
  destroySolanaRuntime,
  getSolanaPayloadBeneficiary,
  getSolanaPayloadDeliveryOptions,
  getSolanaRedeemSourceToken,
  sendMessageFromSolanaWithToken
} from "./solana-shared";
import { ccipExplorerUrl, chainTxExplorerUrl, formatScenarioError, type ScenarioRecord } from "./report";

export type SuiteProfile = "ccip-v1" | "happy" | "failure" | "recovery" | "all";

export type ScenarioDef = {
  id: string;
  name: string;
  category: "happy" | "failure" | "recovery" | "manual";
  family: "evm" | "svm" | "multi";
  profiles: SuiteProfile[];
  expectedOutcome: string;
  requiresSolana?: boolean;
  requiresLocalRefund?: boolean;
  requiresRedeemToken?: boolean;
  requiresWait?: boolean;
  run: (ctx: ScenarioRunContext, def: ScenarioDef) => Promise<ScenarioRecord>;
};

export type ScenarioRunContext = {
  wait: boolean;
  skipSolana: boolean;
};

const FAIL_DEPOSIT_MINIMUM_OUT = process.env.E2E_SUITE_FAIL_DEPOSIT_MINIMUM_OUT ?? "999999999";
const FAIL_REDEEM_MINIMUM_OUT = process.env.E2E_SUITE_FAIL_REDEEM_MINIMUM_OUT ?? "999999999";

function startRecord(def: ScenarioDef): { record: ScenarioRecord; startedAt: number } {
  const startedAt = Date.now();
  return {
    startedAt,
    record: {
      id: def.id,
      name: def.name,
      category: def.category,
      family: def.family,
      status: "failed",
      expectedOutcome: def.expectedOutcome,
      startedAt: new Date(startedAt).toISOString(),
      finishedAt: "",
      durationMs: 0,
      notes: []
    }
  };
}

function finishRecord(record: ScenarioRecord, startedAt: number): ScenarioRecord {
  const finishedAt = Date.now();
  record.finishedAt = new Date(finishedAt).toISOString();
  record.durationMs = finishedAt - startedAt;
  return record;
}

function annotateSend(record: ScenarioRecord, request: CCIPRequest, sourceChainName: string): void {
  record.sendTxHash = request.tx.hash;
  record.messageId = request.message.messageId;
  record.ccipExplorerUrl = ccipExplorerUrl(request.message.messageId);
  record.sendTxExplorerUrl = chainTxExplorerUrl(sourceChainName, request.tx.hash);
}

/** What {@link settle} needs from an EVM or Solana runtime. */
type SettleRuntime = StatusPoller & {
  dest: EVMChain;
  config: { destAdapter: string; pollMs: number; destChain: { name: string } };
};

/**
 * Resolve the scenario outcome; returns true when it matched `expected` (or when not waiting).
 *
 * Without `--wait` the record is marked `sent`. With `--wait` it polls the CCIP API until the message is terminal,
 * then checks what the adapter did. `ccipReceive` catches processing reverts, so a business-logic failure
 * (InvalidTarget, MinimumOutputNotMet, ...) is CCIP `SUCCESS` + adapter `MessageFailed`; CCIP `FAILED` means
 * `ccipReceive` itself reverted (typically too little destination gas) and needs manual execution.
 */
async function settle(
  record: ScenarioRecord,
  runtime: SettleRuntime,
  request: CCIPRequest,
  expected: "succeeded" | "failed",
  wait: boolean
): Promise<boolean> {
  if (!wait) {
    record.status = "sent";
    return true;
  }

  const final = await waitForMessageStatus(runtime, request.message.messageId, [MessageStatus.Success, MessageStatus.Failed]);
  record.finalMessageStatus = final.metadata?.status;

  if (record.finalMessageStatus !== MessageStatus.Success) {
    record.status = "failed";
    record.error =
      `CCIP execution ${record.finalMessageStatus ?? "unknown"}: ccipReceive reverted on the destination ` +
      "(commonly an insufficient gas limit). Manually execute it from the CCIP explorer.";
    return false;
  }

  const { outcome, state, executionTxHash } = await resolveAdapterOutcome(
    runtime.dest,
    runtime.config.destAdapter,
    final,
    runtime.config.pollMs
  );
  record.notes.push(`adapter outcome=${outcome}; messageErrorCode=${state}`);
  if (executionTxHash) {
    record.notes.push(
      `destination execution tx: ${chainTxExplorerUrl(runtime.config.destChain.name, executionTxHash) ?? executionTxHash}`
    );
  }

  if (outcome === expected) {
    record.status = "passed";
    return true;
  }
  record.status = "failed";
  record.error = `expected adapter outcome ${expected} (MessageSucceeded/MessageFailed), observed ${outcome} (messageErrorCode=${state})`;
  return false;
}

export function hasSolanaEnv(): boolean {
  return !!(
    process.env.E2E_SOLANA_SOURCE_RPC_URL &&
    process.env.E2E_SOLANA_WALLET_SECRET_KEY &&
    process.env.E2E_SOLANA_SOURCE_ROUTER &&
    process.env.E2E_SOLANA_SOURCE_USDC_TOKEN_MINT
  );
}

export function hasRedeemEnv(): boolean {
  return !!process.env.E2E_SOURCE_VAULT_TOKEN_ADDRESS;
}

async function redeemPreflight(runtime: Runtime): Promise<string | undefined> {
  if (!hasRedeemEnv()) {
    return "missing E2E_SOURCE_VAULT_TOKEN_ADDRESS";
  }

  const token = getRedeemSourceVaultToken(runtime);
  try {
    await readErc20Decimals(runtime.source, token, runtime.config.sourceVaultTokenDecimals);
    return undefined;
  } catch (error) {
    return formatScenarioError(error);
  }
}

async function runEvmDepositHappy(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  const runtime = await createRuntime();
  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.depositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.depositMinimumOut);
    await logEvmTokenAmount("bridged USDC amount", runtime.source, runtime.config.sourceUsdcToken, amount);

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodePayload({
        target: runtime.config.destVault,
        beneficiary,
        minimumOut,
        ...getPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "succeeded", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runSvmDepositHappy(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  if (ctx.skipSolana || !hasSolanaEnv()) {
    record.notes.push("Solana env not configured or --skip-solana set");
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
  const runtime = await createSolanaRuntime();
  try {
    const amount = await parseTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.depositAmount);
    const { beneficiary, beneficiaryType } = getSolanaPayloadBeneficiary(runtime);
    const minimumOut = await parseTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.depositMinimumOut);

    const request = await sendMessageFromSolanaWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodeSvmPayload({
        target: runtime.config.destVault,
        beneficiary,
        beneficiaryType,
        minimumOut,
        ...getSolanaPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "succeeded", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroySolanaRuntime(runtime);
  }
}

async function runEvmRedeemHappy(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  const runtime = await createRuntime();
  const redeemIssue = await redeemPreflight(runtime);
  if (redeemIssue) {
    record.notes.push(redeemIssue);
    await destroyRuntime(runtime);
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
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

    const request = await sendMessageWithToken(runtime, {
      sourceToken: sourceVaultToken,
      amount,
      data: encodePayload({
        target: runtime.config.destVault,
        beneficiary,
        minimumOut,
        ...getPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "succeeded", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runSvmRedeemHappy(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  if (ctx.skipSolana || !hasSolanaEnv() || !process.env.E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT?.trim()) {
    record.notes.push("Solana redeem env not configured or --skip-solana set");
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
  const runtime = await createSolanaRuntime();
  try {
    const sourceVaultToken = getSolanaRedeemSourceToken(runtime);
    const amount = await parseTokenAmount(runtime.source, sourceVaultToken, runtime.config.redeemAmount);
    const { beneficiary, beneficiaryType } = getSolanaPayloadBeneficiary(runtime);
    const minimumOut = await parseTokenAmount(runtime.dest, runtime.config.destAssetToken, runtime.config.redeemMinimumOut);

    const request = await sendMessageFromSolanaWithToken(runtime, {
      sourceToken: sourceVaultToken,
      amount,
      data: encodeSvmPayload({
        target: runtime.config.destVault,
        beneficiary,
        beneficiaryType,
        minimumOut,
        ...getSolanaPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "succeeded", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroySolanaRuntime(runtime);
  }
}

async function runEvmDepositInvalidTarget(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  const runtime = await createRuntime();
  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.invalidDepositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.invalidDepositMinimumOut);

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodePayload({
        target: invalidTargetAddress(),
        beneficiary,
        minimumOut,
        ...getPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    if (getLocalRefundAddress(runtime)) {
      record.notes.push(`Local recovery: pnpm e2e:ccip recover-local ${request.message.messageId}`);
    }
    record.notes.push(`Cross-chain refund: pnpm e2e:ccip refund ${request.message.messageId}`);

    await settle(record, runtime, request, "failed", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runEvmDepositMinimumOutTooHigh(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  const runtime = await createRuntime();
  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.depositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, FAIL_DEPOSIT_MINIMUM_OUT);
    record.notes.push(`minimumOut=${FAIL_DEPOSIT_MINIMUM_OUT} (vault share units)`);

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodePayload({
        target: runtime.config.destVault,
        beneficiary,
        minimumOut,
        ...getPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "failed", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runEvmRedeemMinimumOutTooHigh(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  const runtime = await createRuntime();
  const redeemIssue = await redeemPreflight(runtime);
  if (redeemIssue) {
    record.notes.push(redeemIssue);
    await destroyRuntime(runtime);
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
  try {
    const beneficiary = getBeneficiary(runtime);
    const sourceVaultToken = getRedeemSourceVaultToken(runtime);
    const amount = await parseEvmTokenAmount(
      runtime.source,
      sourceVaultToken,
      runtime.config.redeemAmount,
      runtime.config.sourceVaultTokenDecimals
    );
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destAssetToken, FAIL_REDEEM_MINIMUM_OUT);
    record.notes.push(`minimumOut=${FAIL_REDEEM_MINIMUM_OUT} (underlying units)`);

    const request = await sendMessageWithToken(runtime, {
      sourceToken: sourceVaultToken,
      amount,
      data: encodePayload({
        target: runtime.config.destVault,
        beneficiary,
        minimumOut,
        ...getPayloadDeliveryOptions(runtime)
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    await settle(record, runtime, request, "failed", ctx.wait);
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runEvmCrossChainRefundFlow(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  if (!ctx.wait) {
    record.notes.push("requires --wait (multi-step flow)");
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
  const runtime = await createRuntime();
  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.invalidDepositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.invalidDepositMinimumOut);

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodePayload({
        target: invalidTargetAddress(),
        beneficiary,
        minimumOut,
        returnToSourceChain: runtime.config.returnToSourceChain,
        localRefundAddress: undefined
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    if (!(await settle(record, runtime, request, "failed", true))) {
      return finishRecord(record, startedAt);
    }
    // Reset so an error in the follow-up step is reported as a failure.
    record.status = "failed";

    const { fee, value, txHash, refundMessageId } = await refundFailedMessage(runtime, request.message.messageId);
    record.followUpTxHash = txHash;
    record.followUpTxExplorerUrl = chainTxExplorerUrl(runtime.config.destChain.name, txHash);
    record.notes.push(`refund fee estimate ${fee.toString()} wei; sent ${value.toString()} wei (excess returned)`);
    if (refundMessageId) {
      record.notes.push(`refund CCIP message: ${ccipExplorerUrl(refundMessageId)}`);
    }
    record.status = "passed";
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

async function runEvmLocalRecoveryFlow(ctx: ScenarioRunContext, def: ScenarioDef): Promise<ScenarioRecord> {
  const { record, startedAt } = startRecord(def);
  record.status = "skipped";

  if (!ctx.wait) {
    record.notes.push("requires --wait (multi-step flow)");
    return finishRecord(record, startedAt);
  }

  if (!process.env.E2E_LOCAL_REFUND_ADDRESS?.trim()) {
    record.notes.push("missing E2E_LOCAL_REFUND_ADDRESS");
    return finishRecord(record, startedAt);
  }

  record.status = "failed";
  const runtime = await createRuntime();
  try {
    const beneficiary = getBeneficiary(runtime);
    const amount = await parseEvmTokenAmount(runtime.source, runtime.config.sourceUsdcToken, runtime.config.invalidDepositAmount);
    const minimumOut = await parseEvmTokenAmount(runtime.dest, runtime.config.destVault, runtime.config.invalidDepositMinimumOut);
    const localRefundAddress = getLocalRefundAddress(runtime);
    record.notes.push(`localRefundAddress=${localRefundAddress}`);
    if (localRefundAddress !== runtime.destWallet.address) {
      // recoverFailedMessageLocally must be called by localRefundAddress; the suite signs with E2E_PRIVATE_KEY.
      record.error = `E2E_LOCAL_REFUND_ADDRESS (${localRefundAddress}) must equal the E2E_PRIVATE_KEY address (${runtime.destWallet.address}) for this scenario`;
      return finishRecord(record, startedAt);
    }

    const request = await sendMessageWithToken(runtime, {
      sourceToken: runtime.config.sourceUsdcToken,
      amount,
      data: encodePayload({
        target: invalidTargetAddress(),
        beneficiary,
        minimumOut,
        returnToSourceChain: runtime.config.returnToSourceChain,
        localRefundAddress
      })
    });

    annotateSend(record, request, runtime.config.sourceChain.name);
    if (!(await settle(record, runtime, request, "failed", true))) {
      return finishRecord(record, startedAt);
    }
    // Reset so an error in the follow-up step is reported as a failure.
    record.status = "failed";

    const { txHash } = await recoverFailedMessageLocally(runtime, request.message.messageId);
    record.followUpTxHash = txHash;
    record.followUpTxExplorerUrl = chainTxExplorerUrl(runtime.config.destChain.name, txHash);
    record.notes.push("recoverFailedMessageLocally confirmed on destination");
    record.status = "passed";
    return finishRecord(record, startedAt);
  } catch (error) {
    record.error = formatScenarioError(error);
    return finishRecord(record, startedAt);
  } finally {
    await destroyRuntime(runtime);
  }
}

export const SCENARIOS: ScenarioDef[] = [
  {
    id: "evm-deposit-happy",
    name: "EVM deposit (valid target, valid minimumOut)",
    category: "happy",
    family: "evm",
    profiles: ["ccip-v1", "happy", "all"],
    expectedOutcome: "CCIP message succeeds; adapter deposits USDC into vault and bridges/delivers output.",
    run: runEvmDepositHappy
  },
  {
    id: "svm-deposit-happy",
    name: "Solana deposit (valid target, valid minimumOut)",
    category: "happy",
    family: "svm",
    profiles: ["ccip-v1", "happy", "all"],
    requiresSolana: true,
    expectedOutcome: "CCIP message from Solana succeeds; adapter deposits on destination.",
    run: runSvmDepositHappy
  },
  {
    id: "evm-redeem-happy",
    name: "EVM redeem (valid target, valid minimumOut)",
    category: "happy",
    family: "evm",
    profiles: ["ccip-v1", "happy", "all"],
    requiresRedeemToken: true,
    expectedOutcome: "CCIP message succeeds; adapter redeems vault shares to underlying and bridges/delivers.",
    run: runEvmRedeemHappy
  },
  {
    id: "svm-redeem-happy",
    name: "Solana redeem (valid target, valid minimumOut)",
    category: "happy",
    family: "svm",
    profiles: ["ccip-v1", "happy", "all"],
    requiresSolana: true,
    expectedOutcome: "CCIP message from Solana succeeds; adapter redeems on destination.",
    run: runSvmRedeemHappy
  },
  {
    id: "evm-deposit-invalid-target",
    name: "EVM deposit with invalid vault target",
    category: "failure",
    family: "evm",
    profiles: ["ccip-v1", "failure", "all"],
    expectedOutcome: "Destination adapter marks message FAILED (InvalidTarget); inbound USDC remains recoverable.",
    run: runEvmDepositInvalidTarget
  },
  {
    id: "evm-deposit-minimum-out-too-high",
    name: "EVM deposit with minimumOut above achievable shares",
    category: "failure",
    family: "evm",
    profiles: ["ccip-v1", "failure", "all"],
    expectedOutcome: "Adapter reverts MinimumOutputNotMet; message marked FAILED on destination.",
    run: runEvmDepositMinimumOutTooHigh
  },
  {
    id: "evm-redeem-minimum-out-too-high",
    name: "EVM redeem with minimumOut above achievable underlying",
    category: "failure",
    family: "evm",
    profiles: ["ccip-v1", "failure", "all"],
    requiresRedeemToken: true,
    expectedOutcome: "Adapter reverts MinimumOutputNotMet on redeem; message marked FAILED.",
    run: runEvmRedeemMinimumOutTooHigh
  },
  {
    id: "evm-cross-chain-refund-flow",
    name: "EVM invalid target → wait FAILED → refundFailedMessage",
    category: "recovery",
    family: "multi",
    profiles: ["recovery", "all"],
    requiresWait: true,
    expectedOutcome: "Invalid-target message FAILED on destination, then refundFailedMessage bridges tokens back to source sender.",
    run: runEvmCrossChainRefundFlow
  },
  {
    id: "evm-local-recovery-flow",
    name: "EVM invalid target → wait FAILED → recoverFailedMessageLocally",
    category: "recovery",
    family: "multi",
    profiles: ["recovery", "all"],
    requiresWait: true,
    requiresLocalRefund: true,
    expectedOutcome: "Invalid-target message FAILED, then recoverFailedMessageLocally transfers inbound tokens to E2E_LOCAL_REFUND_ADDRESS.",
    run: runEvmLocalRecoveryFlow
  }
];

export function scenariosForProfile(profile: SuiteProfile): ScenarioDef[] {
  if (profile === "all") {
    return SCENARIOS;
  }
  return SCENARIOS.filter((scenario) => scenario.profiles.includes(profile));
}
