# CrossChainERC4626Adapter contract reference

Reference for `CrossChainERC4626Adapter` and `CrossChainERC4626AdapterFactory` (`src/ccip/`): deployment arguments, roles, configuration, callable surface, events, errors, and integration notes. Chain families are `EVM` (Ethereum Virtual Machine) and `SVM` (Solana Virtual Machine).

For narrative operations and checklists, see the [operator guide](cross-chain-erc4626-adapter-operator-guide.md). For deployment scripts and env vars, see the [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md). For the message flow, see the [user journey](cross-chain-erc4626-adapter-user-journey.md).

---

## Contracts at a glance

| Contract | Purpose |
|----------|---------|
| `CrossChainERC4626Adapter` | CCIP receiver that deposits/redeems against allowlisted ERC-4626 vaults, optionally bridges output back, tracks flat asset-denominated return-leg fees, and exposes refund tooling for failed deliveries. |
| `CrossChainERC4626AdapterFactory` | One-shot deploy + optional initial `setChainType` / `setTargetEnabled` / `setProcessingEnabled` / `setAssetFee` rows, then hands off `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` and renounces them from itself. |

Version strings (`typeAndVersion`): adapter `CrossChainERC4626Adapter 1.0.0`; factory `CrossChainERC4626AdapterFactory 1.0.0`.

---

## Deployment arguments

### `CrossChainERC4626Adapter` constructor

```solidity
constructor(address router_, address defaultAdmin, address feeSetter, address feeCollector)
```

| Argument | Meaning |
|----------|---------|
| `router_` | Chainlink `IRouterClient` authorized to call `ccipReceive` (`onlyRouter`). Stored as immutable `ROUTER`. Must not be `address(0)` (`InvalidRouter`). |
| `defaultAdmin` | Receives `DEFAULT_ADMIN_ROLE`. Must not be `address(0)` (`InvalidAdmin`). Also receives `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE` initially. |
| `feeSetter` | If different from `defaultAdmin`, additionally granted `FEE_SETTER_ROLE`. Must not be `address(0)` (`InvalidFeeSetter`). |
| `feeCollector` | If different from `defaultAdmin`, additionally granted `FEE_COLLECTOR_ROLE`. Must not be `address(0)` (`InvalidFeeCollector`). |

Post-constructor: `inboundFinality` defaults to `bytes4(0)` (`WAIT_FOR_FINALITY_FLAG`). `evmReturnExtraArgsFormat(destinationChainSelector)` unset / `UNSET` encodes as legacy `GenericExtraArgsV2` on outbound sends, and `evmReturnRequestedFinality(destinationChainSelector, token)` is `bytes4(0)`.

### `CrossChainERC4626AdapterFactory.deploy`

```solidity
function deploy(DeploymentConfig calldata config) external returns (address adapterAddress)
```

`DeploymentConfig` (`struct`):

| Field | Type | Meaning |
|-------|------|---------|
| `router` | `address` | Passed to the adapter constructor as `router_`. |
| `defaultAdmin` | `address` | Final `DEFAULT_ADMIN_ROLE` holder after handoff. Must not be zero (`InvalidAdmin`). |
| `feeSetter` | `address` | Final `FEE_SETTER_ROLE` holder. Must not be zero (`InvalidFeeSetter`). |
| `feeCollector` | `address` | Final `FEE_COLLECTOR_ROLE` holder. Must not be zero (`InvalidFeeCollector`). |
| `vaultTarget` | `address` | If non-zero, `setTargetEnabled(vaultTarget, targetEnabled)` runs after deployment. |
| `targetEnabled` | `bool` | Initial enable flag for `vaultTarget` (ignored if `vaultTarget == address(0)`). |
| `depositsEnabled` | `bool` | `setProcessingEnabled(depositsEnabled, redeemsEnabled)`. |
| `redeemsEnabled` | `bool` | Same. |
| `chainConfigs` | `ChainConfig[]` | Each entry: `chainSelector`, `ChainType` (`NONE` / `EVM` / `SVM`) applied via `setChainType`. |
| `feeConfigs` | `FeeConfig[]` | Each row: `destinationChainSelector`, `bridgedToken`, `fee` applied via `setAssetFee` (same validations as direct `setAssetFee` calls—selector may be staged before `setChainType`). |

