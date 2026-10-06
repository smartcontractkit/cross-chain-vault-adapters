# Cross-chain ERC-4626 adapter operator guide

This guide is written for the deployer and ongoing operator of `CrossChainERC4626Adapter.sol`. CCIP is Chainlink's Cross-Chain Interoperability Protocol; chain families are EVM (Ethereum Virtual Machine) and SVM (Solana Virtual Machine).

Deployment (Foundry scripts, factory on a block explorer, direct constructor, env vars, explorer field mapping) lives in the [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md). The end-user message flow is in the [user journey](cross-chain-erc4626-adapter-user-journey.md), and every function, event, and error is in the [contract reference](cross-chain-erc4626-adapter-contract-reference.md).

It explains:

- how the adapter is deployed (see the deployment guide for procedures)
- how to configure it safely
- what each role is allowed to do
- how to operate the adapter in production
- how to respond to failed messages

## Contracts in scope

Primary contracts:

- `src/ccip/CrossChainERC4626Adapter.sol`
- `src/ccip/CrossChainERC4626AdapterFactory.sol`
- `script/ccip/DeployAndActivateCrossChainERC4626Adapter.s.sol` (`pnpm ccip:deploy`: factory and one configured adapter)
- `script/ccip/ConfigureCrossChainERC4626Adapter.s.sol` (`pnpm ccip:configure`: CCIP v2 lane settings and funding)
- `script/ccip/CheckCrossChainERC4626Adapter.s.sol` (`pnpm ccip:check`: read-only report)
- `script/ccip/DeployCrossChainERC4626AdapterFactory.s.sol` (`pnpm ccip:deploy-factory`: factory only)
- `script/ccip/DeployCrossChainERC4626Adapter.s.sol` (`pnpm ccip:deploy-adapter-only`: adapter via constructor only)

## High-level purpose

`CrossChainERC4626Adapter` is a CCIP destination-side adapter that:

1. accepts one inbound bridged token
2. interprets a payload describing a vault interaction
3. performs a deposit or redeem against an ERC-4626 target vault
4. returns the resulting token either:
   - locally on the destination chain, or
   - back to the original source chain

It also supports:

- fee collection
- failed-message storage
- permissionless refunds for failed messages, and local recovery by an address named in the payload
- configurable per-source CCV (Cross-Chain Verifier) policy and per-selector inbound finality, advertised through the CCIP v2 receiver interface (`getCCVsAndFinalityConfig`)
- configurable per-lane return and refund `extraArgs` format (`setEvmReturnLaneFormat`) and per-(lane, bridged token) V3 `requestedFinality` (`setEvmReturnRequestedFinality`)

## Role model

The adapter uses OpenZeppelin `AccessControlEnumerable` and has three role surfaces:

- `DEFAULT_ADMIN_ROLE`
- `FEE_SETTER_ROLE`
- `FEE_COLLECTOR_ROLE`

### `DEFAULT_ADMIN_ROLE`

This is the primary administrative role and should usually be assigned to a multisig or similarly controlled address.

Capabilities:

- `setChainType(...)`
- `setTargetEnabled(...)`
- `setProcessingEnabled(...)`
- `setCCVsConfig(...)`
- `setInboundFinality(...)`
- `setEvmReturnLaneFormat(...)`, `setEvmReturnRequestedFinality(...)`
- `recoverNative(...)`
- inherited role management:
  - `grantRole(...)`
  - `revokeRole(...)`
  - `renounceRole(...)`

Recommended holder:

- a multisig or governance-controlled admin address

### `FEE_SETTER_ROLE`

This role controls fee schedule updates.

Capabilities:

- `setAssetFee(...)` (single entry)
- `setAssetFees(...)` (batch update)

Recommended holder:

- a dedicated operator or automation address that is allowed to update fee configuration

### `FEE_COLLECTOR_ROLE`

This role controls fee extraction from the adapter.

Capabilities:

- `withdrawFee(...)`

Recommended holder:

- a treasury automation address or operational wallet dedicated to fee collection

## Deployment

