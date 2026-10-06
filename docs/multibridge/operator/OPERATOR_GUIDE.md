# Operator guide

Day-to-day guide for running a hub vault adapter clone. You configure lanes and fees; you do not custody user tokens. Recovery from failed deliveries is permissionless or driven by the handler named in each message.

CCIP is Chainlink's Cross-Chain Interoperability Protocol; LZ is LayerZero, whose OFT (Omnichain Fungible Token) standard and EIDs (endpoint IDs) identify tokens and chains; CCT is the CCIP Cross-Chain Token standard; DVNs are LayerZero's decentralized verifier networks.

For contract design see [`FUNCTIONALITY.md`](../informational/FUNCTIONALITY.md). For deploy field order see [`DEPLOYMENT.md`](./DEPLOYMENT.md). For fee math see [`RETURN_LEG_HANDLING.md`](../informational/RETURN_LEG_HANDLING.md). For stuck messages see [`FAILED_MESSAGE_RESOLUTION.md`](../informational/FAILED_MESSAGE_RESOLUTION.md).

---

## What you operate

One EIP-1167 clone per vault on the hub chain. It:

1. Accepts inbound token deliveries over CCIP or LayerZero (including Stargate pools).
2. Deposits or redeems against your ERC-4626 vault.
3. Sends the result out over a configured rail (CCIP, LZ OFT, Stargate, Solana CCIP, or local transfer).

Users choose an allowed `destination` in their `VaultMessage`. You choose which spokes, rails, and fees are allowed.

---

## Before go-live

| Prerequisite | Who sets it up |
|---|---|
| CCIP router + chain selectors | Chainlink CCIP directory |
| LayerZero endpoint + EIDs | LayerZero deployments |
| Share token CCIP pool (CCT) | You, if shares leave over CCIP |
| OFT peers / DVNs | Token issuer, if asset or shares leave over LZ |
| Stargate pool on hub + spoke | Stargate, if you use Stargate rails |
| Native float on the adapter | You (`fundWei` at deploy or send ETH later) |

LZ compose-`value` surplus is refunded as **native ETH** (best-effort) to the message's
`failedMessageHandler`; with no handler (or if the handler rejects ETH) the surplus stays in the adapter's
native reserve. There is no WETH configuration.

---

## Roles

| Role | Typical holder | Main calls |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Multisig | Allowlists, `setRoute`, `setOftForToken`, `setDestinationGas`, `pause` / `unpause`, `recoverNative`, `transferAdmin`, `grantRole` / `revokeRole` |
| `FEE_SETTER_ROLE` | Fee bot | `setInboundFee`, `setRequireLzReturnPrefunded` |
| `FEE_COLLECTOR_ROLE` | Treasury bot | `withdrawCollectedFee` |

At factory deploy, admin and both fee roles go to `owner` (`feeCollector` in config overrides the collector only). Recovery (`refundToSource`, `retryFailedMessage`, `refundLocal`) needs no role.

> **Handing off the admin key?** `transferAdmin(newAdmin, feeSetter, feeCollector)` only migrates a fee
> role when its argument is **non-zero**. With `address(0)` the outgoing admin **keeps**
> `FEE_SETTER_ROLE` / `FEE_COLLECTOR_ROLE` — it can still set fees and withdraw collected fees until the
> new admin revokes them. Pass explicit non-zero fee-role recipients for a complete handoff; use the
> zero-address form only when dedicated fee bots should keep their roles across an admin rotation.

---

## Deploy and wire routes

### Implementation + factory

Once per chain, publish the `CrossChainVaultAdapter` implementation (`"CrossChainVaultAdapter 1.0.0"`) and a `CrossChainVaultAdapterFactory` bound to it with [`DeployImplementationAndFactory.s.sol`](../../../script/multibridge/DeployImplementationAndFactory.s.sol), from the repository root:

```bash
pnpm multibridge:deploy-factory --rpc-url <RPC_URL> --account <KEYSTORE> --broadcast --verify
```

The pnpm script sets `FOUNDRY_PROFILE=deploy`, which produces the deployment bytecode.

Issuers then clone from the factory with `factory.deploy(DeployConfig)` — see [`DEPLOYMENT.md`](./DEPLOYMENT.md).

### Production

Use [`DeployProduction.s.sol`](../../../script/multibridge/DeployProduction.s.sol) (`pnpm multibridge:deploy`) with a multi-network config in `config/multibridge/deployment.json`. It deploys the clone and installs routes, Stargate destinations, and Solana lanes in one broadcast. See [`DEPLOYMENT_CONFIG.md`](./DEPLOYMENT_CONFIG.md).

### Sepolia testnet