Factory deploy mechanics:

1. Deploys `CrossChainERC4626Adapter(config.router, address(this), address(this), address(this))` so the factory temporarily holds all three privileged roles.
2. Applies `chainConfigs`, optional `setTargetEnabled`, `setProcessingEnabled`, then each `feeConfigs` row.
3. `_handoffRoles`: `grantRole` admin / fee setter / fee collector to the configured addresses, then `renounceRole` each from `address(this)`.
4. Emits `AdapterDeployed` and returns the adapter address.

Unlike the direct constructor, the factory grants each role only to its configured address: `defaultAdmin` does not also receive `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE` unless it is also passed as `feeSetter` / `feeCollector`. The factory does not set return-lane formats, finality, or CCVs, and does not fund the adapter.

---

## Roles

The adapter inherits `AccessControlEnumerable` from OpenZeppelin and uses three roles. `DEFAULT_ADMIN_ROLE` is also the admin role of the other two.

| Role constant | Purpose |
|---------------|----------------|
| `DEFAULT_ADMIN_ROLE` | Multisig / governance: chain typing, vault allowlist, processing toggles, CCIP v2 CCV (Cross-Chain Verifier) lists (`setCCVsConfig`), per-selector `inboundFinality`, per-lane `setEvmReturnLaneFormat` and per-`(selector, token)` `setEvmReturnRequestedFinality`, native recovery. Also grants/revokes other roles via `grantRole` / `revokeRole`. |
| `FEE_SETTER_ROLE` | `setAssetFee`, `setAssetFees` only. Updates `assetFees[destinationChainSelector][bridgedToken]` schedules used when `returnToSourceChain` is true. |
| `FEE_COLLECTOR_ROLE` | `withdrawFee` only. Moves accrued `collectedFees[asset]` to a treasury `recipient`. |

Why split roles matters:

- `FEE_SETTER_ROLE` does not need multisig latency for routine schedule tweaks (gas quotes drift, new routes). You can assign it to a hot wallet or an automation service that monitors `router.getFee` / lane health and submits `setAssetFee` / `setAssetFees` without touching admin-only risk (cannot disable vaults, drain native via `recoverNative`, or rewrite CCIP policy).
- `FEE_COLLECTOR_ROLE` is withdraw-only against `collectedFees`: automation can sweep to a cold treasury on a schedule without the ability to change fee rates or admin configuration. Keep it separate from `FEE_SETTER_ROLE` if you want “update rates” and “pull balances” to be two different operational keys or compliance gates.
- `DEFAULT_ADMIN_ROLE` retains structural changes (chains, targets, deposits/redeems killswitch, CCV arrays via `setCCVsConfig`, `inboundFinality`, return-leg `setEvmReturnLaneFormat` / `setEvmReturnRequestedFinality`, `recoverNative`). Typical pattern: multisig admin + dedicated `feeSetter` + `feeCollector` addresses.

Enumerable reads (useful for dashboards): `getRoleMemberCount`, `getRoleMember`, `hasRole` from `AccessControlEnumerable`.

---

## Configuration functions by role

