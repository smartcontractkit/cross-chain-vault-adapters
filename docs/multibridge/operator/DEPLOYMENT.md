# Deployment guide

Two roles:

- **Protocol deployer** — publishes the implementation and the factory once per chain (§1).
- **Vault issuer** — deploys and activates their own app from the factory's *Write Contract* page on
  a block explorer (§2), then grants fee roles if needed (§3) and validates (§4).

The app uses a **non-upgradeable EIP-1167 clone** model: one published `CrossChainVaultAdapter`
implementation, and a `CrossChainVaultAdapterFactory` bound to it that clones + initializes + configures it
per vault.

> **Scope of this guide.** This walks the **basic factory `deploy`** by hand. The `DeployConfig` here
> installs the inbound/outbound **allowlists, the OFT map, and return-leg fees**; the **route registry** (the per-`(token,
> destination)` rail choice — `LZ_OFT`/`CCIP`/`STARGATE`/`CCIP_SVM`/`LOCAL`, plus `setStargateDestination`
> / `setCcipSvmConfig`) is configured by the **admin after deploy** (`setRoute`, …), or installed atomically by
> the production script. For a **multi-network production deploy** — a `Networks` address book + a
> high-level `routes[]` config that wires the whole registry — use
> [`DeployProduction.s.sol`](../../../script/multibridge/DeployProduction.s.sol); see **[`DEPLOYMENT_CONFIG.md`](./DEPLOYMENT_CONFIG.md)**.

---

## 1. Protocol deployer — publish implementation + factory

Run from the repository root:

```bash
pnpm multibridge:deploy-factory --rpc-url <RPC_URL> --account <KEYSTORE> --broadcast --verify --etherscan-api-key <KEY>
```

`pnpm multibridge:deploy-factory` runs
[`DeployImplementationAndFactory`](../../../script/multibridge/DeployImplementationAndFactory.s.sol)
(`script/multibridge/DeployImplementationAndFactory.s.sol:DeployImplementationAndFactory`) with
`FOUNDRY_PROFILE=deploy`, the deploy compiler settings; extra arguments pass through to `forge script`.
Use any `forge script` signer option (`--account`, `--ledger`, `--private-key`).

It prints two addresses:

- `CrossChainVaultAdapter implementation` — the adapter logic; **inert** (its initializers are disabled),
  used only via clones. Verify its source on the explorer so issuers can inspect it.
- `CrossChainVaultAdapterFactory` — bound to that implementation (`i_implementation`).

Neither takes per-chain config at construction; all of that is supplied later in `factory.deploy`.
Publish both **verified addresses** to your issuers.

---

## 2. Vault issuer — `deploy` on the factory's Write Contract page

Open the **verified factory** on the explorer → **Contract → Write Contract → Connect Wallet →
`deploy`**. The function takes one tuple (`DeployConfig`) and is `payable`.

### 2.1 The `payableAmount` field

`payableAmount` (or "value") is native gas forwarded into the new app to pay future **outbound**
CCIP/LayerZero fees. Enter an amount (e.g. `0.5` ether) or `0` and fund the app later by sending it
native directly. Outbound sends fail (recoverably) if the app has no native balance.

### 2.2 The `config` tuple — field order and meaning

The explorer renders `config` as **one input box** expecting a JSON array of the fields **in this exact
order**. Parallel arrays (same length) are paired by index. Use `[]` for an empty array.