Step-by-step deployment, environment variables, and the block explorer field mapping for `factory.deploy(...)` are in the [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md). In summary:

- Factory `deploy(DeploymentConfig)` (recommended, used by `pnpm ccip:deploy`): one transaction deploys the adapter, applies `chainConfigs`, target enablement, processing toggles, and optional `feeConfigs`, then grants `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` to the configured addresses and renounces its own roles. Each role goes only to its configured address.
- Direct constructor `CrossChainERC4626Adapter(router, defaultAdmin, feeSetter, feeCollector)` (`pnpm ccip:deploy-adapter-only`): validates non-zero addresses, sets the immutable `ROUTER`, and grants all three roles to `defaultAdmin` plus the fee roles to `feeSetter` / `feeCollector` when they differ. You configure chains, targets, processing, and fees yourself afterward.
- Either way, `inboundFinality` defaults to `bytes4(0)` (`WAIT_FOR_FINALITY_FLAG`), unset return lanes encode as `GenericExtraArgsV2` (CCIP v1), and no CCVs are configured. `pnpm ccip:configure` applies the CCIP v2 settings and native funding.

The scripts take the usual Forge signer flags (`--account <keystore name>`, `--private-key`, or `--ledger`); they do not read a private key from `.env`.

### Chain type mapping (`ChainType`)

- `0 = NONE`
- `1 = EVM`
- `2 = SVM`

## CCIP stack version and return-leg `extraArgs` (EVM)

This adapter implements `IAny2EVMMessageReceiverV2` and exposes per-`sourceChainSelector` CCV arrays plus `inboundFinality[message.sourceChainSelector]` as `allowedFinalityConfig` through `getCCVsAndFinalityConfig`. That is the CCIP v2 inbound surface; CCIP v1 lanes do not read it. Return and refund sends are separate and use two admin settings:

- `setEvmReturnLaneFormat(destinationChainSelector, format)` stores `evmReturnExtraArgsFormat[destinationChainSelector]`: the wire format for every EVM return and refund send to that selector, regardless of token.
- `setEvmReturnRequestedFinality(destinationChainSelector, token, requestedFinalityForV3)` stores `evmReturnRequestedFinality[destinationChainSelector][token]`: the `requestedFinality` encoded when that lane uses `GenericExtraArgsV3` (the `token` is the bridged ERC-20 on that leg).

