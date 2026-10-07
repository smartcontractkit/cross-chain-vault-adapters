# Cross-chain ERC-4626 adapter deployment guide

This guide covers three ways to get a `CrossChainERC4626Adapter` instance:

1. [Foundry scripts (recommended)](#recommended-path-foundry-scripts): `pnpm ccip:deploy` deploys a factory (or reuses one) and a fully configured adapter in one broadcast, `pnpm ccip:configure` applies the CCIP v2 lane and funding settings the factory does not cover, and `pnpm ccip:check` verifies the result. Everything is driven by one `.env` file.
2. [Path A, pre-deployed factory](#path-a-deploy-via-a-pre-deployed-factory-block-explorer): call `deploy(DeploymentConfig)` on an existing `CrossChainERC4626AdapterFactory` from a block explorer Write Contract page, or from any wallet or SDK that can encode the struct.
3. [Path B, adapter only](#path-b-deploy-the-adapter-with-foundry-constructor-only): broadcast `new CrossChainERC4626Adapter(...)` with `pnpm ccip:deploy-adapter-only`, then configure chains, targets, fees, and return-leg policy yourself.

For ongoing operation, CCIP return-leg setup, and roles, see the [operator guide](cross-chain-erc4626-adapter-operator-guide.md). For the end-user message flow, see the [user journey](cross-chain-erc4626-adapter-user-journey.md). For ABI-level detail, see the [contract reference](cross-chain-erc4626-adapter-contract-reference.md).

---

## Deployment prerequisites

Before deploying an adapter, confirm the following:

- The vault share token and the underlying vault asset token must both be enabled on Chainlink CCIP for the lanes you will use.
- The target vault must comply with the standard ERC-4626 interface: synchronous, atomic deposits and redemptions, and a single underlying asset.
- The vault must not enforce address-specific deposit or redemption restrictions, such as user allowlists or mandatory cooldown periods.
- The chain must support the Shanghai upgrade: the adapter and factory bytecode uses the `PUSH0` opcode (it is compiled for cancun, but no Cancun-only opcode is emitted).

These are operational requirements outside the factory `deploy` call. If CCIP is not enabled for the share or asset token, or the vault is non-standard, inbound messages will fail or behave unpredictably even when the adapter deploys successfully.

---

## What to decide before deploying

| Item | Notes |
|------|--------|
| Factory address | Path A only, optional for the scripts: a verified `CrossChainERC4626AdapterFactory` on the same chain where the adapter will live. The scripts deploy a new one when `FACTORY` is unset. |
| CCIP router | The CCIP router on the chain where the adapter will live, from the [CCIP directory](https://docs.chain.link/ccip/directory). Immutable on the adapter as `ROUTER`. |
| `defaultAdmin` | Multisig or governance; receives `DEFAULT_ADMIN_ROLE`. |
| `feeSetter`, `feeCollector` | Addresses for `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE`. They can equal `defaultAdmin`. With the factory, each role goes only to its configured address, so `defaultAdmin` holds the fee roles only if you pass it for them too. |
| `vaultTarget` | ERC-4626 vault the adapter will call. Use `address(0)` only if you will enable a target later with `setTargetEnabled` (the factory skips target wiring when it is zero). |
| `targetEnabled` | Whether `vaultTarget` is allowlisted immediately (ignored if `vaultTarget == address(0)`). |
| `depositsEnabled`, `redeemsEnabled` | Operational switches for the deposit and redeem paths. |
| `chainConfigs` | Each entry: CCIP chain selector and type, `0 = NONE`, `1 = EVM`, `2 = SVM`. Every source chain you expect inbound messages from must be non-`NONE`; return legs to that chain use the same entry for outbound encoding. |
| `feeConfigs` | Optional per-destination flat fees (see the [operator guide](cross-chain-erc4626-adapter-operator-guide.md#setassetfeeuint64-destinationchainselector-address-bridgedtoken-uint256-fee)). Fees can be staged for a selector that is not yet configured (setting a fee does not check `chains`), but a fee only applies on return legs, which require the selector to be configured. |

---

## Recommended path: Foundry scripts

All commands run from the repo root. Forge loads `.env` from the repo root automatically, and `--rpc-url ccip`
resolves to `RPC_URL` from that file (see the `[rpc_endpoints]` section of `foundry.toml`).

| Command | Script | What it does |
|---|---|---|
| `pnpm ccip:deploy` | `DeployAndActivateCrossChainERC4626Adapter.s.sol` | Deploys a factory (or uses `FACTORY`) and an adapter with chain types, vault target, processing toggles, fees and roles |
| `pnpm ccip:configure` | `ConfigureCrossChainERC4626Adapter.s.sol` | Sets return-lane formats, return and inbound finality, CCVs, and native funding |
| `pnpm ccip:check` | `CheckCrossChainERC4626Adapter.s.sol` | Read-only report of the adapter, with warnings for common misconfigurations |
| `pnpm ccip:deploy-factory` | `DeployCrossChainERC4626AdapterFactory.s.sol` | Deploys only a factory, for later `deploy` calls (Path A) |
| `pnpm ccip:deploy-adapter-only` | `DeployCrossChainERC4626Adapter.s.sol` | Constructor-only deploy (Path B) |
| `pnpm ccip:build-payload` | `BuildPayload.s.sol` | Read-only: previews a deposit or a redemption, applies the tolerance, and prints the 128-byte user request payload |

The scripts live in `script/ccip/`.

### 1. Fill in `.env`

```bash
cp .env.example .env
```

Every variable is documented in [`.env.example`](../../.env.example). The minimum for `ccip:deploy` is `RPC_URL`,
`ROUTER`, `DEFAULT_ADMIN`, `FEE_SETTER`, `FEE_COLLECTOR`, `DEPOSITS_ENABLED` and `REDEEMS_ENABLED`; in practice also set
`VAULT_TARGET`, `CHAIN_SELECTORS` / `CHAIN_TYPES` for every chain that sends to or receives from the adapter, and any
return-leg fee rows (`FEE_DESTINATION_CHAIN_SELECTORS`, `FEE_BRIDGED_TOKENS`, `FEE_VALUES`). Router addresses and
chain selectors are in the [CCIP directory](https://docs.chain.link/ccip/directory).

### 2. Dry run, then deploy

```bash
pnpm ccip:deploy --rpc-url ccip                                           # simulation only
pnpm ccip:deploy --rpc-url ccip --account deployer --broadcast --verify --delay 20 --retries 12
```

Before broadcasting, the script checks that `ROUTER` (and `FACTORY`, if set) has code, that `FACTORY` reports the
factory `typeAndVersion`, that `VAULT_TARGET` answers `asset()`, that chain types are 0 to 2 and that list lengths
match, and reverts with an error naming the variable otherwise. With `--broadcast` it writes
`deployments/ccip/<chainId>.json` (or `DEPLOYMENT_OUT`) with the factory, adapter, router, and role addresses; a dry
run writes nothing. `--account` uses a `cast wallet` keystore; `--private-key` and `--ledger` also work.

`--delay` and `--retries` matter for `--verify`: the adapter is created inside `factory.deploy()`, so the explorer
often needs more than the default 5 seconds before its bytecode is visible.

### 3. Configure CCIP v2 lanes and fund the adapter

The factory does not set return-lane formats, finality or CCVs. An unset lane encodes return legs as
`GenericExtraArgsV2`, which is correct for CCIP v1 lanes, so a v1-only deployment only needs funding. For each CCIP v2
lane, set `RETURN_LANE_SELECTORS` / `RETURN_LANE_FORMATS` (format `2`), then the per-token `RETURN_FINALITY_*` rows, and
optionally `INBOUND_FINALITY_*` and `CCV_*`. `FUND_NATIVE_WEI` sends native gas for return-leg CCIP fees. Set `ADAPTER`
to the deployed adapter and run as `DEFAULT_ADMIN`:

```bash
pnpm ccip:configure --rpc-url ccip --account admin --broadcast
```

The script applies lane formats before finality, which the contract requires. If `DEFAULT_ADMIN` is a multisig, run a
dry run with `--sender <multisig address>` (no `--broadcast`): Forge simulates the calls as the multisig and writes them
to `broadcast/ConfigureCrossChainERC4626Adapter.s.sol/<chainId>/dry-run/`, from which you can build the multisig
transaction. Funding needs no role.

### 4. Check

```bash
pnpm ccip:check --rpc-url ccip
```

The report shows roles for `DEFAULT_ADMIN` / `FEE_SETTER` / `FEE_COLLECTOR`, the vault target, processing toggles,
native balance, and for each of `CHAIN_SELECTORS` the chain type, return-lane format, inbound finality and fees. It
reads `ADAPTER`, or the deployment record when `ADAPTER` is unset, and exits with the number of warnings in its return
value.

---

## Path A: deploy via a pre-deployed factory (block explorer)

Use this when `CrossChainERC4626AdapterFactory` is already deployed and verified on the network where the adapter
should live. To deploy one, run `pnpm ccip:deploy-factory --rpc-url ccip --account deployer --broadcast --verify`.

### 1. Open the verified factory contract

On Etherscan, Basescan, or the chain’s explorer, open the factory at its address and go to Write Contract. Connect the wallet that will pay gas; any EOA or multisig may call `deploy`.

### 2. Call `deploy`

Function shape:

```text
deploy((address router, address defaultAdmin, address feeSetter, address feeCollector, address vaultTarget, bool targetEnabled, bool depositsEnabled, bool redeemsEnabled, (uint64 chainSelector, uint8 chainType)[] chainConfigs, (uint64 destinationChainSelector, address bridgedToken, uint256 fee)[] feeConfigs))
```

Explorers usually expand `DeploymentConfig` into separate fields.

#### Top-level tuple (`DeploymentConfig`)

| Field | Type | What to paste |
|--------|------|----------------|
| `router` | address | CCIP `Router` address on this chain (checksummed `0x…`). |
| `defaultAdmin` | address | Admin multisig or EOA. |
| `feeSetter` | address | Fee setter account. |
| `feeCollector` | address | Fee collector account. |
| `vaultTarget` | address | ERC-4626 vault, or `0x0000000000000000000000000000000000000000` to skip initial target wiring. |
| `targetEnabled` | bool | `true` or `false` (only applies if `vaultTarget` is non-zero). |
| `depositsEnabled` | bool | `true` or `false`. |
| `redeemsEnabled` | bool | `true` or `false`. |
| `chainConfigs` | array of structs | See below. Leave empty only if you will configure chains later with `setChainType` (not recommended for production). |
| `feeConfigs` | array of structs | See below. Use `[]` if you have no initial fee schedule. |

#### `chainConfigs[]` (each row)

| Sub-field | Type | What to paste |
|-----------|------|----------------|
| `chainSelector` | uint64 | CCIP chain selector (decimal string is fine in most UIs). |
| `chainType` | uint8 | `0` = NONE (disables), `1` = EVM, `2` = SVM. |

Add one row per remote chain.

#### `feeConfigs[]` (each row)

| Sub-field | Type | What to paste |
|-----------|------|----------------|
| `destinationChainSelector` | uint64 | Return-leg destination (the inbound source chain). It must be configured in `chainConfigs` for the fee to ever apply. |
| `bridgedToken` | address | Token bridged back on that return leg: the vault share (the vault address) for deposit returns, or the underlying for redeem returns. |
| `fee` | uint256 | Absolute fee in vault underlying smallest units (not basis points). |

#### Example values

This example deploys on Ethereum Sepolia with inbound lanes from Base Sepolia (EVM) and Solana devnet (SVM). Replace
every placeholder, selector, and fee with your own values before submitting, and confirm the router in the
[CCIP directory](https://docs.chain.link/ccip/directory/testnet).

| Field | Example value |
|--------|----------------|
| `router` | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` (Ethereum Sepolia router) |
| `defaultAdmin` | `<admin multisig address>` |
| `feeSetter` | `<fee setter address>` |
| `feeCollector` | `<fee collector address>` |
| `vaultTarget` | `<ERC-4626 vault address>` |
| `targetEnabled` | `true` |
| `depositsEnabled` | `true` |
| `redeemsEnabled` | `true` |
| `chainConfigs` | `[[10344971235874465080,1],[16423721717087811551,2]]` |
| `feeConfigs` | `[[10344971235874465080,<ERC-4626 vault address>,100]]` |

The `chainConfigs` rows enable Base Sepolia (`10344971235874465080`, EVM) and Solana devnet
(`16423721717087811551`, SVM). The `feeConfigs` row charges a flat `100` underlying units on deposit returns to Base
Sepolia: the bridged token on a deposit return is the vault share, so the row is keyed by the vault address.

Explorers differ in how they accept nested arrays: some take the literal above in one field; others expand `chainConfigs` and `feeConfigs` into per-item forms with the same numbers. For no fees, use `[]`, not a row of zeros.

### 3. Submit the transaction

On success:

- Note the new adapter address from the `AdapterDeployed` event, or from the transaction return value if the explorer shows it.
- The factory does not retain any role: it grants `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` to `defaultAdmin`, `feeSetter`, and `feeCollector`, then renounces them from itself.
- Continue with [After deployment](#after-deployment). You can point the scripts at the new adapter by setting `ADAPTER` in `.env`.

### 4. If the explorer only accepts raw calldata

Encode `deploy(DeploymentConfig)` off-chain (`cast calldata`, ethers, viem, and so on) using the verified ABI. Prefer the explorer form when available to avoid encoding mistakes.

---

## Path B: deploy the adapter with Foundry (constructor only)

Deploys `CrossChainERC4626Adapter` directly:

```solidity
constructor(address router_, address defaultAdmin, address feeSetter, address feeCollector)
```

No factory is involved. `defaultAdmin` receives all three roles, and `feeSetter` / `feeCollector` additionally receive their role. You must then call `setChainType`, `setTargetEnabled`, `setProcessingEnabled`, and the fee setters yourself, plus the CCIP v2 settings (`setEvmReturnLaneFormat`, `setEvmReturnRequestedFinality`, `setInboundFinality`, `setCCVsConfig`) where needed; see the [operator guide](cross-chain-erc4626-adapter-operator-guide.md#recommended-initial-setup-sequence).

- Script: `script/ccip/DeployCrossChainERC4626Adapter.s.sol` (`pnpm ccip:deploy-adapter-only`)
- Contract: `DeployCrossChainERC4626AdapterScript`
- Required environment variables: `ROUTER`, `DEFAULT_ADMIN`, `FEE_SETTER`, `FEE_COLLECTOR`, in `.env` at the repo root (Forge loads it automatically)

```bash
pnpm ccip:deploy-adapter-only --rpc-url ccip --account deployer --broadcast --verify --delay 20 --retries 12
```

Use `--private-key` instead of `--account` if that matches your workflow. The console output logs the new adapter
address and role recipients. After deploying, `pnpm ccip:configure` covers the CCIP v2 and funding settings; the chain
types, target, processing toggles and fees still need the admin and fee-setter calls listed above. This script does not
write a deployment record, so set `ADAPTER` for `ccip:configure` and `ccip:check`.

You can deploy the same bytecode with another toolchain (for example `forge create`); the constructor arguments and the post-deploy checklist are unchanged.

---

## After deployment

1. Verify the source on the block explorer (`--verify` does this for the scripted paths).
2. For CCIP v2 lanes, complete the return-lane formats, per-token return finality, inbound finality and CCV lists (`pnpm ccip:configure`, or `setEvmReturnLaneFormat`, `setEvmReturnRequestedFinality`, `setInboundFinality` and `setCCVsConfig` directly). CCIP v1 lanes need none of these.
3. Fund the adapter with native token for the outbound CCIP fees of `returnToSourceChain` deliveries (`FUND_NATIVE_WEI`). Refunds of failed messages are paid by the caller of `refundFailedMessage`, not from the adapter balance.
4. Run `pnpm ccip:check`, then a small deposit and redeem on your intended lane (see the [E2E harness](../../e2e/ccip/README.md)).