| # | Field | Type | What to enter |
|---|-------|------|---------------|
| 1 | `ccipRouter` | address | The CCIP Router on **this** chain (Chainlink CCIP Directory). |
| 2 | `lzEndpoint` | address | The LayerZero **EndpointV2** on this chain (LayerZero deployments). |
| 3 | `owner` | address | Your **admin** address; receives `DEFAULT_ADMIN_ROLE` and `FEE_SETTER_ROLE` (and `FEE_COLLECTOR_ROLE` unless `feeCollector` is set) at deploy. Must not be the factory. |
| 4 | `feeCollector` | address | Address for `FEE_COLLECTOR_ROLE` (`withdrawCollectedFee`); `address(0)` => same as `owner`. |
| 5 | `vault` | address | The ERC-4626 vault this app serves (its share token is the vault address). |
| 6 | `lzSrcEids` | uint32[] | Source LayerZero **EIDs** you accept inbound deposits/redeems from. |
| 7 | `lzSrcOfts` | address[] | For each `lzSrcEids[i]`, the OFT contract on **this** chain that delivers the token via `lzCompose` (e.g. the USDT0 OFT). |
| 8 | `ccipSrcSelectors` | uint64[] | Source CCIP **chain selectors** you accept inbound from. |
| 9 | `ccipDstSelectors` | uint64[] | CCIP destination selectors you will bridge results **out** to. |
| 10 | `lzDstEids` | uint32[] | LayerZero destination EIDs you will bridge results **out** to. |
| 11 | `oftTokens` | address[] | Tokens you will send **out** over LayerZero (the asset and/or the share token). |
| 12 | `ofts` | address[] | For each `oftTokens[i]`, the OFT whose `token()` is that token. |
| 13 | `requireLzReturnPrefunded` | bool | Require LayerZero inbound to prefund the return-leg native fee. |
| 14 | `inboundFeeOutboundTokens` | address[] | CCIP inbound fee: the produced token (vault share on deposit, asset on redeem). |
| 15 | `inboundFeeDestinations` | uint64[] | CCIP inbound fee: the `VaultMessage.destination` route key. |
| 16 | `inboundFeeAmounts` | uint256[] | CCIP inbound fee: flat amount in inbound-token units. Use empty arrays for 14 to 16 if unused. |

EID is a LayerZero endpoint ID; OFT is LayerZero's Omnichain Fungible Token standard.

Notes:
- Inbound is gated by `(srcEid, oft)` for LayerZero and by **source chain selector** for CCIP (any sender
  on an allowlisted chain). A LayerZero compose from an unlisted pair reverts; a CCIP message from an
  unlisted chain is captured as a failed message, refundable to its sender.
- Outbound destinations must be listed in 9/10. Stargate destinations and Solana (SVM) lanes are not in
  `DeployConfig`; the admin sets them after deploy (`setStargateDestination`, `setCcipSvmConfig`).
- Without a registry route, a produced token leaves over LayerZero only if it has an entry in 11/12,
  otherwise over CCIP (a CCT) to a `ccipDstSelector`. Entries in 11/12 also let the adapter bounce a
  LayerZero inbound back to source.
- The asset and the share token can each independently use either rail; list whichever applies.

### 2.3 Worked example

Deposits arrive from Arbitrum over LayerZero (USDT0 OFT) **and** over CCIP (from any sender there);
results bridge out to the Arbitrum CCIP selector and LZ EID; the asset (USDT0) and share token both
have OFTs. Paste into the `config` box:

```json
[
  "0xCcipRouterOnThisChain",
  "0xLzEndpointV2OnThisChain",
  "0xYourOwnerAddress",
  "0xYourFeeCollectorBotOrZero",
  "0xYourErc4626Vault",
  [30110],
  ["0xUsdt0OftOnThisChain"],
  [4949039107694359620],
  [4949039107694359620],
  [30110],
  ["0xUsdt0OftUnderlyingToken", "0xYourErc4626Vault"],
  ["0xUsdt0OftOnThisChain", "0xShareTokenOft"],
  false,
  [],
  [],
  []
]
```

Set `payableAmount` to e.g. `0.5`, then **Write**.

---

## 3. Access control (roles)

`deploy` grants **`DEFAULT_ADMIN_ROLE`** to your `owner` address immediately — there is no two-step
accept step. The app is operational as soon as the factory transaction confirms.

Adapters use OpenZeppelin **AccessControl** with three operator-facing roles (see
[`src/multibridge/AdapterRoles.sol`](../../../src/multibridge/AdapterRoles.sol)):

| Role | Purpose |
|------|---------|
| `DEFAULT_ADMIN_ROLE` | Routes, allowlists, `setOftForToken`, `setDestinationGas`, `recoverNative`, `grantRole` / `revokeRole`, `transferAdmin` |
| `FEE_SETTER_ROLE` | `setInboundFee`, `setRequireLzReturnPrefunded` — safe to delegate to a fee bot |
| `FEE_COLLECTOR_ROLE` | `withdrawCollectedFee` — safe to delegate to a collector bot |