The encoded result must be accepted by the local CCIP router, OnRamp, and token pool for the selector passed to `ccipSend`, which is the inbound message's `sourceChainSelector` when bridging back. Choose the format per destination selector from the lane's CCIP version (see the [CCIP documentation](https://docs.chain.link/ccip) and the [CCIP directory](https://docs.chain.link/ccip/directory)); the contract does not enforce it:

| Lane (outbound from this adapter to that selector) | Configuration | What gets encoded |
| --- | --- | --- |
| CCIP v2 lane that accepts `GenericExtraArgsV3` with finality on token-only transfers | `setEvmReturnLaneFormat(selector, GENERIC_EXTRA_ARGS_V3_BASIC)`, then optionally `setEvmReturnRequestedFinality(selector, token, requestedFinalityForV3)` for each bridged token (unset tokens use `bytes4(0)`, wait for finality) | `ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, evmReturnRequestedFinality[selector][token])`, with `gasLimit` 0 (no destination callback; tokens-only return leg) |
| CCIP v1 lane that accepts only `GenericExtraArgsV2` | `setEvmReturnLaneFormat(selector, LEGACY_EXTRA_ARGS_V2)`, or leave `evmReturnExtraArgsFormat[selector]` unset (`UNSET` encodes as legacy V2) | `Client.GenericExtraArgsV2` with `gasLimit == 0` and `allowOutOfOrderExecution == true` (stored finality is ignored) |

The adapter does not detect the CCIP version of a lane. The wrong format usually shows up as a `getFee` or `ccipSend` revert, or an unexpected fee quote; validate on a test lane before production.

Solana (`ChainType.SVM`) return legs always use the adapter's fixed `Client.SVMExtraArgsV1` construction (`computeUnits` 0, `allowOutOfOrderExecution` true, `tokenReceiver` set to the beneficiary); lane format and requested finality are not used.

## Recommended initial setup sequence

After deployment, a good production setup order is below. Steps 3 to 6 are done by the factory when you deploy with `pnpm ccip:deploy`, and steps 7 to 10 by `pnpm ccip:configure`.

1. Confirm `ROUTER()` is correct.
2. Confirm all intended roles are held by the expected addresses.
3. Configure source and return chains with `setChainType(...)`.
4. Enable the target vault with `setTargetEnabled(...)`.
5. Configure processing switches with `setProcessingEnabled(...)`.
6. Configure the fee schedule with `setAssetFee(...)` and/or `setAssetFees(...)` if needed.
7. CCIP v2 lanes only: for each inbound source selector, configure CCV lists with `setCCVsConfig(sourceChainSelector, ...)` if the lane's default verifiers are not what you want.
8. CCIP v2 lanes only: for each inbound source selector, call `setInboundFinality(sourceChainSelector, ...)` so `getCCVsAndFinalityConfig` advertises the intended `allowedFinalityConfig` (skip it if `bytes4(0)`, wait for finality, is correct).
9. For each outbound EVM return selector on a CCIP v2 lane, call `setEvmReturnLaneFormat(destinationChainSelector, GENERIC_EXTRA_ARGS_V3_BASIC)`; CCIP v1 lanes can stay unset (see [CCIP stack version and return-leg `extraArgs` (EVM)](#ccip-stack-version-and-return-leg-extraargs-evm)). Then call `setEvmReturnRequestedFinality(destinationChainSelector, token, requestedFinalityForV3)` for each bridged token that needs a finality other than `bytes4(0)`. Set the lane format first: the finality setter only accepts non-zero values once the lane resolves to V3.
10. Fund the adapter with enough native gas token to pay the CCIP fees of return-to-source deliveries.
11. Perform at least one deposit-path and one redeem-path test on the intended lane, then run `pnpm ccip:check`.

## Role-gated functions

Below are the role-gated functions that operators should understand.

### `setChainType(uint64 chainSelector, ChainType chainType)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- enables or disables a chain in the `chains` mapping
- controls whether the inbound `sourceChainSelector` on a delivered message is accepted (`processMessage` reverts `InvalidChain` if `NONE`, and `ccipReceive` catches that into the failed-message path)
- controls how outbound return messages are shaped (EVM vs SVM) for that selector; outbound message building reverts `InvalidChain` only if the effective encoding family is `NONE` (return legs are already gated by `onlyValidChain`; refunds use the family snapshotted at failure time)

Behavior:

- emits `ChainTypeSet(chainSelector, chainType)`
- `ChainType.NONE` disables the chain
- `ChainType.EVM` enables standard EVM return message construction
- `ChainType.SVM` enables Solana-style return message construction

Operational note:

- if a source chain is not enabled, `processMessage(...)` reverts `InvalidChain`, `ccipReceive(...)` catches it, and the message becomes refundable (the router call still completes)
- keep return/refund destination selectors configured with the correct family (EVM vs SVM); a wrong family can yield wrong encoding or router rejection on `getFee` / `ccipSend`

### `setTargetEnabled(address target, bool enabled)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- allows or disallows a vault target

Behavior:

- processing reverts if the payload target is not enabled
- target must be a valid ERC-4626-style vault for the default implementation

Operational note:

- use this to explicitly control which vaults the adapter is allowed to interact with

### `setProcessingEnabled(bool depositsEnabled_, bool redeemsEnabled_)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- controls whether deposit and redeem flows are currently active

Typical uses:

- disable deposits if you want to stop new asset-to-share conversions
- disable redeems if you want to stop new share-to-asset conversions
- use this as the adapter’s pause-like operational switch

### `setAssetFee(uint64 destinationChainSelector, address bridgedToken, uint256 fee)`

Role required:

- `FEE_SETTER_ROLE`

Purpose:

- sets the absolute fee amount for return-leg sends of `bridgedToken` (vault share on deposit-return, underlying on redeem-return) whose CCIP destination is `destinationChainSelector`; the amount is always in the vault underlying asset's smallest units. Refunds of failed messages do not charge this fee

Preconditions:

- `bridgedToken` must not be `address(0)` (`InvalidTarget`)
- `destinationChainSelector` may be configured in `chains` later; fees can be staged before the lane is enabled and take effect once the chain is live

How fees are applied:

- only when `returnToSourceChain == true` in the inbound payload (return-leg CCIP send follows). Local deliveries skip adapter asset fees.
- deposit flow: fee is deducted from inbound asset before vault deposit
- redeem flow: fee is deducted from redeemed asset after vault redeem

Important notes:

- fees are absolute token amounts, not basis points
- if `fee >= amount` on the path where fees apply (the inbound amount on deposit, the redeemed assets on redeem), processing fails with `FeeExceedsAmount`
- asset-denominated fees only approximate native CCIP cost quoted by `router.getFee`; the exchange rate between the asset and the native token is not tracked on-chain, so operators must periodically reconcile schedules against live quotes

### `setAssetFees(uint64[] destinationChainSelectors, address[] bridgedTokens, uint256[] fees)`

Role required:

- `FEE_SETTER_ROLE`

Purpose:

- batch-set return-leg asset fees; arrays must have equal length; each row `(destinationChainSelectors[i], bridgedTokens[i], fees[i])` is validated like `setAssetFee` (`address(0)` token reverts; selector need not yet be enabled in `chains`).

### `setCCVsConfig(uint64 sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- configures the CCIP v2 CCV lists and optional-pass threshold for `sourceChainSelector`, surfaced through `getCCVsAndFinalityConfig(sourceChainSelector, …)`
- does not set finality: use `setInboundFinality` (per `sourceChainSelector`) for inbound advertised finality; use `setEvmReturnLaneFormat` (per `destinationChainSelector`) and `setEvmReturnRequestedFinality` (per `destinationChainSelector`, `token`) for return/refund outbound encoding

Default values on deployment:

- per selector: `requiredCCVs = []`, `optionalCCVs = []`, `optionalThreshold = 0` until configured

Validation:

- `optionalThreshold` must be less than or equal to `optionalCCVs.length` (`InvalidOptionalThreshold`)
- `optionalThreshold` must be positive when `optionalCCVs` is non-empty (`OptionalCCVsRequirePositiveThreshold`)
- CCVs must be unique across the required and optional sets (`DuplicateCCV`)
- `address(0)` is rejected in `optionalCCVs` (`InvalidOptionalCCV`) but remains valid in `requiredCCVs` as the CCIP default-verifier placeholder

Operational meaning:

- CCV routing is controlled per inbound source chain; `allowedFinalityConfig` advertised to the network for that source reads `inboundFinality[sourceChainSelector]`

### `setInboundFinality(uint64 sourceChainSelector, bytes4 allowedFinalityConfig)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- sets `inboundFinality[sourceChainSelector]`: the `allowedFinalityConfig` value `getCCVsAndFinalityConfig(sourceChainSelector, …)` returns for messages whose `message.sourceChainSelector` is `sourceChainSelector`

Operational note:

- unset keys behave as `bytes4(0)`, i.e. `FinalityCodec.WAIT_FOR_FINALITY_FLAG` (“wait for full finality”)

### `setEvmReturnLaneFormat(uint64 destinationChainSelector, EvmReturnExtraArgsFormat format)` / `setEvmReturnRequestedFinality(uint64 destinationChainSelector, address token, bytes4 requestedFinalityForV3)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- selects how the trusted outbound EVM `extraArgs` are built for return and refund sends to `destinationChainSelector` (the chain the adapter sends *to* when bridging back)
- `setEvmReturnLaneFormat` sets the format for the whole lane (`evmReturnExtraArgsFormat[destinationChainSelector]`) and emits `EvmReturnLaneFormatSet(destinationChainSelector, format)`
- `setEvmReturnRequestedFinality` sets the V3 `requestedFinality` for one bridged `token` on that lane (`evmReturnRequestedFinality[destinationChainSelector][token]`) and emits `EvmReturnRequestedFinalitySet(destinationChainSelector, token, requestedFinalityForV3)`
- return-leg `extraArgs` never come from the user payload: only admin policy and Chainlink `ExtraArgsCodec` encodings apply

Formats:

- `UNSET` (0): storage default; encodes as `LEGACY_EXTRA_ARGS_V2`
- `LEGACY_EXTRA_ARGS_V2` (1): `Client.GenericExtraArgsV2` with `gasLimit == 0` and `allowOutOfOrderExecution == true` (CCIP v1 lanes)
- `GENERIC_EXTRA_ARGS_V3_BASIC` (2): `ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, evmReturnRequestedFinality[destinationChainSelector][token])`, a tokens-only return leg with no callback gas (CCIP v2 lanes)

Validation:

- `setEvmReturnLaneFormat`: `UNSET` is rejected (`InvalidEvmReturnExtraArgsFormat`); selectors that were never configured keep `UNSET` in storage and behave like legacy V2 until an admin sets an explicit format
- `setEvmReturnRequestedFinality`: `token` must not be `address(0)` (`InvalidTarget`)
- `setEvmReturnRequestedFinality` on a lane that resolves to legacy V2 (unset or `LEGACY_EXTRA_ARGS_V2`): only `bytes4(0)` is accepted, which clears the stored value; any other value reverts `UnexpectedRequestedFinalityForLegacyFormat`. Set the lane to `GENERIC_EXTRA_ARGS_V3_BASIC` first
- `setEvmReturnRequestedFinality` on a V3 lane: the value must pass `FinalityCodec._validateRequestedFinality`: `bytes4(0)` (wait for finality), exactly one flag bit in the upper 16 bits (for example `0x00010000`, wait for `safe`), or a pure block depth `1..65535` in the lower 16 bits. A flag combined with a depth, or several flags, reverts `RequestedFinalityCanOnlyHaveOneMode`. The value must still be accepted by the CCIP router, OnRamp, and token pool on that lane
- switching a lane from V3 back to legacy does not clear stored per-token finality; it is ignored on encode while the lane is legacy and applies again if the lane is switched back to V3

Operational note:

- see [CCIP stack version and return-leg `extraArgs` (EVM)](#ccip-stack-version-and-return-leg-extraargs-evm): set finality for the actual output token on each leg (vault shares after a deposit, underlying after a redeem, or the inbound token on a refund)

### `withdrawFee(address asset, address recipient, uint256 amount)`

Role required:

- `FEE_COLLECTOR_ROLE`

Purpose:

- withdraws a specific amount of accrued fee balance for an asset

Checks:

- `recipient` must be nonzero
- `amount` must be nonzero
- `amount <= collectedFees[asset]` (otherwise `InsufficientFeeBalance`)

Behavior:

- subtracts from `collectedFees[asset]`
- transfers the requested token amount to `recipient` via `safeTransfer`

Operational notes:

- this is `nonReentrant`
- this is the fee-collection path for the adapter
- if `collectedFees` and the real ERC-20 balance ever diverge, `amount` can pass the accounting check yet `safeTransfer` reverts with the token's own error (not `InsufficientFeeBalance`)

### `recoverNative(address recipient)`

Role required:

- `DEFAULT_ADMIN_ROLE`

Purpose:

- transfers the full native balance held by the adapter to `recipient`

Checks:

- `recipient` must be nonzero
- adapter must have nonzero native balance
- if `recipient` rejects ether, the call reverts with `RecoverNativeFailed()`

Operational warning:

- the adapter uses its native balance to pay the outbound CCIP fees of return-to-source deliveries
- draining the native balance makes those deliveries fail (the messages are then stored as failed and must be refunded or recovered)

Use carefully.

## Read functions useful to operators

The following public read surfaces are useful during operations.

### `ROUTER()`

Returns the immutable configured router address.

### `chains(uint64 chainSelector)`

Returns the configured chain type for a selector.

### `enabledTargets(address target)`

Returns whether the target vault is enabled.

### `depositsEnabled()` / `redeemsEnabled()`

Returns whether those two processing paths are currently active.

### `assetFees(uint64 destinationChainSelector, address bridgedToken)`

Returns the configured fee amount (in vault underlying units) for that outbound destination and bridged-token pair (used only on return-leg processing).

### `collectedFees(address asset)`

Returns the currently accrued fee balance tracked by the adapter.

### `messageErrorCode(bytes32 messageId)`

Returns the per-message `ErrorCode` processing status (not message contents):

- `NONE`
- `BASIC`
- `RESOLVED`

### `getFailedMessageRecord(bytes32 messageId)`

Returns the stored refund-relevant fields only while `messageErrorCode(messageId)` is `BASIC`. After a successful `refundFailedMessage` or `recoverFailedMessageLocally`, this storage is cleared for that ID (state is `RESOLVED`). If a recovery transaction reverts partway through, storage rolls back and the copy remains for retries. Returns `sourceChainSelector`, `sender`, `destTokenAmounts`, and `localRefundAddress` (not the full CCIP envelope or `message.data`).

### `checkRefundEligibility(bytes32 messageId)`

Returns:

- whether a failed message is refundable
- original sender
- token and amount
- estimated fee required to execute the refund

It returns `canRefund = false` instead of reverting when the message is not `BASIC`, the stored sender is not 32 bytes, or there is no non-zero amount. The router `getFee` call it makes can still revert (for example an unsupported lane or an incompatible return-lane format); treat that as "not refundable right now".

### `preview(address token, address vaultTarget, uint256 amount, bool returnToSourceChain, uint64 assetFeeDestinationChainSelector)`

External view helper for UIs: returns the net output amount the adapter would produce for an inbound CCIP transfer of `amount` of `token` into allowlisted `vaultTarget`, using the same deposit vs redeem path and conditional asset fee as `processMessage`. When `returnToSourceChain` is false, no asset fee is charged. When true, fees use `assetFees[assetFeeDestinationChainSelector][...]`. `assetFeeDestinationChainSelector` must be the inbound `message.sourceChainSelector` and must be configured in `chains` in all cases (same rule as `processMessage`'s `onlyValidChain`), not only when simulating a return leg. Internally it calls the vault's `previewDeposit` (deposit path: `token` is the vault asset) or `previewRedeem` (redeem path: `token` is the vault address). Use the result to set `minimumOut` with a slippage discount. Returns `0` when `amount` is zero, when the fee leaves nothing to deposit or no net assets after redeem, or when the vault preview is zero—without reverting. Still reverts for configuration errors (e.g. target not enabled, wrong `token` for `vaultTarget`, deposits/redeems disabled, or unconfigured source chain selector). If the vault's `previewDeposit` / `previewRedeem` reverts, this function reverts too.

### `estimateRefundFee(bytes32 messageId)`

Returns an estimate of the native fee required to refund a failed message. Each refund leg is re-quoted at execution, so pad `msg.value`.

### `checkLocalRecoveryEligibility(bytes32 messageId)`

Returns:

- whether a failed message supports local recovery
- the stored `localRefundAddress` from the inbound payload
- token and amount that would be transferred on this chain

### `inboundFinality(uint64 sourceChainSelector)`

Public mapping getter:

- `inboundFinality`: bitmask returned as `allowedFinalityConfig` from `getCCVsAndFinalityConfig` for that inbound `sourceChainSelector`

### `getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes sender)`

Returns `requiredCCVs`, `optionalCCVs`, and `optionalThreshold` from `ccvConfigs[sourceChainSelector]`, plus `allowedFinalityConfig == inboundFinality[sourceChainSelector]`. `sender` is unused (`IAny2EVMMessageReceiverV2` interface parity).

## Message lifecycle

### Success path

1. The router delivers a CCIP message to the adapter.
2. In `ccipReceive`, the adapter checks the caller is the configured router.
3. In `processMessage`, the adapter checks the inbound `sourceChainSelector` is enabled (`onlyValidChain`).
4. The inbound message must carry exactly one token, and the payload must be exactly 128 bytes: `abi.encode(address target, bytes32 beneficiary, uint256 minimumOut, uint256 deliveryAndRefund)` for both EVM and SVM sources (same shape; chain family still gates outbound return message encoding). `deliveryAndRefund` packs bit 0 = `returnToSourceChain` and bits 1..160 = `localRefundAddress` on this chain (`address(0)` in those bits disables local recovery).
5. The target is checked for enablement.
6. The adapter decides whether the inbound token implies:
   - deposit flow, or
   - redeem flow
7. The adapter executes the vault interaction.
8. `minimumOut` is enforced.
9. The output is either:
   - bridged back to the source chain (internal `sendToken`, after the return-leg fee and paid from the adapter's native balance), or
   - transferred locally to `beneficiary`
10. `MessageSucceeded` is emitted.

### Failure path

If anything fails during processing:

- `ccipReceive(...)` catches the revert with a bare `catch` (revert data is not materialized or logged)
- `messageErrorCode[messageId]` is set to `BASIC`
- a minimal failure record (`sourceChainSelector`, `sender`, `destTokenAmounts`, `localRefundAddress`) is stored in `failedMessageRecords`
- the outbound encoding family for a later refund is stored in `refundChainFamilySnapshot[messageId]`
- `MessageFailed` is emitted

Because `ccipReceive` does not revert, the CCIP execution succeeds and the CCIP Explorer shows the message as `SUCCESS`, not `FAILED`, even though the adapter recorded a failure. Monitor `MessageFailed` events or `messageErrorCode(messageId) == BASIC` to find messages that need a refund or local recovery. A CCIP-level `FAILED` status only occurs when `ccipReceive` itself reverts (for example the destination execution runs out of gas).

This means failed messages are recoverable rather than silently lost.

### Refund path

`refundFailedMessage(bytes32 messageId)` is:

- payable
- permissionless
- `nonReentrant`

Behavior (exact on-chain order):

1. checks that the message is currently failed (`BASIC`)
2. loads `failedMessageRecords[messageId]` and validates at least one positive `destTokenAmounts` entry
3. derives the original sender from the stored `sender` (it must be exactly 32 bytes, otherwise `InvalidSenderAddressFormat`)
4. resolves the outbound encoding family from `refundChainFamilySnapshot`, falling back to the live `chains` entry and then to inference from the sender
5. sets `messageErrorCode` to `RESOLVED` and deletes `failedMessageRecords[messageId]` and `refundChainFamilySnapshot[messageId]` (before outbound sends)
6. for each `destTokenAmounts` entry with nonzero amount, bridges that token to the original sender (internal `sendToken`), accumulating the native fees actually paid
7. requires `msg.value >=` that aggregate (reverts with `InsufficientRecoveryFee` if not)
8. refunds any excess native value to the refund caller
9. emits `MessageRefunded`

The caller pays the refund CCIP fees through `msg.value`; the adapter's own native balance is not needed.

Integrators should use `estimateRefundFee` / `checkRefundEligibility` only as estimates and pad `msg.value`: each `sendToken` re-quotes fees at execution time.

Important:

- refunds go to the original `message.sender`
- refunds do not go to the payload `beneficiary`
- if any step after the state update reverts, the entire transaction rolls back, the message stays `BASIC`, and `failedMessageRecords` is restored for retry

### Local recovery path

`recoverFailedMessageLocally(bytes32 messageId)` is:

- non-payable
- callable only by the stored payload `localRefundAddress` (must be non-zero)
- `nonReentrant`

Behavior:

1. checks that the message is currently failed (`BASIC`)
2. loads `failedMessageRecords[messageId]` and requires a non-zero `localRefundAddress` (`NoLocalRefundAddress`)
3. requires `msg.sender == localRefundAddress` (`UnauthorizedLocalRefund`)
4. requires at least one positive `destTokenAmounts` entry (`NoRefundableTokenAmounts`)
5. sets `messageErrorCode` to `RESOLVED` and deletes `failedMessageRecords[messageId]` and `refundChainFamilySnapshot[messageId]` (before transfers)
6. for each `destTokenAmounts` entry with nonzero amount, `safeTransfer`s that token to `localRefundAddress` on this chain
7. emits `MessageRecoveredLocally`

Cross-chain refund and local recovery are both available while the message is `BASIC`; whichever succeeds first resolves the message, and the other then reverts `MessageNotFailed`.

Use this path when cross-chain `refundFailedMessage` is unavailable, too costly, or blocked (for example an unsupported `message.sender` width, a broken return lane, or a refund fee the user does not want to pay). Integrators should still attempt the permissionless cross-chain refund first when feasible.

## Operator runbook

### Before enabling production use

Complete the [recommended initial setup sequence](#recommended-initial-setup-sequence), including a deposit-path and a redeem-path test on the intended lane, and confirm `pnpm ccip:check` reports no warnings.

### During normal operation

Monitor:

- native gas balance on the adapter
- `messageErrorCode`
- `collectedFees`
- emitted events:
  - `MessageFailed`
  - `MessageRefunded`
  - `TargetProcessed`
  - `MessageSent`
  - `MessageSucceeded`
  - `MessageRecoveredLocally`
  - `LocalTokenDelivered`

### If messages start failing

Check:

- is the source chain enabled?
- is the target vault enabled?
- are deposits and redeems enabled?
- is the adapter sufficiently funded with native gas token for return-to-source deliveries?
- is the target vault paused, capped, or otherwise unable to process?
- is `minimumOut` too strict?
- if return sends fail on a lane, is `evmReturnExtraArgsFormat(selector)` correct for that lane (V2 vs V3), and on V3 lanes is `evmReturnRequestedFinality(selector, token)` accepted for that bridged token?

If a message is already failed:

- inspect `getFailedMessageRecord(messageId)`
- call `estimateRefundFee(messageId)`
- optionally inspect `checkRefundEligibility(messageId)` and `checkLocalRecoveryEligibility(messageId)`
- submit `refundFailedMessage(messageId)` with enough native value, or have `localRefundAddress` call `recoverFailedMessageLocally(messageId)` when cross-chain refund is not viable

## Configuration cautions

### Native gas balance

The adapter pays the outbound CCIP fees of bridge-back output sends (`returnToSourceChain = true`) from its own native balance. If it does not hold enough native gas token, those sends revert with `InsufficientNativeBalance` and the inbound message is stored as failed. Failed-message refunds are paid by the caller's `msg.value`, not by the adapter balance.

### Fees

Fees are absolute token amounts.

This means:

- very small transfers can fail if fee configuration is too aggressive
- operators should set fee amounts with token decimals and expected transaction sizes in mind

### Admin privilege

`DEFAULT_ADMIN_ROLE` can materially affect system behavior by:

- disabling chains
- disabling targets
- disabling processing
- changing `inboundFinality`, return `extraArgs` policy, or CCV arrays
- draining native gas balance through `recoverNative`

This role should be controlled conservatively.

## Minimal example production configuration

A reasonable initial configuration often looks like:

- `router = <lane router>`
- `defaultAdmin = <multisig>`
- `feeSetter = <operations wallet or automation>`
- `feeCollector = <treasury collection wallet or automation>`
- `vaultTarget = <approved ERC-4626 vault>`
- `targetEnabled = true`
- `depositsEnabled = true`
- `redeemsEnabled = true`
- `chainConfigs = <enabled source and return chains>`
- `feeConfigs = []` or configured fee entries
- for each inbound source on a CCIP v2 lane: `setInboundFinality` as needed (omit if the `WAIT_FOR_FINALITY_FLAG` default is acceptable)
- for each EVM return destination on a CCIP v2 lane: `setEvmReturnLaneFormat(selector, GENERIC_EXTRA_ARGS_V3_BASIC)`, and `setEvmReturnRequestedFinality(selector, token, …)` per bridged token as needed

## Summary

The deployer/admin operating this adapter is responsible for:

- safe deployment
- correct role assignment
- target allowlisting
- chain enablement
- fee configuration
- inbound finality, return `extraArgs` policy, and CCV policy
- keeping the adapter funded with native gas token
- monitoring failed messages and helping users refund or recover them

The adapter is intentionally simple, so most operational safety comes from correct configuration and disciplined role management.