`config/multibridge/sepolia.json` ships without factory, implementation, or adapter addresses: deploy the adapter yourself. The scripts read `e2e/multibridge/.env` (`HUB_RPC_URL`, and `PRIVATE_KEY` or a Foundry keystore named by `FOUNDRY_ACCOUNT`, default `vaultdeployer`) and run from any directory.

```bash
# Once per chain: implementation + factory (paste the printed addresses into hub.factory / hub.implementation)
bash script/multibridge/deploy-factory-sepolia.sh

# Per vault clone
bash script/multibridge/deploy-adapter-sepolia.sh          # USDT vault
bash script/multibridge/deploy-adapter-usdc-sepolia.sh     # USDC vault (Fuji spoke)

# After editing config allowlists, routes, or fees
ADAPTER=0xYourClone bash script/multibridge/sync-hub-config-sepolia.sh
ADAPTER=0xYourUsdcClone bash script/multibridge/sync-hub-config-usdc-sepolia.sh
```

Paste new clone addresses into `config/multibridge/sepolia.json` (`hub.app`, `adapters.usdt.app`, `adapters.usdc.app`) before running e2e. See [`e2e/multibridge/README.md`](../../../e2e/multibridge/README.md).

### Per-spoke checklist

For each spoke you support:

```text
[ ] Inbound allowlist     setCcipSource(selector, true)  OR  setLzOft(eid, oft, true)
[ ] Outbound allowlist    setCcipDestination / setLzDestination / setStargateDestination
[ ] Return route          setRoute(outToken, destination, Route{ rail, endpoint, dstId })
[ ] Return-leg fee        see "Fees" below
[ ] Optional gas          setDestinationGas(destination, gasLimit)
```

A delivery needs both an enabled route and the matching outbound allowlist.

---

## Fees

Two mechanisms. Pick based on how the spoke sends inbound traffic.

### CCIP spokes

Set a token skim so the originator pays in the inbound token:

```solidity
setInboundFee(outboundToken, destination, fee)  // FEE_SETTER_ROLE
```

| Flow | `outboundToken` | `fee` unit |
|---|---|---|
| Deposit, shares out | `address(vault)` | Asset (USDT, USDC, …) |
| Redeem, asset out | `address(asset)` | Vault shares |

`destination` must match the route key users put in `VaultMessage` (CCIP selector or LZ EID), not necessarily the wire `dstId` inside the route struct.

The adapter reserve still pays the CCIP/LZ router native fee on the outbound send. Skimmed tokens accrue in `s_collectedFees`; withdraw with `withdrawCollectedFee`. Top up reserve when balance is low.

### LZ / Stargate spokes

Do not use `setInboundFee` on these paths. Require users to attach hub-native ETH on the compose send:

```solidity
setRequireLzReturnPrefunded(true)  // FEE_SETTER_ROLE
```

Surplus prefund refunds as native ETH to the `failedMessageHandler` when set (best-effort); otherwise it stays in the reserve.

### Reserve sizing

Prefund native on the adapter at deploy (`fundWei`). Size for peak concurrent CCIP returns times quoted native fee per route. Monitor `address(adapter).balance`. `recoverNative` withdraws native only (any amount, so take only the excess); it cannot move ERC-20 user or failed-message tokens.

---

## Daily monitoring

Check on each adapter clone:

| Signal | How |
|---|---|
| Native reserve | `cast balance $ADAPTER --rpc-url $HUB_RPC_URL` or the inspect script |
| Accrued skim fees | `s_collectedFees(token)` |
| Fee config | `s_inboundFees(outToken, destination)`, `s_requireLzReturnPrefunded()` |
| Paused? | `paused()` |
| Stuck messages | `MessageFailed` events on the adapter |

Inspect helper:

```bash
ADAPTER=0xYourClone pnpm e2e:multibridge inspect:adapter   # or: ADAPTER=0xYourClone bash script/multibridge/inspect-adapter.sh
```

AccessControl is not enumerable, so the inspect script checks a candidate list (config owners, fee collectors, the factory, `DEPLOYER`, and `ROLE_CANDIDATES`). Use `hasRole` directly for any other address.

---

## Emergency pause

`pause()` (admin only) halts:

- **Inbound processing** — new deliveries are captured as recoverable failed messages instead of executing (fail-safe), and `retryFailedMessage` is blocked.

Refund paths stay live while paused — by design, so captured funds always remain retrievable:

- `refundToSource(inbound)` (permissionless bounce-back) and `refundLocal(inbound, to)` (handler-only).

`unpause()` (admin only) resumes processing. Messages captured while paused stay captured; their handlers can `retryFailedMessage` after unpause, or anyone can bounce them with `refundToSource`.