During `deploy` the factory is the clone's temporary holder of all three roles while it installs the
config. It then grants `DEFAULT_ADMIN_ROLE` and **`FEE_SETTER_ROLE`** to `config.owner`, grants
**`FEE_COLLECTOR_ROLE`** to `config.feeCollector` (or `owner` when zero), and revokes all of its own
roles.

To hand admin to a multisig later, the current admin calls
**`transferAdmin(newAdmin, feeSetter, feeCollector)`** (one step). It reverts if `newAdmin` is the caller
or `address(0)`; pass the new fee-role holders to migrate them too, or `address(0)` to leave a fee role
with the current holder.

You can then manage the app (e.g. `setCcipSource`, `setLzOft`, `setCcipDestination`,
`setLzDestination`, `setOftForToken`, `setDestinationGas`, `setRoute`, `transferAdmin`). Optionally call
`setRequireLzReturnPrefunded(true)` so LayerZero-originated messages must pre-pay their return-leg fee
(via the compose `value`) rather than drawing the operator's reserve; the surplus is returned to the
message's `failedMessageHandler` (or stays in the reserve when there is none).

For production deploys that install the full route registry in-script, see
[`DeployProduction.s.sol`](../../../script/multibridge/DeployProduction.s.sol) (`pnpm multibridge:deploy`,
described in [`DEPLOYMENT_CONFIG.md`](./DEPLOYMENT_CONFIG.md)). The deployer is temporary admin during
`deploy`, installs routes, then calls `transferAdmin` (admin and fee roles) to `home.owner` if different.

---

## 4. Validate a deployment

- Confirm the new app is a **standard EIP-1167 minimal proxy** whose implementation is the published
  `CrossChainVaultAdapter` — most explorers auto-label it *"Minimal Proxy (EIP-1167) for 0xImpl."*
  Every clone runs the same implementation logic. `typeAndVersion()`
  returns `"CrossChainVaultAdapter 1.0.0"`.
- Confirm config via the app's read functions: `s_vault`, `s_asset`, `s_ccipRouter`, `s_lzEndpoint`,
  `s_ccipSourceAllowed`, `s_lzOftAllowed`, `s_ccipDestAllowed`, `s_lzDestAllowed`,
  `s_stargateDestAllowed`, `s_ccipSvm`, `s_oftForToken`, `s_route(token, destination)`, `s_dstGas`,
  `s_requireLzReturnPrefunded`, `s_inboundFees(outToken, destination)`, `s_collectedFees(token)`,
  `paused()`, and `hasRole(DEFAULT_ADMIN_ROLE, admin)` / `hasRole(FEE_SETTER_ROLE, …)` /
  `hasRole(FEE_COLLECTOR_ROLE, …)`. The inspect script
  (`HUB_RPC_URL=… ADAPTER=0x… pnpm e2e:multibridge inspect:adapter`, source
  [`e2e/multibridge/src/inspect-adapter.ts`](../../../e2e/multibridge/src/inspect-adapter.ts)) lists role
  holders, routes, return-leg fee config, and accrued inbound fees.

---

## Where to find the inputs

| Input | Source |
|-------|--------|
| CCIP Router address, CCIP chain selectors | [Chainlink CCIP Directory](https://docs.chain.link/ccip/directory/mainnet) |
| LayerZero EndpointV2 address, EIDs | [LayerZero documentation](https://docs.layerzero.network) |
| USDT0 OFT and token addresses | [USDT0 documentation](https://docs.usdt0.to) |
| Mainnet values used by the scripts | [`script/multibridge/config/Networks.sol`](../../../script/multibridge/config/Networks.sol) (verify before use) |

> Preconditions (out of scope of this app): the share token's CCIP token pool (CCT) and the OFT
> peers/DVNs for each lane must already be configured for the tokens you route. USDT0 (LZ) and Stargate
> are the practical rails for native USDT; CCIP applies to tokens you control.
