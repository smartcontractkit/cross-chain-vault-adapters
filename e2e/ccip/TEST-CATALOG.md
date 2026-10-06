# CCIP adapter E2E test catalog

This is the checklist for live integration validation of `CrossChainERC4626Adapter` from EVM (Ethereum Virtual Machine) and Solana (SVM) source chains. Setup, environment
variables and the recovery commands are covered in [`README.md`](README.md). Run every command from the repo root.

Some items apply only to CCIP v2 lanes, whose OnRamp accepts GenericExtraArgsV3: CCV (Cross-Chain Verifier)
policy, the inbound finality bitmask, V3 return-lane finality, and `E2E_OUTBOUND_REQUESTED_FINALITY`. They are listed separately in
[section 6](#6-genericextraargsv3--ccv-lanes-only) and are not in the default `ccip-v1` suite profile.

## Quick run

```bash
# List all automated scenario ids (no env or network needed)
pnpm e2e:ccip suite --list

# Default profile (ccip-v1): send happy + failure scenarios; report under e2e/ccip/reports/
pnpm e2e:ccip suite

# Also wait for delivery and verify each adapter outcome (slower)
pnpm e2e:ccip suite --wait

# Multi-step refund / local recovery (requires --wait)
pnpm e2e:ccip suite --profile=recovery --wait
```

Each report entry includes the **send tx hash**, **message ID**, **CCIP Explorer link**
(`https://ccip.chain.link/msg/<id>`), a block explorer link where known, and with `--wait` the final CCIP status
and the adapter outcome.

## How outcomes are judged

`ccipReceive` catches every revert from `processMessage`. A business-logic failure therefore still shows as
**`SUCCESS`** on the CCIP Explorer. The adapter emits `MessageFailed(messageId)` and sets
`messageErrorCode(messageId)` to `BASIC` (1), keeping the tokens for refund or local recovery.

With `--wait`, the suite checks two things:

1. **CCIP reaches `SUCCESS`.** `FAILED` means `ccipReceive` itself reverted (usually too little gas) and fails
   the scenario.
2. **The adapter outcome matches the scenario.** It is read from the `MessageSucceeded` / `MessageFailed` event
   in the destination execution receipt, falling back to `messageErrorCode`:
   - happy scenarios expect `MessageSucceeded`;
   - failure scenarios expect `MessageFailed`.

Without `--wait`, scenarios are reported as `SENT`. Check them manually as described in
[Tracking a message](README.md#tracking-a-message).

---

## 1. Happy path (required)

| # | Scenario | Source | Automated id | Notes |
|---|----------|--------|--------------|-------|
| 1.1 | Deposit into vault | EVM | `evm-deposit-happy` | Source token, then adapter `deposit`, then shares delivered or returned per `E2E_RETURN_TO_SOURCE_CHAIN` |
| 1.2 | Deposit into vault | Solana (SVM) | `svm-deposit-happy` | Same 128-byte payload; requires the Solana env (skipped otherwise) |
| 1.3 | Redeem from vault | EVM | `evm-redeem-happy` | Requires `E2E_SOURCE_VAULT_TOKEN_ADDRESS` (bridged shares on the source; skipped otherwise) |
| 1.4 | Redeem from vault | Solana (SVM) | `svm-redeem-happy` | Requires `E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT` (skipped otherwise) |

**Manual verification after delivery:**

- With `returnToSourceChain=false`, the beneficiary receives shares (deposit) or underlying (redeem) on the
  destination (`LocalTokenDelivered`).
- With `returnToSourceChain=true`, the adapter emits `MessageSent` and a second CCIP message delivers the output
  on the source chain.

---

## 2. Payload / business-logic failures (required)

In all of these the CCIP Explorer shows `SUCCESS`, and the adapter emits `MessageFailed` and holds the inbound
token.

| # | Scenario | Automated id | Revert inside `processMessage` |
|---|----------|--------------|-------------------|
| 2.1 | Unregistered vault `target` (`0x…01`) | `evm-deposit-invalid-target` | `InvalidTarget` |
| 2.2 | `minimumOut` too high (deposit) | `evm-deposit-minimum-out-too-high` | `MinimumOutputNotMet` |
| 2.3 | `minimumOut` too high (redeem) | `evm-redeem-minimum-out-too-high` | `MinimumOutputNotMet` |

`pnpm e2e:ccip refund-send` sends the same message as 2.1 on its own.

**Not automated (manual):**

| # | Scenario | How to test | Expected revert (caught, `MessageFailed`) |
|---|----------|-------------|----------|
| 2.4 | Wrong inbound token (neither asset nor share) | Send a vault-unrelated CCIP token with a valid payload | `InvalidTargetToken` |
| 2.5 | Disabled target | `setTargetEnabled(vault, false)`, then a valid send | `InvalidTarget` |
| 2.6 | Deposits disabled | `setProcessingEnabled(false, true)`, then a deposit send | `DepositsDisabled` |
| 2.7 | Redeems disabled | `setProcessingEnabled(true, false)`, then a redeem send | `RedeemsDisabled` |
| 2.8 | Invalid payload length | `message.data` that is not exactly 128 bytes | `InvalidPayloadLength` (no `localRefundAddress` is stored) |
| 2.9 | Zero bridged amount | Send with `amount = 0` (if the lane allows it) | `AmountIsZero` |
| 2.10 | Local delivery to a non-EVM beneficiary | `returnToSourceChain=false` with non-zero upper 96 bits in `beneficiary` | `InvalidEVMAddress` |
| 2.11 | Unconfigured source chain | `setChainType(sourceSelector, 0)`, then a valid send | `InvalidChain` |

---

## 3. Failed-message recovery (required)

| # | Scenario | Automated id | Requires |
|---|----------|--------------|----------|
| 3.1 | Cross-chain refund | `evm-cross-chain-refund-flow` | `--profile=recovery --wait`; destination native balance for gas and the refund CCIP fee |
| 3.2 | Local recovery | `evm-local-recovery-flow` | `--profile=recovery --wait`; `E2E_LOCAL_REFUND_ADDRESS` equal to the `E2E_PRIVATE_KEY` address |

In 3.1 the suite sends an invalid-target message and waits for `MessageFailed`, then calls `refundFailedMessage`.
It records the refund transaction and the refund leg's CCIP message id.

In 3.2 it sends the same failing message with `localRefundAddress` packed into the payload, then calls
`recoverFailedMessageLocally`.

**Manual follow-ups:**

| # | Scenario | Command / check |
|---|----------|---------|
| 3.3 | Refund an existing failed message | `pnpm e2e:ccip refund <message-id>` |
| 3.4 | Locally recover an existing failed message | `pnpm e2e:ccip recover-local <message-id>` |
| 3.5 | The two paths are mutually exclusive | After 3.1 or 3.2, `messageErrorCode` is `2` (`RESOLVED`) and the other path reverts `MessageNotFailed` |
| 3.6 | Refund leg arrives | Track the refund CCIP message printed by `refund`; the original sender receives the tokens on the source chain |
| 3.7 | Wrong local caller | `recover-local` from a key other than `localRefundAddress`: the script refuses; a direct call reverts `UnauthorizedLocalRefund` |
| 3.8 | No local refund address | `recover-local` on a message sent without `E2E_LOCAL_REFUND_ADDRESS`: `checkLocalRecoveryEligibility` returns `canRecover=false` (a direct call reverts `NoLocalRefundAddress`) |

---

## 4. Delivery mode variants (recommended)

| # | Scenario | Config | Verify |
|---|----------|--------|--------|
| 4.1 | Local delivery (no return bridge) | `E2E_RETURN_TO_SOURCE_CHAIN=false`; optionally `E2E_DEST_BENEFICIARY` | `LocalTokenDelivered`; tokens land with the destination beneficiary |
| 4.2 | Return to source (EVM beneficiary) | `E2E_RETURN_TO_SOURCE_CHAIN=true`; adapter funded with native; return-lane format set on CCIP v2 lanes | `MessageSent`; the return CCIP message delivers on the source chain |
| 4.3 | Return to source (Solana beneficiary) | `E2E_SOLANA_RETURN_TO_SOURCE_CHAIN=true`; optionally `E2E_SOLANA_BENEFICIARY` | SVM-encoded beneficiary on the return leg |
| 4.4 | Local recovery address in the payload | Set `E2E_LOCAL_REFUND_ADDRESS` on failure sends | `getFailedMessageRecord(messageId).localRefundAddress` is populated |

---

## 5. Prerequisites / setup (before the suite)

See [Prerequisites](README.md#prerequisites) for details.

| # | Check |
|---|--------|
| 5.1 | The adapter is deployed and verified on the destination chain |
| 5.2 | `enabledTargets(vault)`, `depositsEnabled()` and `redeemsEnabled()` are all true |
| 5.3 | Every source chain is configured on the adapter: `chains(selector)` is non-zero (set with `setChainType`) |
| 5.4 | The adapter holds native token on the destination if you use `returnToSourceChain=true` |
| 5.5 | The source wallet holds the source token, bridged vault shares (for redeem), and native for CCIP fees |
| 5.6 | The destination wallet holds native for refund and recovery gas and the refund fee |
| 5.7 | The Solana wallet is funded for SVM scenarios |

---

## 6. GenericExtraArgsV3 / CCV lanes only

These are CCIP v2 features and are not in the `ccip-v1` profile or automated. Test them manually, only on lanes
whose OnRamp and OffRamp support them.

- Required and optional verifier configuration: `setCCVsConfig`, `getCCVsAndFinalityConfig`
- The inbound finality bitmask: `setInboundFinality`, `inboundFinality`
- V3 return lanes: `setEvmReturnLaneFormat(destSelector, GENERIC_EXTRA_ARGS_V3_BASIC)`, then
  `setEvmReturnRequestedFinality(destSelector, token, finality)` for each returned token
- The outbound GenericExtraArgsV3 encoding path in the harness: `E2E_OUTBOUND_REQUESTED_FINALITY`

---

## 7. Optional / ops scenarios

| # | Scenario | How |
|---|----------|--------|
| 7.1 | Bridge vault tokens only (no adapter) | `pnpm e2e:ccip bridge-vault` |
| 7.2 | Fee accrual on a return-to-source flow | Manual: `setAssetFee(sourceSelector, bridgedToken, fee)`, then a happy send with `returnToSourceChain=true`; check `collectedFees(asset)` |
| 7.3 | `recoverNative` / `withdrawFee` | Admin operations on the adapter |

---

## Env vars used by the failure scenarios

| Var | Default | Purpose |
|-----|---------|---------|
| `E2E_SUITE_FAIL_DEPOSIT_MINIMUM_OUT` | `999999999` | Unreachable deposit `minimumOut` (vault-share units) |
| `E2E_SUITE_FAIL_REDEEM_MINIMUM_OUT` | `999999999` | Unreachable redeem `minimumOut` (underlying units) |
| `E2E_INVALID_DEPOSIT_USDC_AMOUNT` | deposit amount, then `1` | Amount for invalid-target and recovery sends |
| `E2E_INVALID_DEPOSIT_MINIMUM_OUT` | deposit `minimumOut`, then `1` | `minimumOut` for those sends |
| `E2E_LOCAL_REFUND_ADDRESS` | unset | Packed into `deliveryAndRefund`; enables local recovery |
