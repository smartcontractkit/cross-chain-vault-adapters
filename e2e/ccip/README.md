# CCIP adapter E2E harness

Live-network scripts for [`CrossChainERC4626Adapter`](../../src/ccip/CrossChainERC4626Adapter.sol), built on
[`@chainlink/ccip-sdk`](https://www.npmjs.com/package/@chainlink/ccip-sdk) and ethers. They send real CCIP
messages on public testnets to a deployed adapter and help you recover failed messages. They are integration
checks, not mocked unit tests. The Foundry tests under `test/ccip/` cover contract logic.

**These scripts send real transactions and spend real (testnet) funds. Use throwaway testnet wallets only.**

The default lane is Avalanche Fuji (`avalanche-testnet-fuji`) to Ethereum Sepolia (`ethereum-testnet-sepolia`).
Any CCIP lane between two EVM (Ethereum Virtual Machine) chains works. Solana devnet (SVM, Solana Virtual Machine) is supported as a source chain.

- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Environment variables](#environment-variables)
- [Scripts](#scripts)
- [Tracking a message](#tracking-a-message)
- [Recovering a failed message](#recovering-a-failed-message)
- [Suite runner](#suite-runner)
- [Payload encoding](#payload-encoding)
- [Troubleshooting](#troubleshooting)

For the full manual and automated checklist, see [`TEST-CATALOG.md`](TEST-CATALOG.md).

## Prerequisites

1. **Tooling.** Node.js 20.11 or later and pnpm 10 or later. Run `pnpm install` once at the repo root; it installs this
   workspace package too.
2. **A deployed, configured adapter on the destination chain.** Follow the
   [deployment guide](../../docs/ccip/cross-chain-erc4626-adapter-deployment-guide.md) and the
   [operator guide](../../docs/ccip/cross-chain-erc4626-adapter-operator-guide.md). At minimum:
   - the vault is enabled with `setTargetEnabled(vault, true)`;
   - deposits and redeems are enabled with `setProcessingEnabled(true, true)`;
   - every source chain is configured with `setChainType(sourceSelector, 1)` for EVM or `2` for SVM.
   - If you send with `E2E_RETURN_TO_SOURCE_CHAIN=true`, the adapter must hold native token, because it pays
     the return-leg CCIP fee from its own balance. CCIP v1 return lanes need no further setup; on a CCIP v2
     return lane, set `setEvmReturnLaneFormat` (and optionally `setEvmReturnRequestedFinality`), for example with
     `pnpm ccip:configure`.

   `pnpm ccip:check` reports all of these.
3. **A CCIP lane that carries your tokens.** The source token (for example CCIP test USDC) must be a CCIP-enabled
   token on the source-to-destination lane, and it must arrive on the destination as the vault's `asset()`.
   To test redeems, the vault share must also be CCIP-enabled on the lane. Check lanes, routers and tokens in the
   [CCIP directory](https://docs.chain.link/ccip/directory/testnet).
4. **Funded testnet wallets.**
   - EVM wallet (`E2E_PRIVATE_KEY`):
     - on the source chain: native gas plus CCIP fees, the source token for deposits, and bridged vault shares
       for redeems;
     - on the destination chain: native gas for refund and local recovery, plus the refund CCIP fee (the caller of
       `refundFailedMessage` pays it).
   - The adapter: native token on the destination chain for return legs (see above).
   - Solana wallet (optional, `E2E_SOLANA_WALLET_SECRET_KEY`): devnet SOL and the SPL mints you bridge.

## Setup

Run all commands from the **repo root**. The `.env` file lives in `e2e/ccip/`:

```bash
pnpm install
cp e2e/ccip/.env.example e2e/ccip/.env
# edit e2e/ccip/.env
pnpm e2e:ccip typecheck
pnpm e2e:ccip suite --list      # needs no env or network
```

The scripts always load `e2e/ccip/.env`, regardless of the working directory. Values in it override
variables already exported in your shell. `.env` is gitignored; never commit it.

Every script checks its configuration before touching the network. If a variable is missing or malformed, the
script exits with code 1 and one line naming every missing variable, for example:

```text
configuration error: missing required env var(s) for EVM adapter scripts: E2E_SOURCE_RPC_URL, E2E_DEST_RPC_URL, ...
```

## Environment variables

Every variable the code reads is listed in [`.env.example`](.env.example), with a comment. Amounts are in
human units and are parsed with each token's on-chain `decimals()`.

### Lane and signer

| Variable | Required by | Default | Purpose |
|---|---|---|---|
| `E2E_SOURCE_CHAIN` | EVM scripts | `avalanche-testnet-fuji` | Source chain name, chain id or selector, as known to the CCIP SDK. |
| `E2E_DEST_CHAIN` | all | `ethereum-testnet-sepolia` | Destination chain. It must be EVM and must differ from the source. |
| `E2E_SOURCE_RPC_URL` | EVM scripts | none | Source JSON-RPC endpoint. |
| `E2E_DEST_RPC_URL` | all | none | Destination JSON-RPC endpoint. |
| `E2E_PRIVATE_KEY` | EVM scripts, `refund`, `recover-local` | none | 32-byte hex key. It signs on both chains: sends on the source, recovery on the destination. |
| `E2E_SOURCE_ROUTER` | EVM scripts | Fuji router in `.env.example` | CCIP Router on the source chain. |

### Adapter and tokens

| Variable | Required by | Default | Purpose |
|---|---|---|---|
| `E2E_DEST_ADAPTER` | adapter scripts, `refund`, `recover-local` | none | `CrossChainERC4626Adapter` on the destination chain; the CCIP receiver. |
| `E2E_DEST_VAULT` | adapter scripts | none | ERC-4626 vault on the destination chain. It is the payload `target` and must be enabled on the adapter. |
| `E2E_DEST_ASSET_TOKEN_ADDRESS` | adapter scripts | none | The vault's `asset()` on the destination chain. Its decimals are used to parse the redeem `minimumOut`. |
| `E2E_SOURCE_USDC_TOKEN_ADDRESS` | EVM adapter scripts | none | Source token bridged by deposits. It arrives on the destination as the vault asset. |
| `E2E_SOURCE_VAULT_TOKEN_ADDRESS` | `redeem`, `bridge-vault` | none | The bridged vault share on the source chain. Redeem scenarios are skipped when it is unset. |
| `E2E_SOURCE_VAULT_TOKEN_DECIMALS` | optional | read on-chain | Decimals override for a bridged share token that has no readable `decimals()`. |

### Payload options

| Variable | Default | Purpose |
|---|---|---|
| `E2E_DEST_BENEFICIARY` | signer address | Payload `beneficiary` (EVM). Required by `bridge-vault`, and by Solana local delivery. |
| `E2E_RETURN_TO_SOURCE_CHAIN` | `true` (`.env.example` sets `false`) | Bit 0 of `deliveryAndRefund`. `false` delivers the vault output to the beneficiary on the destination chain. `true` bridges it back to the beneficiary on the source chain. |
| `E2E_LOCAL_REFUND_ADDRESS` | none | Bits 1..160 of `deliveryAndRefund`: the destination-chain address that may call `recoverFailedMessageLocally`. If it is empty, only the cross-chain refund can recover a failed message. |

### Amounts

| Variable | Default | Purpose |
|---|---|---|
| `E2E_DEPOSIT_USDC_AMOUNT` | `.1` | Deposit amount (source token). |
| `E2E_DEPOSIT_MINIMUM_OUT` | `0` | Deposit `minimumOut`, in vault-share units. |
| `E2E_INVALID_DEPOSIT_USDC_AMOUNT` | deposit amount, then `1` | Amount for `refund-send` and the failure and recovery scenarios. |
| `E2E_INVALID_DEPOSIT_MINIMUM_OUT` | deposit `minimumOut`, then `1` | `minimumOut` for those sends. |
| `E2E_REDEEM_VAULT_AMOUNT` | `1` | Vault shares to redeem. |
| `E2E_REDEEM_MINIMUM_OUT` | `0` | Redeem `minimumOut`, in underlying-asset units. |
| `E2E_SUITE_FAIL_DEPOSIT_MINIMUM_OUT` | `999999999` | Unreachable deposit `minimumOut`, for `evm-deposit-minimum-out-too-high`. |
| `E2E_SUITE_FAIL_REDEEM_MINIMUM_OUT` | `999999999` | Unreachable redeem `minimumOut`, for `evm-redeem-minimum-out-too-high`. |

### Gas, fees and polling

| Variable | Default | Purpose |
|---|---|---|
| `E2E_CCIP_GAS_LIMIT` | SDK estimate | Destination execution gas for adapter sends. If unset, the scripts use `estimateReceiveExecution` multiplied by the next variable. |
| `E2E_CCIP_GAS_MULTIPLIER_BPS` | `12000` | Safety margin on the SDK gas estimate. |
| `E2E_REFUND_FEE_MULTIPLIER_BPS` | `12000` | The refund sends `msg.value = estimateRefundFee * bps / 10000`. The adapter returns any excess. |
| `E2E_STATUS_POLL_MS` | `15000` | CCIP API poll interval for `suite --wait`. |
| `E2E_STATUS_TIMEOUT_MS` | `1800000` | Timeout per message for `suite --wait`. |
| `E2E_OUTBOUND_REQUESTED_FINALITY` | unset | Only for CCIP v2 lanes whose OnRamp accepts GenericExtraArgsV3. A 4-byte `requestedFinality`; when set, EVM sends call `Router.ccipSend` with Solidity-encoded GenericExtraArgsV3. Leave it unset on CCIP v1 lanes. `0x00000000` counts as unset. |
| `E2E_REFUND_MESSAGE_ID` | none | Fallback message id for `refund` and `recover-local` when no argument is given. |
| `E2E_BRIDGE_VAULT_AMOUNT` | redeem amount, then `1` | Amount for `bridge-vault`. |
| `E2E_BRIDGE_CCIP_GAS_LIMIT` | `0` | Destination gas for `bridge-vault`. It is a tokens-only send with no receiver callback. |

### Solana source

The Solana scripts also use `E2E_DEST_RPC_URL`, `E2E_DEST_CHAIN`, `E2E_DEST_ADAPTER`, `E2E_DEST_VAULT`,
`E2E_DEST_ASSET_TOKEN_ADDRESS`, `E2E_LOCAL_REFUND_ADDRESS`, and the gas and polling variables above.

| Variable | Default | Purpose |
|---|---|---|
| `E2E_SOLANA_SOURCE_CHAIN` | `solana-devnet` | SVM source chain. |
| `E2E_SOLANA_SOURCE_RPC_URL` | none (required) | Solana RPC endpoint. |
| `E2E_SOLANA_SOURCE_ROUTER` | devnet router in `.env.example` | CCIP Router program. |
| `E2E_SOLANA_WALLET_SECRET_KEY` | none (required) | Keypair file path (a leading `~` expands to your home directory), base58 secret key, or JSON byte array. |
| `E2E_SOLANA_SOURCE_USDC_TOKEN_MINT` | none (required) | SPL mint bridged by `deposit-solana`. |
| `E2E_SOLANA_SOURCE_VUSDC_TOKEN_MINT` | none | Bridged vault-share mint. Required by `redeem-solana`. |
| `E2E_SOLANA_BENEFICIARY` | wallet pubkey | Solana beneficiary when the output returns to Solana. |
| `E2E_SOLANA_RETURN_TO_SOURCE_CHAIN` | `E2E_RETURN_TO_SOURCE_CHAIN`, then `true` | `false` delivers on the destination chain to `E2E_DEST_BENEFICIARY`, which is then required. |
| `E2E_SOLANA_DEPOSIT_USDC_AMOUNT`, `E2E_SOLANA_DEPOSIT_MINIMUM_OUT`, `E2E_SOLANA_REDEEM_VUSDC_AMOUNT`, `E2E_SOLANA_REDEEM_MINIMUM_OUT` | matching EVM variable, then `1` | Solana amounts. |

## Scripts

Run each script as `pnpm e2e:ccip <script> [args]` from the repo root. The scripts are defined in
[`package.json`](package.json).

| Script | File | What it does |
|---|---|---|
| `deposit` | `deposit-valid.ts` | Bridges `E2E_DEPOSIT_USDC_AMOUNT` of the source token to the adapter with a valid payload (`target = E2E_DEST_VAULT`). The adapter deposits it and delivers or returns the shares. |
| `redeem` | `redeem-valid.ts` | Bridges `E2E_REDEEM_VAULT_AMOUNT` vault shares to the adapter. Because the input token is the vault share, the adapter takes the redeem path and delivers or returns the underlying. |
| `refund-send` | `deposit-invalid-refund.ts` | Same as `deposit`, but with an unregistered `target` (`0x…01`), so the adapter records the message as failed. Use it to test recovery. |
| `refund <message-id>` | `refund-message.ts` | Cross-chain refund of a failed message. See [Recovering a failed message](#recovering-a-failed-message). |
| `recover-local <message-id>` | `recover-local-message.ts` | Local recovery of a failed message on the destination chain. |
| `deposit-solana` | `solana-deposit.ts` | Solana-source deposit. It uses the same 128-byte payload as the EVM scripts. |
| `redeem-solana` | `solana-redeem.ts` | Solana-source redeem. |
| `bridge-vault` | `bridge-vault-token.ts` | Tokens-only CCIP send of `E2E_SOURCE_VAULT_TOKEN_ADDRESS` to `E2E_DEST_BENEFICIARY`, with empty `data` and no adapter involved. Use it to move vault shares between chains. |
| `suite [flags]` | `run-suite.ts` | Runs a set of scenarios and writes a Markdown report. See [Suite runner](#suite-runner). |
| `typecheck` | | Runs `tsc --noEmit` over the harness. |

The send scripts return once the source transaction confirms; they do not wait for delivery. A successful send
prints output like this:

```text
bridged USDC amount: 0.1 USDC
estimated CCIP receive gas: 187000; applying multiplier 12000 bps -> 224400
sending token 0x… amount 100000 with gasLimit 224400
send tx hash: 0x…
message id: 0x…
track: https://ccip.chain.link/msg/0x…
```

`deposit-solana` also prints a JSON "CCIP SDK support snippet", with transaction-size diagnostics, before sending.

## Tracking a message

Open `https://ccip.chain.link/msg/<message-id>` (the `track:` line) in the CCIP Explorer. A message moves
through `SENT` / `SOURCE_FINALIZED` / `COMMITTED` and then reaches `SUCCESS` or `FAILED`. On testnets this
usually takes 5 to 30 minutes, depending on source-chain finality.

**CCIP status is not the adapter outcome.** `ccipReceive` wraps processing in `try/catch`. Business-logic
failures such as `InvalidTarget`, `MinimumOutputNotMet`, `DepositsDisabled` or `InvalidTargetToken` therefore
do **not** revert the CCIP execution. In those cases:

- the CCIP Explorer shows **`SUCCESS`**;
- the adapter emits **`MessageFailed(messageId)`** instead of `MessageSucceeded(messageId)`;
- the adapter keeps the inbound tokens and sets `messageErrorCode(messageId)` to `1` (`BASIC`).

To check the adapter state:

```bash
cast call "$E2E_DEST_ADAPTER" "messageErrorCode(bytes32)(uint8)" <message-id> --rpc-url "$E2E_DEST_RPC_URL"
# 0 = NONE (processed, or not executed yet), 1 = BASIC (failed, recoverable), 2 = RESOLVED (refunded / recovered)
```

A CCIP **`FAILED`** status means `ccipReceive` itself reverted, most often because the destination gas limit was
too low. The adapter never saw the message. Manually execute it from the CCIP Explorer, with a higher gas limit if
needed.

`suite --wait` does all of this automatically. It waits for a terminal CCIP status, then reads the adapter's
`MessageSucceeded` / `MessageFailed` event from the execution receipt, falling back to `messageErrorCode`.

## Recovering a failed message

A message with `messageErrorCode == BASIC` can be recovered in one of two ways. Whichever succeeds first sets
the code to `RESOLVED`, and after that the other path reverts with `MessageNotFailed`.

### Cross-chain refund

```bash
pnpm e2e:ccip refund <message-id>
```

- This script needs only `E2E_DEST_RPC_URL`, `E2E_PRIVATE_KEY` and `E2E_DEST_ADAPTER`.
- It calls `refundFailedMessage(messageId)`, which bridges the inbound tokens back to the original sender on the
  source chain. Anyone can call it: the recipient is taken from the stored message, not from the caller.
- Before sending, the script checks `messageErrorCode` and `checkRefundEligibility`.
- It pays `estimateRefundFee` padded by `E2E_REFUND_FEE_MULTIPLIER_BPS`. The adapter refunds the unused part.
- It prints the refund transaction and the refund leg's CCIP message id and Explorer link. Track that second
  message to see the tokens arrive on the source chain.

### Local recovery

```bash
pnpm e2e:ccip recover-local <message-id>
```

- Recovery is possible only if the original payload had a non-zero `localRefundAddress`. Set
  `E2E_LOCAL_REFUND_ADDRESS` **before** sending.
- The transaction must be signed by that address, so `E2E_PRIVATE_KEY` must be its key.
- The script checks `checkLocalRecoveryEligibility` and the signer, then calls
  `recoverFailedMessageLocally(messageId)`. That call transfers the inbound tokens to `localRefundAddress` on the
  destination chain and needs no CCIP fee.

A typical recovery test:

```bash
pnpm e2e:ccip refund-send        # prints the message id and the follow-up commands
# wait until the Explorer shows SUCCESS and messageErrorCode == 1
pnpm e2e:ccip refund <message-id>        # or: pnpm e2e:ccip recover-local <message-id>
```

The message id can also come from `E2E_REFUND_MESSAGE_ID` instead of the argument.

## Suite runner

```bash
pnpm e2e:ccip suite                                   # profile ccip-v1: send happy + failure scenarios, no waiting
pnpm e2e:ccip suite --wait                            # also wait for delivery and verify each adapter outcome
pnpm e2e:ccip suite --profile=recovery --wait         # send, wait for the adapter failure, then refund / recover
pnpm e2e:ccip suite --only=evm-deposit-happy,evm-deposit-invalid-target --wait
pnpm e2e:ccip suite --skip-solana
pnpm e2e:ccip suite --list                            # scenario catalog; needs no env or network
pnpm e2e:ccip suite --help
```

| Profile | Scenarios |
|---|---|
| `ccip-v1` (default) | every happy and failure scenario |
| `happy` | EVM and Solana deposit and redeem |
| `failure` | invalid target, and `minimumOut` too high on deposit and redeem |
| `recovery` | `evm-cross-chain-refund-flow`, `evm-local-recovery-flow` (need `--wait`) |
| `all` | everything |

- Without `--wait`, each scenario is reported as `SENT` once its source transaction confirms.
- With `--wait`, each scenario is `PASSED` or `FAILED` against its expected adapter outcome:
  - happy scenarios expect `MessageSucceeded`;
  - failure scenarios expect `MessageFailed`.
- A scenario is `SKIPPED` when its prerequisites are missing:
  - Solana env or redeem token not configured;
  - `--wait` not given for recovery scenarios;
  - `E2E_LOCAL_REFUND_ADDRESS` not set for local recovery.
- `--only` selects scenarios within the chosen profile; use `--profile=all` to pick recovery scenarios by id.
- The suite exits non-zero if any scenario failed.

Each run writes `e2e/ccip/reports/suite-<timestamp>.md` (gitignored). For every scenario, the report
records the send transaction, message id, CCIP Explorer link, final CCIP status, adapter outcome, and any
follow-up transaction. The console prints the same information:

```text
[SENT] evm-deposit-happy: EVM deposit (valid target, valid minimumOut)
  message id: 0x…
  ccip explorer: https://ccip.chain.link/msg/0x…
  send tx: 0x…
  send tx explorer: https://testnet.snowtrace.io/tx/0x…
...
Passed=0 Sent=3 Failed=0 Skipped=4
```

[`TEST-CATALOG.md`](TEST-CATALOG.md) maps every scenario id to what it checks, and lists the manual checks.

## Payload encoding

`message.data` is `abi.encode` of the adapter's `Payload` struct. It is exactly 128 bytes for both EVM and SVM
sources (`CCIP_MESSAGE_PAYLOAD_LENGTH`):

```solidity
(address target, bytes32 beneficiary, uint256 minimumOut, uint256 deliveryAndRefund)
```

- `beneficiary`:
  - a left-padded EVM address for local delivery, or when returning to an EVM source;
  - the raw 32-byte Solana pubkey when returning to Solana.
- `deliveryAndRefund = (uint160(localRefundAddress) << 1) | (returnToSourceChain ? 1 : 0)`. When decoding, the
  adapter reads bit 0 and bits 1..160 and ignores bits 161..255.

`encodePayload` and `packDeliveryAndRefund` in [`shared.ts`](shared.ts) implement this.

Return-leg CCIP `extraArgs` are not part of the payload. The adapter builds them from its admin configuration
(`setEvmReturnLaneFormat` per destination lane, `setEvmReturnRequestedFinality` per lane and bridged token). The
function signatures used by the harness are in [`abis.ts`](abis.ts) and match the compiled adapter ABI.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `configuration error: ...` | A variable is missing or malformed. The message names it. |
| `insufficient native balance on source chain` | Fund the source wallet. CCIP fees on Fuji can exceed 0.35 AVAX per message. |
| `router getFee/ccipSend reverted 0x5247fdce` | The lane rejected the `extraArgs`. Unset `E2E_OUTBOUND_REQUESTED_FINALITY` on CCIP v1 lanes. |
| `token metadata unavailable (symbol/decimals)` on redeem | Set `E2E_SOURCE_VAULT_TOKEN_DECIMALS`, and check that `E2E_SOURCE_VAULT_TOKEN_ADDRESS` is the bridged share. |
| `... not configured in registry` | The token has no CCIP pool on this lane. Redeem needs vault shares that were bridged to the source chain first. |
| Explorer shows `SUCCESS` but nothing arrived | The adapter recorded a failure (`MessageFailed`). Check `messageErrorCode` and recover the message. |
| Explorer shows `FAILED` | `ccipReceive` reverted, usually from too little gas. Manually execute it from the Explorer; raise `E2E_CCIP_GAS_LIMIT` / `E2E_CCIP_GAS_MULTIPLIER_BPS` for future sends. |
| `bigint: Failed to load bindings, pure JS will be used` | A harmless notice from a `@solana/web3.js` dependency. |
