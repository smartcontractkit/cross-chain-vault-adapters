# Cross-chain ERC-4626 adapter user journey

This document describes the full user journey for `CrossChainERC4626Adapter.sol`, assuming the adapter has already been deployed and configured correctly. Deployment options are in the [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md); ongoing operation is in the [operator guide](cross-chain-erc4626-adapter-operator-guide.md). EVM means Ethereum Virtual Machine chains and SVM means Solana Virtual Machine chains.

## Preconditions

Before a user can use the adapter successfully, the following must already be configured:

- the source chain selector must be enabled
- the vault target contract must be enabled
- deposit and/or redeem processing must be enabled
- the adapter must hold enough native gas token if it needs to bridge outputs back to the source chain
- any desired per-destination asset fee entries (`assetFees`) must already be configured for return-leg flows (they approximate the native CCIP cost in asset units, and operators retune them as quotes and prices move)
- on CCIP v2 lanes, any desired CCV (Cross-Chain Verifier) and inbound finality policy must already be configured
- for EVM return legs, the return-lane `extraArgs` format must match the lane: `GenericExtraArgsV2` (the default) on CCIP v1 lanes, `GenericExtraArgsV3` with optional finality on CCIP v2 lanes; see the [operator guide](cross-chain-erc4626-adapter-operator-guide.md#ccip-stack-version-and-return-leg-extraargs-evm)

## Payload expectations

The source-side sender should compose a CCIP message that includes exactly one bridged token and a payload.

Inbound payload (EVM and SVM): ABI-encode the tuple `(address target, bytes32 beneficiary, uint256 minimumOut, uint256 deliveryAndRefund)`. The encoded length must be exactly 128 bytes (four 32-byte words). The same tuple is used regardless of whether `chains[sourceChainSelector]` is EVM or SVM; the chain type only affects outbound return encoding (EVM `receiver` vs Solana token receiver and SVM `extraArgs`). This compact shape keeps Solana `ccipSend` transactions under the network transaction size cap.

`deliveryAndRefund` packing: bit 0 = `returnToSourceChain`; bits 1..160 = `localRefundAddress` on the destination EVM chain (`address(0)` disables local recovery). Encode as `(uint256(uint160(localRefundAddress)) << 1) | (returnToSourceChain ? 1 : 0)`.

Validate the payload before sending: once tokens are bridged, a bad payload cannot be corrected. If the payload is not exactly 128 bytes, or `localRefundAddress` is zero, local recovery is unavailable and a failed message can only be refunded cross-chain.

Return-leg CCIP `extraArgs` are not taken from the message. For EVM return destinations, operators choose `GenericExtraArgsV2` (CCIP v1) or `GenericExtraArgsV3` (CCIP v2) per destination selector using `setEvmReturnLaneFormat`, and on V3 lanes set `requestedFinality` per (destination selector, bridged token) using `setEvmReturnRequestedFinality`. For SVM, the adapter uses its fixed Solana `extraArgs` layout.

## Full user journey

### 1. A source-side app or user sends a CCIP message

The user or source-side application originates a CCIP message from an enabled source chain. That message includes:

- one bridged token amount
- a payload instructing the adapter which vault target to use
- a beneficiary that should ultimately receive the output token
- a minimum acceptable output amount
- a packed `deliveryAndRefund` word: whether the output returns to the source chain or is delivered locally, plus an optional destination-chain `localRefundAddress`

There is no user-supplied return-leg `extraArgs` in the payload. Return and refund sends use operator-configured encodings only.

### 2. The router delivers the message to the adapter

On the destination chain, the configured CCIP router calls `ccipReceive()` on the adapter.

In `ccipReceive`, the adapter verifies the caller is the configured router. If that fails, the call reverts immediately.

The inbound source chain selector is validated inside `processMessage` (`onlyValidChain`). If it is not configured, `processMessage` reverts with `InvalidChain` and `ccipReceive` catches that into the failed-message path (so the router delivery still completes and funds can be refunded).

### 3. The adapter enters defensive processing

The adapter uses an external self-call to `processMessage()` inside a `try/catch`.

This means:

- if processing succeeds, the message is marked successful
- if processing fails, the message is marked failed instead of reverting all the way back through the router

This is the core defensive design: failed processing does not silently lose the inbound tokens.

### 4. The payload is decoded and validated

Inside `processMessage()`, the adapter:

- requires the inbound `sourceChainSelector` is configured (non-`NONE`), otherwise `InvalidChain`
- requires exactly one inbound token amount (`InvalidTokenCount`)
- requires `message.data` to be exactly 128 bytes (`InvalidPayloadLength`) and decodes the payload
- checks that the payload `target` is enabled (`InvalidTarget`)
- checks that the inbound amount is nonzero (`AmountIsZero`)

If any of these validations fail, processing reverts and the outer `ccipReceive()` catch path stores the failed message.

### 5. The adapter decides whether this is a deposit or redeem flow

The adapter treats the target as an ERC-4626 vault.

It checks:

- if the bridged token equals `IERC4626(target).asset()`, this is a deposit flow
- if the bridged token equals `target` itself, this is a redeem flow (an ERC-4626 vault is its own share token)

If neither condition matches, the message fails with `InvalidTargetToken`.

### 6. Deposit flow

If the bridged token is the vault asset:

- deposit processing must be enabled
- when `returnToSourceChain` is true, any configured `assetFees[destinationChainSelector][bridgedToken]` for that outbound return route is deducted first (`destinationChainSelector` is the inbound message source CCIP selector; `bridgedToken` is the vault share on deposit-return or underlying on redeem-return); local deliveries skip adapter asset fees
- the remaining amount is approved to the vault
- the adapter calls `deposit()` on the vault
- the adapter receives vault shares as output

The output token in this path is the vault share token.

### 7. Redeem flow

If the bridged token is the vault share token:

- redeem processing must be enabled
- the adapter calls `redeem()` on the vault
- the adapter receives the underlying asset as output
- when `returnToSourceChain` is true, any configured per-destination asset fee is deducted from the redeemed amount; local deliveries skip adapter asset fees

The output token in this path is the underlying vault asset.

### 8. Minimum output enforcement

After deposit or redeem, the adapter checks that:

- the output amount is nonzero (`NoOutputReceived`)
- the output amount, after any fee, is at least `minimumOut` (`MinimumOutputNotMet`)

If the output is too small, the message fails and moves into the failed-message path.

### 9. A processing event is emitted

If target processing succeeds, the adapter emits a `TargetProcessed` event recording:

- the message ID
- the target
- the input token
- the output token
- the input amount
- the output amount

This gives operators and offchain systems visibility into what the vault interaction actually did.

### 10. The output is either bridged back or delivered locally

This depends on `returnToSourceChain`.

#### If `returnToSourceChain == true`

The adapter builds an outbound CCIP message (internal `sendToken`, using the `chains` mapping for EVM vs Solana shape) and bridges the output token back to the `beneficiary` on the original source chain. It pays that CCIP fee from its own native balance; if the balance is too low, the send reverts and the whole message is stored as failed. For an EVM source, `beneficiary` must be a canonical EVM address.

The return message uses only adapter-trusted `extraArgs`: for EVM destinations, the per-lane format in `evmReturnExtraArgsFormat[destinationChainSelector]` (unset means legacy V2) and, on V3 lanes, the per-token `evmReturnRequestedFinality[destinationChainSelector][token]`; for SVM, the fixed Solana `extraArgs` layout with `computeUnits` 0 and the beneficiary as token receiver.

#### If `returnToSourceChain == false`

The adapter transfers the output token directly on the current chain to the local beneficiary address.

This requires the `beneficiary` bytes32 value to be a valid EVM address encoding (upper 96 bits zero), otherwise `InvalidEVMAddress`.

### 11. Success path completes

If the vault action and final delivery both succeed:

- the adapter emits `MessageSucceeded`
- the user has either:
  - received the output locally on the destination chain, or
  - had the output bridged back toward the source chain (a second CCIP message, emitted as `MessageSent`)

## Failure journey

If anything fails during processing, the flow changes.

### 12. The failed message is stored

When `processMessage()` reverts for any reason, `ccipReceive()` catches the error with a bare `catch` (so large revert payloads cannot exhaust gas in the handler) and stores a minimal record:

- `messageErrorCode[messageId] = BASIC`
- `failedMessageRecords[messageId]` — only `sourceChainSelector`, `sender`, `destTokenAmounts`, and `localRefundAddress` (not full `message.data`)
- `refundChainFamilySnapshot[messageId]` — the outbound EVM vs SVM encoding family to use when bridging the refund back: normally `chains[sourceChainSelector]` at failure time; if that mapping was still `NONE`, the adapter derives a best-effort type from `message.sender` (32-byte with only the low 160 bits set → EVM; any other 32-byte value → SVM; any other length → `NONE`, so refunds revert until `chains` is configured)

It also emits `MessageFailed`.

This means the message is now recoverable instead of silently lost.

Because `ccipReceive()` catches the error and does not revert, the CCIP execution itself succeeds: the CCIP Explorer shows the message as `SUCCESS`. To tell whether the vault action actually happened, check the adapter: `MessageSucceeded` vs `MessageFailed` for the message ID, or `messageErrorCode(messageId)` (`BASIC` means failed and recoverable).

### 13. Anyone can inspect refund eligibility

An operator, frontend, or automation system can call:

- `checkRefundEligibility(messageId)`
- `checkLocalRecoveryEligibility(messageId)`
- `estimateRefundFee(messageId)`

These helpers reveal:

- whether the message is refundable cross-chain
- whether local recovery is available and which `localRefundAddress` may claim it
- who the original sender is
- which token and amount are associated with the failed message
- how much native fee is required to bridge the refund back

### 14. Anyone can trigger the cross-chain refund

Any address can call `refundFailedMessage(messageId)` as long as it provides enough `msg.value` to pay the return CCIP fee.

The refund path (exact on-chain order):

- checks the message is still failed (`BASIC`)
- loads the stored record from `failedMessageRecords`
- derives the original sender from `message.sender`
- resolves the outbound wire family for refund sends from `refundChainFamilySnapshot`, falling back to the live `chains` entry and, if needed, the same sender-based inference—so refunds do not silently assume EVM when the route was effectively SVM
- sets `messageErrorCode` to `RESOLVED` and deletes `failedMessageRecords[messageId]` and `refundChainFamilySnapshot[messageId]` before looping outbound sends (on full success there is no stored copy left)
- for each `destTokenAmounts` entry with nonzero amount, bridges that token back to the original sender on the source chain, paying native CCIP fees from `msg.value` as it goes
- requires `msg.value` to cover the total of the fees actually paid in those sends (reverts `InsufficientRecoveryFee` otherwise; use `estimateRefundFee` / `checkRefundEligibility` as estimates and pad `msg.value`)
- refunds any excess `msg.value` back to the refund caller

If anything after the initial state update reverts (for example an outbound send fails or `msg.value` is too low), the entire rolls back, the message stays `BASIC`, and `failedMessageRecords` remains available for a retry.

### 15. The `localRefundAddress` can recover on the destination chain

When the inbound payload included a non-zero `localRefundAddress`, that EVM address may call `recoverFailedMessageLocally(messageId)` while the message is still `BASIC`.

The local recovery path:

- requires `msg.sender == localRefundAddress`
- does not require native CCIP fee
- transfers inbound `destTokenAmounts` tokens on this chain (the same tokens cross-chain refund would bridge back)
- sets `messageErrorCode` to `RESOLVED` and deletes the stored failure record before transfers
- emits `MessageRecoveredLocally`

Cross-chain refund and local recovery are both available while the message is `BASIC`; whichever succeeds first resolves the message. Integrators should attempt cross-chain refund when feasible, and use local recovery when the return lane is broken, too costly, or blocked by sender encoding rules.

### 16. Important refund behavior

Refunds go to the original `message.sender`, not the payload beneficiary.

That means:

- the normal success path is beneficiary-driven
- the failed-message refund path is sender-driven

This is intentional in the current design and should be understood by integrators using source-side sender contracts.

## Two concrete mental models

### Deposit into a vault

1. User or app bridges the vault asset to the adapter.
2. The adapter deposits that asset into the configured vault.
3. The adapter gets vault shares.
4. Shares are either sent back to the source chain or delivered locally.

### Redeem from a vault

1. User or app bridges vault shares to the adapter.
2. The adapter redeems the shares into the underlying asset.
3. The adapter gets the underlying asset.
4. Asset is either sent back to the source chain or delivered locally.

## Summary

The adapter acts as a defensive cross-chain vault adapter:

- it receives one bridged token
- interprets the payload
- performs a deposit or redeem against an ERC-4626 target
- returns the resulting token either locally or back to the source chain
- and if anything fails, it stores the message so the tokens can be refunded to the original sender or recovered by the `localRefundAddress`