Deployment procedures are in the [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md); the recommended setup order is in the [operator guide](cross-chain-erc4626-adapter-operator-guide.md#recommended-initial-setup-sequence).

All below are `external` on `CrossChainERC4626Adapter` unless noted.

### `DEFAULT_ADMIN_ROLE`

| Function | Summary |
|----------|---------|
| `setEvmReturnLaneFormat(uint64 destinationChainSelector, EvmReturnExtraArgsFormat format)` | Chooses legacy `GenericExtraArgsV2` vs `GenericExtraArgsV3` basic for all EVM return and refund sends to `destinationChainSelector` (stored in `evmReturnExtraArgsFormat[destinationChainSelector]`). `UNSET` reverts `InvalidEvmReturnExtraArgsFormat`; never-written storage encodes as legacy V2. Emits `EvmReturnLaneFormatSet`. |
| `setEvmReturnRequestedFinality(uint64 destinationChainSelector, address token, bytes4 requestedFinalityForV3)` | Sets `evmReturnRequestedFinality[destinationChainSelector][token]` for the bridged `token` on that lane. `token == address(0)` reverts `InvalidTarget`. If the lane resolves to legacy V2, only `bytes4(0)` is accepted (clears the entry; any other value reverts `UnexpectedRequestedFinalityForLegacyFormat`). On a V3 lane the value is checked by `FinalityCodec._validateRequestedFinality` (reverts `RequestedFinalityCanOnlyHaveOneMode`) and stored. Emits `EvmReturnRequestedFinalitySet`. Changing a lane back to legacy does not clear stored finality; it is ignored on encode. |
| `setChainType(uint64 chainSelector, ChainType chainType)` | Maps selector → `NONE` / `EVM` / `SVM` (inbound gate + outbound encoding family). Emits `ChainTypeSet`. |
| `setTargetEnabled(address target, bool enabled)` | Allowlists `Payload.target` vaults (`InvalidTarget` if `target == 0`). Emits `TargetEnabled`. |
| `setProcessingEnabled(bool depositsEnabled_, bool redeemsEnabled_)` | Global deposit/redeem path toggles. Emits `ProcessingEnabledSet`. |
| `setCCVsConfig(uint64 sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold_)` | CCIP v2 CCV lists and optional threshold for the given inbound `sourceChainSelector` (stored in `ccvConfigs`; read via `getCCVsAndFinalityConfig`). Inbound finality is `setInboundFinality`; return-leg encoding is `setEvmReturnLaneFormat` / `setEvmReturnRequestedFinality`. Emits `CCVsConfigSet`. |
| `setInboundFinality(uint64 sourceChainSelector, bytes4 allowedFinalityConfig)` | Sets `inboundFinality[sourceChainSelector]` read by `getCCVsAndFinalityConfig`. Emits `InboundFinalitySet`. |
| `recoverNative(address recipient)` | `nonReentrant`; sends the full native balance to `recipient` (`InvalidRecipient` for zero, `AmountIsZero` if the balance is zero, `RecoverNativeFailed` if the transfer fails). Emits `NativeRecovered`. |

Inherited from `AccessControl`: `grantRole`, `revokeRole`, `renounceRole` (admin gates apply).

### `FEE_SETTER_ROLE`

| Function | Summary |
|----------|---------|
| `setAssetFee(uint64 destinationChainSelector, address bridgedToken, uint256 fee)` | Single row; `bridgedToken != 0`; selector may be staged before `chains[destinationChainSelector]` is set. Emits `AssetFeeSet`. |
| `setAssetFees(uint64[] destinationChainSelectors, address[] bridgedTokens, uint256[] fees)` | Batch; lengths must match (`FeeConfigLengthMismatch`); per-row same checks as `setAssetFee`. |

### `FEE_COLLECTOR_ROLE`

| Function | Summary |
|----------|---------|
| `withdrawFee(address asset, address recipient, uint256 amount)` | `nonReentrant`; non-zero `recipient` and `amount`, and `amount <= collectedFees[asset]` (`InsufficientFeeBalance`). Emits `FeeWithdrawn`. |

---

## Message format and inbound flow

Users are integrators originating CCIP token transfers to this adapter’s address on the destination chain. Users do not call `processMessage` directly: the CCIP router calls `ccipReceive`.

### Message shape

- Exactly one entry in `destTokenAmounts`.
- `message.data` must be `abi.encode(Payload)` with length `CCIP_MESSAGE_PAYLOAD_LENGTH` (128 bytes).

`Payload` (`struct`):

| Field | Type | Meaning |
|-------|------|---------|
| `target` | `address` | ERC-4626 vault the adapter interacts with; must be `enabledTargets[target]`. |
| `beneficiary` | `bytes32` | Output recipient. For local delivery, and for returns to an EVM chain, it must be a canonical left-padded EVM address (upper 96 bits zero), otherwise `InvalidEVMAddress`. For returns to an SVM chain it is the 32-byte Solana token receiver. |
| `minimumOut` | `uint256` | Minimum output after the adapter fee: shares on the deposit path, underlying on the redeem path. |
| `deliveryAndRefund` | `uint256` | Bit 0 = `returnToSourceChain`; bits 1..160 = `localRefundAddress` on this chain (`address(0)` disables local recovery); bits 161..255 are ignored. When `returnToSourceChain` is set, the adapter bridges the output to `beneficiary` on `message.sourceChainSelector`; otherwise it transfers it to `beneficiary` on this chain. |

Paths:

- Deposit: inbound token equals `IERC4626(target).asset()` → `deposit` into `target`.
- Redeem: inbound token equals `target` (share token) → `redeem` from `target`.

Fees (asset skim):

When `returnToSourceChain` is `true`, the adapter reads `assetFees[message.sourceChainSelector][bridgedOutputToken]` (vault share on deposit-return, underlying on redeem-return); `fee` amounts are in `IERC4626(target).asset()` smallest units and accrue in `collectedFees`. Local delivery skips this skim.

Failures and refunds:

If `processMessage` reverts, `ccipReceive` uses a bare `catch` (no revert-data materialization) so failure persistence cannot be bypassed by oversized revert payloads. It sets `messageErrorCode[messageId] = BASIC`, stores a minimal `FailedMessageRecord` (`sourceChainSelector`, `sender`, `destTokenAmounts`, `localRefundAddress`—no full `message.data`), emits `MessageFailed`. Because the revert is caught, the CCIP execution itself succeeds: the CCIP Explorer / API shows the message as `SUCCESS`, not `FAILED`. Detect adapter-level failures with `MessageFailed` or `messageErrorCode(messageId) == BASIC`.

- `checkRefundEligibility`, `estimateRefundFee`, `refundFailedMessage` implement the permissionless cross-chain refund (`refundFailedMessage` can be called by any address, which pays the CCIP fee in `msg.value` and receives any excess back).
- `checkLocalRecoveryEligibility`, `recoverFailedMessageLocally` implement optional on-chain recovery to the payload `localRefundAddress` (callable only by that address; no native CCIP fee).
- `message.sender` must be exactly 32 bytes (the CCIP wire encoding) for transactional cross-chain refunds; otherwise `InvalidSenderAddressFormat` (view `checkRefundEligibility` avoids revert). Local recovery does not depend on `message.sender` encoding.

---

## Integration notes

The full guide is the [frontend integration guide](cross-chain-erc4626-adapter-frontend-integration-guide.md).

### ABI and typing

- Prefer generated ABI from `src/ccip/CrossChainERC4626Adapter.sol` / artifacts.
- `supportsInterface`: reports `IAny2EVMMessageReceiver`, `IAny2EVMMessageReceiverV2`, and `AccessControlEnumerable`/`AccessControl`/`ERC165` via `super`.

### Encoding `Payload` (128 bytes)

Mirror Solidity:

```text
deliveryAndRefund = (uint256(uint160(localRefundAddress)) << 1) | (returnToSourceChain ? 1 : 0)

abi.encode(
  address target,
  bytes32 beneficiary,
  uint256 minimumOut,
  uint256 deliveryAndRefund
)
```

Use `ethers.AbiCoder` (or equivalent) so `message.data` length is exactly 128. See `packDeliveryAndRefund` / `unpackDeliveryAndRefund` in `e2e/ccip/shared.ts`.

### Read helpers for UX

| Function | Use |
|----------|-----|
| `preview(token, vaultTarget, amount, returnToSourceChain, assetFeeDestinationChainSelector)` | Same economics as `processMessage`, as a view; `assetFeeDestinationChainSelector` must be a configured inbound source chain (same as `onlyValidChain`) regardless of `returnToSourceChain`; returns `0` instead of reverting when `amount` is zero, the fee consumes the amount, or the vault preview is zero. Still reverts for a disabled target, a disabled path, a token that matches neither vault asset nor share, or a vault `preview*` revert. |
| `ROUTER` | Immutable router address (getter). |
| `chains(uint64)`, `enabledTargets(address)`, `depositsEnabled`, `redeemsEnabled` | Gates for showing deposit vs redeem UI. |
| `assetFees(uint64 destinationChainSelector, address bridgedToken)` | Show approximate flat fee (in vault underlying units) for bridge-back flows. |
| `collectedFees(address asset)` | Treasury / ops dashboards. |
| `messageErrorCode(bytes32 messageId)` | `NONE` (0), `BASIC` (1, failed and recoverable), `RESOLVED` (2). |
| `getFailedMessageRecord(bytes32 messageId)` | Refund-relevant stored fields: `sourceChainSelector`, `sender`, `destTokenAmounts`, `localRefundAddress`. Omits unused `messageId` / full `data`. |
| `checkLocalRecoveryEligibility(bytes32 messageId)` | Non-reverting preflight for local recovery by `localRefundAddress`. |
| `getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes)` | Returns `ccvConfigs[sourceChainSelector]` CCV arrays, `optionalThreshold`, and `inboundFinality[sourceChainSelector]` as `allowedFinalityConfig`. Second argument unused (interface parity). |
| `inboundFinality(uint64)` | Per-selector inbound bitmask advertised via `getCCVsAndFinalityConfig`. |
| `evmReturnExtraArgsFormat(uint64 destinationChainSelector)` | Per-lane outbound EVM return/refund format (`0` UNSET = legacy V2, `1` LEGACY_EXTRA_ARGS_V2, `2` GENERIC_EXTRA_ARGS_V3_BASIC). |
| `evmReturnRequestedFinality(uint64 destinationChainSelector, address token)` | Per (destination selector, bridged token) `requestedFinality` used when the lane is V3 basic. |

### CCIP `gasLimit` on the source send

Destination execution gas for `ccipReceive` and `processMessage` is not configured on this contract; it is supplied by the `extraArgs.gasLimit` of the source-chain send. This repo’s `e2e/ccip/shared.ts` estimates it via `estimateReceiveExecution` from `@chainlink/ccip-sdk` and applies `E2E_CCIP_GAS_MULTIPLIER_BPS`—reuse that pattern for production frontends/SDK integrations.

### Events to index

See [Events](#events-complete-list) below; primary UX signals: `MessageSucceeded`, `MessageFailed`, `TargetProcessed`, `LocalTokenDelivered`, `MessageSent`, `MessageRefunded`, `ProcessingEnabledSet`, `TargetEnabled`, `AssetFeeSet`.

---

## Types and constants

### Structs

`FailedMessageRecord`: `sourceChainSelector`, `sender`, `destTokenAmounts`, `localRefundAddress`. Stored on inbound failure instead of the full `Client.Any2EVMMessage` so refund paths do not copy unused dynamic `data`.

`CCVConfig`: `requiredCCVs`, `optionalCCVs`, `optionalThreshold`. Stored per inbound `sourceChainSelector` in `ccvConfigs`.

### Enums

`ChainType`: `NONE` (0), `EVM` (1), `SVM` (2).

`EvmReturnExtraArgsFormat`: `UNSET` (0), `LEGACY_EXTRA_ARGS_V2` (1, CCIP v1 lanes), `GENERIC_EXTRA_ARGS_V3_BASIC` (2, CCIP v2 lanes). Stored per `destinationChainSelector` in `evmReturnExtraArgsFormat`; `UNSET` / never-written encodes as legacy V2 on send (`setEvmReturnLaneFormat` rejects `UNSET` as an explicit write). Per-token finality for V3 lanes lives separately in `evmReturnRequestedFinality`.

`ErrorCode`: `NONE` (0), `BASIC` (1, failed and recoverable), `RESOLVED` (2).

### Constants

| Name | Value / role |
|------|----------------|
| `FEE_SETTER_ROLE` | `keccak256("FEE_SETTER_ROLE")` |
| `FEE_COLLECTOR_ROLE` | `keccak256("FEE_COLLECTOR_ROLE")` |
| `CCIP_MESSAGE_PAYLOAD_LENGTH` | `128` |
| `typeAndVersion` (adapter) | `"CrossChainERC4626Adapter 1.0.0"` |
| `typeAndVersion` (factory) | `"CrossChainERC4626AdapterFactory 1.0.0"` |

---

## Public and external functions

| Function | Access | Notes |
|----------|--------|------|
| `constructor` | | See [constructor](#crosschainerc4626adapter-constructor). |
| `receive()` | `payable` | Accepts native for `ccipSend`. |
| `supportsInterface(bytes4)` | `view` | CCIP receiver + enumerable access control introspection. |
| `setEvmReturnLaneFormat` | `DEFAULT_ADMIN_ROLE` | Per-destination-lane EVM return `extraArgs` format. |
| `setEvmReturnRequestedFinality` | `DEFAULT_ADMIN_ROLE` | Per (destination selector, token) V3 `requestedFinality`. |
| `setChainType` | `DEFAULT_ADMIN_ROLE` | |
| `setTargetEnabled` | `DEFAULT_ADMIN_ROLE` | |
| `setProcessingEnabled` | `DEFAULT_ADMIN_ROLE` | |
| `setAssetFee` | `FEE_SETTER_ROLE` | |
| `setAssetFees` | `FEE_SETTER_ROLE` | |
| `setInboundFinality` | `DEFAULT_ADMIN_ROLE` | Row in `inboundFinality`. |
| `setCCVsConfig` | `DEFAULT_ADMIN_ROLE` | Per-`sourceChainSelector` CCV arrays + optional threshold. |
| `withdrawFee` | `FEE_COLLECTOR_ROLE`, `nonReentrant` | |
| `recoverNative` | `DEFAULT_ADMIN_ROLE`, `nonReentrant` | |
| `getFailedMessageRecord` | `view` | Minimal stored failure snapshot for refund tooling. |
| `ccipReceive` | `onlyRouter` | `try` / bare `catch` around `this.processMessage`; emits `MessageSucceeded` / `MessageFailed`. |
| `processMessage` | `onlySelf` + `onlyValidChain` | Callable only via `address(this)` (router → `ccipReceive` path). |
| `preview` | `view` | Slippage / fee UX helper. |
| `refundFailedMessage` | `payable`, `nonReentrant` | Permissionless caller; `msg.value` pays outbound CCIP fees. |
| `recoverFailedMessageLocally` | `nonReentrant` | Callable only by stored `localRefundAddress`; transfers inbound tokens on this chain. |
| `checkRefundEligibility` | `view` | Returns `canRefund = false` instead of reverting for the `MessageNotFailed`, sender-length, and no-amount cases; the router `getFee` call it makes can still revert. |
| `checkLocalRecoveryEligibility` | `view` | Non-reverting preflight for local recovery. |
| `estimateRefundFee` | `view` | Sum of `getFee` estimates (`router` state may change leg-by-leg). |
| `getCCVsAndFinalityConfig` | `view`, `virtual` | CCIP v2 metadata for `sourceChainSelector`; `allowedFinalityConfig` is `inboundFinality[sourceChainSelector]`. |

Immutable and state getters: `ROUTER`, `depositsEnabled`, `redeemsEnabled`, `chains`, `enabledTargets`, `assetFees`, `collectedFees`, `messageErrorCode`, `refundChainFamilySnapshot`, `evmReturnExtraArgsFormat`, `evmReturnRequestedFinality`, `inboundFinality`, `typeAndVersion`, `CCIP_MESSAGE_PAYLOAD_LENGTH`, `FEE_SETTER_ROLE`, `FEE_COLLECTOR_ROLE`, `DEFAULT_ADMIN_ROLE`. CCV arrays and optional threshold are per `sourceChainSelector` in internal `ccvConfigs`—use `getCCVsAndFinalityConfig`. `failedMessageRecords` is internal—use `getFailedMessageRecord`.

Internal only (not callable externally): `sendToken`, `_buildOutboundMessage`, `_buildReturnLegExtraArgs`, `_normalizeToBytes32`, `_estimateRefundFee`, `_processTarget`, `_bytes32ToAddress`, etc.

---

## Events (complete list)

### `CrossChainERC4626Adapter`

| Event | When |
|-------|------|
| `MessageSent(..., ChainType indexed chainType, ...)` | After `ccipSend` in `sendToken`. `chainType` is the effective EVM vs SVM wire family for that send (return legs follow live `chains[destinationChainSelector]`; refund legs follow the failure snapshot / inferred family, which can differ from live `chains` after admin changes). |
| `MessageSucceeded(bytes32 indexed messageId)` | `processMessage` completes without revert (inside `try`). |
| `MessageFailed(bytes32 indexed messageId)` | `processMessage` reverted inside bare `catch`. Revert data is intentionally not logged to keep the handler non-reverting. The CCIP message still shows `SUCCESS` on the CCIP Explorer. |
| `MessageRefunded(bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary)` | Successful `refundFailedMessage`. |
| `MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress)` | Successful `recoverFailedMessageLocally`. |
| `TargetProcessed(bytes32 indexed messageId, address indexed target, address indexed inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount)` | After vault interaction succeeds. |
| `TargetEnabled(address indexed target, bool enabled)` | `setTargetEnabled`. |
| `ChainTypeSet(uint64 indexed chainSelector, ChainType chainType)` | `setChainType`. |
| `ProcessingEnabledSet(bool depositsEnabled, bool redeemsEnabled)` | `setProcessingEnabled`. |
| `AssetFeeSet(uint64 indexed destinationChainSelector, address indexed bridgedToken, uint256 fee)` | `setAssetFee` / `setAssetFees`. |
| `CCVsConfigSet(uint64 indexed sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold)` | `setCCVsConfig`. |
| `InboundFinalitySet(uint64 indexed sourceChainSelector, bytes4 allowedFinalityConfig)` | `setInboundFinality`. |
| `EvmReturnLaneFormatSet(uint64 indexed destinationChainSelector, EvmReturnExtraArgsFormat format)` | `setEvmReturnLaneFormat`. |
| `EvmReturnRequestedFinalitySet(uint64 indexed destinationChainSelector, address indexed token, bytes4 requestedFinalityForV3)` | `setEvmReturnRequestedFinality` (emits `bytes4(0)` when clearing on a legacy lane). |
| `FeeWithdrawn(address indexed asset, address indexed recipient, uint256 amount)` | `withdrawFee`. |
| `NativeRecovered(address indexed recipient, uint256 amount)` | `recoverNative`. |
| `LocalTokenDelivered(bytes32 indexed messageId, address indexed token, address indexed beneficiary, uint256 amount)` | Local `safeTransfer` path. |

### `CrossChainERC4626AdapterFactory`

| Event | When |
|-------|------|
| `AdapterDeployed(address indexed adapter, address indexed router, address indexed defaultAdmin, address feeSetter, address feeCollector, address vaultTarget, bool targetEnabled, bool depositsEnabled, bool redeemsEnabled)` | End of `deploy`. |

---

## Errors (custom)

Every custom error the adapter can revert with. Errors raised inside `processMessage` are caught by `ccipReceive`
(the message is stored as failed and `MessageFailed` is emitted) rather than reverting the CCIP execution.

| Error | Raised when |
|-------|-------------|
| `InvalidRouter(address router)` | The constructor router is `address(0)`, or `ccipReceive` is called by an address other than `ROUTER`. |
| `InvalidAdmin()` | `defaultAdmin` is `address(0)` (constructor or factory `deploy`). |
| `InvalidFeeSetter()` | `feeSetter` is `address(0)` (constructor or factory `deploy`). |
| `InvalidFeeCollector()` | `feeCollector` is `address(0)` (constructor or factory `deploy`). |
| `InvalidRecipient()` | `withdrawFee` or `recoverNative` was given `address(0)` as the recipient. |
| `InvalidChain(uint64 chainSelector)` | The selector is `NONE` in `chains`: inbound source in `processMessage` (`onlyValidChain`, caught), `assetFeeDestinationChainSelector` in `preview`, or an outbound return or refund whose effective encoding family is `NONE`. Fee setters do not check `chains`. |
| `OnlySelf()` | `processMessage` was called by any address other than the adapter itself. |
| `AmountIsZero()` | Zero inbound token amount (caught), zero `withdrawFee` amount, zero native balance in `recoverNative`, or a zero-amount outbound send. |
| `InvalidEVMAddress(bytes32 beneficiary)` | A `beneficiary` for local delivery or for a return to an EVM chain has non-zero upper 96 bits. |
| `InvalidSenderAddressFormat()` | The stored inbound sender is not exactly 32 bytes (`refundFailedMessage`, `estimateRefundFee`). |
| `InsufficientNativeBalance(uint256 requiredFee, uint256 availableBalance)` | The adapter's native balance cannot pay the CCIP fee of an outbound send. |
| `InsufficientRecoveryFee(uint256 requiredFee, uint256 providedFee)` | `msg.value` of `refundFailedMessage` is below the fees actually paid for the refund legs. |
| `InsufficientFeeBalance(uint256 availableBalance, uint256 requestedAmount)` | `withdrawFee` amount exceeds `collectedFees[asset]` (a token balance shortfall reverts in the token transfer instead). |
| `MessageNotFailed(bytes32 messageId)` | The message is not in `BASIC` state (`refundFailedMessage`, `estimateRefundFee`, `recoverFailedMessageLocally`). |
| `InvalidTarget(address target)` | The payload `target` is not enabled (caught), `preview` was called for a disabled vault, or a zero `target` / `bridgedToken` / `token` was passed to `setTargetEnabled`, `setAssetFee(s)`, or `setEvmReturnRequestedFinality`. |
| `InvalidTargetToken(address target, address token)` | The inbound token is neither the vault asset nor the vault share token. |
| `InvalidTokenCount(uint256 tokenCount)` | The inbound message does not carry exactly one token amount. |
| `InvalidPayloadLength(uint256 length, uint256 expected)` | Inbound `message.data` is not exactly 128 bytes. |
| `FeeConfigLengthMismatch()` | `setAssetFees` arrays have different lengths. |
| `InvalidEvmReturnExtraArgsFormat()` | `setEvmReturnLaneFormat` was called with `UNSET`. |
| `UnexpectedRequestedFinalityForLegacyFormat(bytes4 requestedFinalityForV3)` | Non-zero finality was set for a lane that resolves to legacy V2. |
| `RequestedFinalityCanOnlyHaveOneMode(bytes4 encodedFinality)` | From Chainlink `FinalityCodec`: the requested finality combines more than one mode (a flag plus a block depth, or several flags). |
| `InvalidOptionalThreshold(uint8 optionalThreshold, uint256 optionalCCVCount)` | The optional CCV threshold exceeds the number of optional CCVs. |
| `OptionalCCVsRequirePositiveThreshold(uint256 optionalCCVCount)` | Optional CCVs were supplied with a zero threshold. |
| `DuplicateCCV(address ccv)` | A CCV appears more than once across `requiredCCVs` and `optionalCCVs`. |
| `InvalidOptionalCCV()` | `address(0)` appears in `optionalCCVs` (it is allowed in `requiredCCVs`). |
| `DepositsDisabled()` | Deposit path while `depositsEnabled` is false (caught in `processMessage`; reverts in `preview`). |
| `RedeemsDisabled()` | Redeem path while `redeemsEnabled` is false (caught in `processMessage`; reverts in `preview`). |
| `FeeExceedsAmount(uint256 amount, uint256 fee)` | The return-leg fee is greater than or equal to the deposit amount or the redeemed assets. |
| `MinimumOutputNotMet(uint256 minimumOut, uint256 actualOut)` | The output after the fee is below the payload `minimumOut`. |
| `NoOutputReceived()` | The vault action produced zero output. |
| `RefundFailed()` | Returning excess `msg.value` to the `refundFailedMessage` caller failed. |
| `RecoverNativeFailed()` | The `recoverNative` transfer failed (typically a recipient that rejects native tokens). |
| `NoRefundableTokenAmounts()` | The failed message has no non-zero `destTokenAmounts` entry to refund or recover. |
| `NoLocalRefundAddress(bytes32 messageId)` | Local recovery was requested but the failed message has no `localRefundAddress`. |
| `UnauthorizedLocalRefund(address caller, address localRefundAddress)` | The caller of `recoverFailedMessageLocally` is not the stored `localRefundAddress`. |

Inherited OpenZeppelin errors include `AccessControlUnauthorizedAccount` (missing role), `AccessControlBadConfirmation`, and `ReentrancyGuardReentrantCall`.

Revert data from underlying `SafeERC20`, `IERC4626`, or `IRouterClient` is not surfaced on-chain when inbound processing fails; inspect the failing `processMessage` path off-chain if diagnostics are needed.

---

## Limitations

- Default vault logic assumes a standard ERC-20 underlying and share token; fee-on-transfer and rebasing semantics are not reflected in `minimumOut` or `collectedFees` accounting.
- The EVM return and refund `extraArgs` format is per `destinationChainSelector` (`setEvmReturnLaneFormat`); on V3 lanes, `requestedFinality` is per `(destinationChainSelector, bridged token)` (`setEvmReturnRequestedFinality`) for the actual token on that leg (vault share or underlying). Unset format storage encodes as legacy V2.
- Core handlers are not `virtual`; changing behavior requires forking and redeploying, not subclass overrides on untouched bytecode.