These refund paths still move tokens (back to the source sender or a handler-chosen local address). To fully halt outbound flow over a compromised route or destination, remove its outbound allowlist entry (`setCcipDestination` / `setLzDestination` / `setStargateDestination` with `false`) and disable the route (`setRoute` with `enabled=false`). Disabling only the route is not enough: without an enabled route, `_routeOut` falls back to the legacy default for that `destination`.

---

## Failed messages

When `_handleReceive` reverts, inbound tokens stay on the adapter and `MessageFailed(guid, …)` fires.

### 1. Get `guid`

| Channel | Source |
|---|---|
| CCIP | `messageId` from [ccip.chain.link](https://ccip.chain.link) |
| LayerZero | `guid` from LayerZero Scan |

E2e prints `GUID=0x…` after each originate step.

### 2. Check state

```solidity
isFailed(guid)           // true = actionable
isRefunded(guid)         // true = already resolved
failedMessageHash(guid)  // the stored hash commitment over the captured delivery
```

The adapter stores only a fixed-size hash commitment per failure; reconstruct the full `Inbound` by
decoding the `message` field of the adapter's `MessageFailed(guid, …)` event.

### 3. Resolve

Pass the reconstructed `Inbound` (hash-verified on-chain):

```solidity
refundToSource{value: bridgeFee}(inbound);     // anyone (unless onlyLocalRefund + handler); bounce to spoke sender
retryFailedMessage{value: bridgeFee}(inbound); // failedMessageHandler only
refundLocal(inbound, to);                      // failedMessageHandler only; hub-local payout
```

Recovery callers pay outbound bridge fees via `msg.value`. The prefunded reserve is not spent on recovery.

E2e helpers:

```bash
GUID=0x… pnpm e2e:multibridge recover:status
GUID=0x… pnpm e2e:multibridge recover:refund
```

Common failure reasons: `MinAmountOutNotMet`, `ReturnNotPrefunded`, `ReturnFeeNotPrefunded`, `InboundFeeExceedsAmount`, `UnauthorizedCcipSource`, `EnforcedPause`. Decode `reason` from the `MessageFailed` event or the hub tx trace; the full list is in [`FAILED_MESSAGE_RESOLUTION.md`](../informational/FAILED_MESSAGE_RESOLUTION.md#decode-the-failure-reason).

---

## Sepolia e2e smoke tests

Requires `e2e/multibridge/.env` with `HUB_RPC_URL`, spoke RPCs, and `PRIVATE_KEY`.

```bash
bash script/multibridge/run-spoke-e2e.sh         # USDT: deposits in over Stargate, redeems in over CCIP
bash script/multibridge/run-fuji-usdc-e2e.sh     # USDC: Fuji CCIP deposit + redeem

# Subsets
bash script/multibridge/run-spoke-e2e.sh --only deposits
bash script/multibridge/run-spoke-e2e.sh --only fail --recover-fail
```

Logs land in `logs/spoke-e2e-*` and `logs/fuji-usdc-e2e-*` with per-step tx links.

Redeem scenarios need share-token balance on the spoke (`spokes.*.shareToken` in config). Run a successful deposit through the current adapter first if you redeployed clones.

---

## Config changes without redeploy

Safe to update on a live clone (admin or fee roles as noted):

| Change | Function / script |
|---|---|
| Allowlists | `setCcipSource`, `setLzOft`, `setCcipDestination`, `setStargateDestination`, … |
| Routes | `setRoute` |
| CCIP inbound fees | `setInboundFee` or `sync-hub-config-*.sh` |
| LZ prefund policy | `setRequireLzReturnPrefunded` or sync script |
| Withdraw skim | `withdrawCollectedFee` |
| Top up reserve | Send ETH to adapter |
| Reclaim excess reserve | `recoverNative` (admin) |
| Destination gas | `setDestinationGas` (admin) |
| Pause / resume inbound processing | `pause` / `unpause` (admin) |

Requires redeploy (immutable after `initialize`):

| Field | Why |
|---|---|
| `vault` | Bound at init |
| `ccipRouter` / `lzEndpoint` | Bound at init |

---

## Related docs

| Topic | Doc |
|---|---|
| User flows and rail matrix | [`FUNCTIONALITY.md`](../informational/FUNCTIONALITY.md) |
| Factory tuple field order | [`DEPLOYMENT.md`](./DEPLOYMENT.md) |
| Fee sizing and examples | [`RETURN_LEG_HANDLING.md`](../informational/RETURN_LEG_HANDLING.md) |
| Recovery paths in full | [`FAILED_MESSAGE_RESOLUTION.md`](../informational/FAILED_MESSAGE_RESOLUTION.md) |
| Stargate specifics | [`STARGATE.md`](../informational/STARGATE.md) |
| Tenderly fork testing | [`TENDERLY_E2E.md`](../development/TENDERLY_E2E.md) |
