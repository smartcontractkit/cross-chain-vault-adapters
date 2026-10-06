# Functionality summary

What the system does, from the operator's and the user's perspective, plus a supported-token matrix and
how transactions are originated. For contract-level detail see
[`MULTI_CHANNEL_BRIDGE_ADAPTER.md`](../development/MULTI_CHANNEL_BRIDGE_ADAPTER.md); for rails and config see
[`STARGATE.md`](./STARGATE.md), [`SOLANA.md`](./SOLANA.md), [`DEPLOYMENT_CONFIG.md`](../operator/DEPLOYMENT_CONFIG.md).

## What it is

A cross-chain vault adapter that delivers over several rails, built in three layers:

- **Transport**: `MultiChannelBridgeAdapter` receives and sends tokens over Chainlink CCIP (Cross-Chain
  Interoperability Protocol), LayerZero V2 OFT (Omnichain Fungible Token), and Stargate V2, normalizing
  each inbound delivery into one `Inbound{channel, srcId, sender, guid, tokens[], data, lzOft}` and handing
  it to a `_handleReceive` hook. It also owns the failed-message capture and recovery state machine.
- **Routing**: `RouteRegistry` (a mixin on the transport) picks one of five rails per
  `(token, destination)` to deliver a produced token onward.
- **Vault adapter**: a **synchronous ERC-4626** adapter on top of those shared layers, **one vault per
  deployment**: deposit asset → get shares, or redeem shares → get the asset, with the vault action +
  delivery in **one transaction**: **`CrossChainVaultAdapter`** (`"CrossChainVaultAdapter 1.0.0"`), using
  CCIP v1 extra args (`GenericExtraArgsV2`).

`CrossChainVaultAdapterFactory` (on the shared `VaultAdapterFactoryBase`) clones + configures the
implementation (EIP-1167, non-upgradeable).

**The vault lives on one "home" (hub) chain.** Users originate from any allowlisted "spoke" chain; the
hub does the deposit/redeem and sends the result onward (or hands it over locally).

Two core principles:
- **No operator custody of user funds.** The operator configures lanes; it cannot move user or failed
  tokens. Recovery is permissionless or handler-driven.
- **The user picks the path; the operator picks the universe.** The operator allowlists which source and
  destination chains/rails are permitted; the user chooses, per transfer, which allowed destination to use.

### The five delivery rails

The produced token leaves the hub over one rail, chosen per `(token, destination)` by the operator's
**route registry** (`s_route[token][destination] → Route{enabled, rail, endpoint, dstId}`):

| Rail | Transport | Typical use |
|---|---|---|
| `LZ_OFT` | LayerZero V2 OFT | USDT via **USDT0**, or any OFT token; reaches **Solana** |
| `STARGATE` | Stargate V2 pooled liquidity | canonical USDT/USDC to chains without USDT0 (BNB, Avalanche) |
| `CCIP` | Chainlink CCIP (EVM) | **USDC** (Chainlink-supported USDC pools) or a **share token** (deployer-provisioned CCT pool) |
| `CCIP_SVM` | Chainlink CCIP to **Solana** (SVM, the Solana Virtual Machine) | same as CCIP, 32-byte recipient + SVM encoding |
| `LOCAL` | direct `transfer` (no bridge) | **same-chain** delivery on the hub; fee 0 |

---

## Operator's perspective

### One-time setup

1. Publish the implementation + a factory (`DeployImplementationAndFactory`), or use the production
   `DeployProduction` script, which also publishes them when no existing factory is configured.
2. Ensure token-level prerequisites exist (not part of this app): a **CCT pool for the vault share token**
   (CCT, the CCIP Cross-Chain Token standard; you deploy it); **USDC** already has Chainlink-supported
   pools on CCIP lanes that list it in the CCIP directory; **OFT peers/DVNs** (LayerZero decentralized
   verifier networks) for any LayerZero-routed token; and **Stargate pools** for the asset on every lane used.

### Deploy + activate (one transaction)

`factory.deploy(DeployConfig)` clones the implementation, initializes it (router, endpoint, vault),
installs allowlists, the OFT map and return-leg fees, optionally funds the native fee float, and grants
**`DEFAULT_ADMIN_ROLE`**, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` to `config.owner` (immediate, no
accept step; a non-zero `config.feeCollector` receives `FEE_COLLECTOR_ROLE` instead). Stargate
destinations, Solana lanes, and routes are set afterwards by the admin. For a full multi-network
production deploy, [`DeployProduction.s.sol`](../../../script/multibridge/DeployProduction.s.sol)
resolves a high-level config (home + vault + `routes[]`) against the [`Networks`](../../../script/multibridge/config/Networks.sol)
address book and installs the whole route registry. See [`DEPLOYMENT_CONFIG.md`](../operator/DEPLOYMENT_CONFIG.md).

### What the operator configures (by role)

| Capability | Function | Role |
|---|---|---|
| Inbound CCIP sources | `setCcipSource(selector, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Inbound LZ / Stargate OFTs | `setLzOft(srcEid, oft, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound CCIP dests | `setCcipDestination(selector, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound LZ dests | `setLzDestination(eid, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound Stargate dests | `setStargateDestination(eid, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Solana (SVM) lanes | `setCcipSvmConfig(selector, enabled, computeUnits)` (`computeUnits` must be 0) | `DEFAULT_ADMIN_ROLE` |
| **Route registry** | `setRoute(token, destination, Route)` | `DEFAULT_ADMIN_ROLE` |
| Token → OFT | `setOftForToken(token, oft)` | `DEFAULT_ADMIN_ROLE` |
| Destination gas | `setDestinationGas(destination, gas)` | `DEFAULT_ADMIN_ROLE` |
| LZ return prefund policy | `setRequireLzReturnPrefunded(bool)` | `FEE_SETTER_ROLE` |
| Inbound CCIP return-leg fees | `setInboundFee(outboundToken, destination, fee)` | `FEE_SETTER_ROLE` |
| Withdraw accrued inbound fees | `withdrawCollectedFee(token, recipient, amount)` | `FEE_COLLECTOR_ROLE` |
| Fee float | send native / `recoverNative(to, amount)` | `DEFAULT_ADMIN_ROLE` |
| Emergency pause | `pause()` / `unpause()` | `DEFAULT_ADMIN_ROLE` |
| Admin handoff | `transferAdmin(newAdmin, feeSetter, feeCollector)` (reverts on self; `address(0)` fee arg = leave unchanged — the **outgoing caller keeps** that fee role; pass non-zero addresses for a complete handoff) | `DEFAULT_ADMIN_ROLE` |
| Grant fee roles to bots | `grantRole(FEE_SETTER_ROLE, …)` | `DEFAULT_ADMIN_ROLE` |

> **`FEE_SETTER_ROLE`** and **`FEE_COLLECTOR_ROLE`** are granted to `config.owner` at deploy
> (`feeCollector` overrides the collector when non-zero). Revoke and re-grant to dedicated bots later
> via `grantRole` / `revokeRole` if needed.

> **Defense in depth:** a delivery needs **both** an enabled `Route` **and** the matching per-rail
> outbound allowlist for the concrete `dstId`. `setRoute` validates the endpoint actually bridges that
> token (`IOFT(endpoint).token() == token`) and bounds `dstId` per rail. Slippage is not a route field —
> it is the user's per-transaction `minAmountOut`, enforced on the delivered amount.

### Responsible for / NOT responsible for

- **Responsible:** which chains/rails are allowed; per-token bridging prerequisites (share-token CCT pool,
  OFT peers, Stargate pools; USDC pools on CCIP lanes are Chainlink-provided); keeping the native gas float funded;
  return-fee policy.
- **NOT (and cannot):** recover failed/stuck user tokens (no admin token-recovery path; recovery is
  permissionless `refundToSource` or the message's `failedMessageHandler`), or touch user funds in flight
  (the admin can only move its own native fee float).

---

## User's perspective

### What a user does

Originate a transfer **from a source chain** carrying the token + a small `VaultMessage`. The hub performs
the vault action and delivers the produced token to the destination the user chose.

- **Deposit:** send the **asset** in → receive **shares** at `recipient` on the chosen destination.
- **Redeem:** send the **share token** in → receive the **asset** at `recipient`.

### The message the user supplies (`VaultMessage`, ABI-encoded)

| Field | Meaning |
|---|---|
| `minAmountOut` | the user's per-tx **end-to-end** slippage floor on the DELIVERED amount (output-token units: shares on deposit, assets on redeem); measured for LOCAL/CCIP, the bridge's `minAmountLD` for OFT/Stargate |
| `destination` | the outbound **route key**: an operator-registered key (often the dest EID/selector); **`0` = LOCAL** (deliver on the hub). With no route set, the legacy default applies (`≤ uint32.max` ⇒ LZ EID, else CCIP selector) |
| `recipient` | beneficiary as `bytes32` (EVM address in low 20 bytes; full 32 bytes for Solana) |
| `failedMessageHandler` | optional: who may retry / refund-local on a failure, and who receives unused LayerZero prepay (`0` ⇒ only the permissionless `refundToSource`) |
| `onlyLocalRefund` | opt-in: when `true` **and** a handler is set, blocks the permissionless `refundToSource` so only the handler recovers (ignored when no handler — no-freeze) |

Outbound gas is **not** in the message (operator config). The message is intentionally small for
size-constrained origins (e.g. Solana).

### Paying for the return leg

See [`RETURN_LEG_HANDLING.md`](./RETURN_LEG_HANDLING.md) for the full inbound/outbound token matrix.

- **LayerZero/Stargate origin:** attach native (the compose `value`) to **pre-pay** the return-leg fee;
  the surplus is returned to the message's `failedMessageHandler` (best-effort; with no handler it stays
  in the adapter's reserve). If the operator requires prefunding, this is mandatory. (LOCAL costs nothing;
  any attached value is returned the same way.)
- **CCIP origin:** the outbound native bridge fee is paid from the operator's reserve (CCIP can't deliver
  native). The operator may instead charge a flat **inbound-token** fee via `setInboundFee` (skimmed
  before the vault action) to fund return-leg economics.

### Success / failure

On success the vault action runs and the produced token is delivered to `recipient` in one hub
transaction (`VaultDelivered`). On **any** failure (malformed payload, unsupported token, CCIP source not
allowlisted, adapter paused, `minAmountOut` breach, an outbound-leg shortfall, or a non-EVM recipient on
a LOCAL route) it rolls back atomically and the inbound token is captured for recovery (no operator
needed). Each call takes the captured `Inbound`, decoded from the `MessageFailed` event:

| Path | Who | Effect |
|---|---|---|
| `refundToSource(inbound)` | **anyone** (blocked if the message set `onlyLocalRefund` with a handler) | bounce the held token back to the origin sender over the inbound rail |
| `retryFailedMessage(inbound)` | the message's **handler** | re-run once the cause clears (caller funds the outbound) |
| `refundLocal(inbound, to)` | the message's **handler** | send the held token to a local address |

---

## Supported tokens: network × token × bridge

"Supported token" means the vault's asset (USDT or USDC) and its share token. The matrix shows how each
moves to and from a network and over which rail. Every entry assumes the token-level prerequisite
exists: a USDC pool on the CCIP lane, a CCT pool you deploy for the share token, USDT0 OFT peers for USDT
over LayerZero, and Stargate pools on the lane. "N/A" means not available.

| Network | EID / CCIP selector | USDT | USDC | Share token | Same-chain |
|---|---|---|---|---|---|
| Ethereum | 30101 / 5009297550715157269 | USDT0 (`LZ_OFT`), Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Arbitrum | 30110 / 4949039107694359620 | USDT0, Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Optimism | 30111 / 3734403246176062136 | USDT0, Stargate | CCIP, Stargate (pool address unverified) | CCIP | `LOCAL` |
| Polygon | 30109 / 4051577828743386545 | USDT0, Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Base | 30184 / 15971525489660198786 | N/A (no supported USDT rail) | Stargate, CCIP | CCIP | `LOCAL` |
| Avalanche | 30106 / 6433500567565415381 | Stargate (no USDT0) | Stargate, CCIP | CCIP | `LOCAL` |
| BNB | 30102 / 11344663589394136015 | Stargate (no USDT0; 18 decimals) | Stargate, CCIP | CCIP | `LOCAL` |
| Solana | 30168 / 124615329519749607 | USDT0 (`LZ_OFT`), Stargate | Stargate, `CCIP_SVM` | `CCIP_SVM` | N/A (non-EVM) |

EID is the LayerZero endpoint ID.

Notes:
- **Native USDT is never a CCIP token.** It moves over USDT0 (`LZ_OFT`) or Stargate.
- **USDT0** covers Ethereum (lock/mint adapter), Arbitrum, Optimism, Polygon, Solana, and other USDT0
  chains. Avalanche, BNB, and Base have no USDT0, so USDT there goes over Stargate (none on Base).
- **Base has no supported USDT rail.** Bridged "USDT" tokens on Base are not Tether-issued, have no USDT0
  OFT and no Stargate USDT pool, and USDT is never CCIP, so none of the five rails move them. Treat Base
  USDT as unsupported unless you provision your own rail (for example a CCT pool) for that specific token.
- **USDC over CCIP/`CCIP_SVM`** uses the USDC pools Chainlink supports on each lane, so you deploy no CCT
  for it. Confirm that each lane you use lists USDC in the
  [CCIP directory](https://docs.chain.link/ccip/directory/mainnet). USDC may also move over Stargate.
- **The share token** moves over CCIP/`CCIP_SVM` through a CCT pool you deploy on each lane as part of
  vault setup. Until a lane's pool exists, that lane does not carry shares.
- **`LOCAL`** works for any token on the home chain (the produced token is transferred directly).
- Selectors and EIDs are in [`Networks.sol`](../../../script/multibridge/config/Networks.sol). Reconfirm
  pool and router addresses against official directories before mainnet (some are flagged `VERIFY`).

---

## How transactions are originated

The hub adapter has no public "deposit" function; it is driven **only** by an inbound bridge delivery
(both entrypoints are `nonReentrant` and callable only by the configured router or endpoint). A user
(or a thin spoke "originator" contract / front-end) originates by **sending the token to the hub adapter
over a rail with the `VaultMessage` as the payload**:

| Originate over | Call on the source chain | Carries the message as |
|---|---|---|
| **CCIP** | `IRouterClient.ccipSend(hubSelector, msg)` with `tokenAmounts=[{token, amount}]`, `receiver = hub adapter` | `msg.data = abi.encode(VaultMessage)` |
| **LayerZero OFT** | `IOFT.send(SendParam{dstEid: hubEid, to: hubAdapter, composeMsg, …})` | `composeMsg = abi.encode(VaultMessage)` |
| **Stargate** | `IStargate.sendToken(SendParam{dstEid: hubEid, to: hubAdapter, composeMsg, …})` | `composeMsg = abi.encode(VaultMessage)` |

1. The source chain locks/burns the token and emits the cross-chain message.
2. On the hub, the CCIP router calls `ccipReceive`, or the LayerZero endpoint calls `lzCompose`
   (Stargate inbound arrives as an OFT compose). LayerZero/Stargate deliveries must come from an
   allowlisted `(srcEid, oft)` or they revert. CCIP deliveries are checked against the source chain
   selector allowlist inside the isolated call, so a non-allowlisted source is captured for recovery.
   The adapter then normalizes to `Inbound` and runs `_handleReceive`.
3. `_handleReceive` decodes the `VaultMessage`, does the deposit/redeem, and delivers the produced token
   to `recipient` over the registry-selected rail for `(producedToken, destination)`, or `transfer`s it
   locally when `destination = 0`.

**Same-chain users** can interact with the vault directly (it's a normal ERC-4626 vault); they don't
need the adapter. The adapter is for **cross-chain** origination; `LOCAL` delivery covers the case where a
cross-chain message wants its result handed over **on the hub** (e.g. a spoke deposit whose shares should
land on the hub itself).

Worked end-to-end origination + settlement examples (Tenderly multi-fork) are in
[`TENDERLY_E2E.md`](../development/TENDERLY_E2E.md).

---

## Failure and recovery model (at a glance)

```text
inbound (CCIP ccipReceive | LZ/Stargate lzCompose, both nonReentrant)
  -> caller must be the router / endpoint; LZ/Stargate (srcEid, oft) must be allowlisted (else revert)
  -> normalize -> isolated self-call: [paused? CCIP source allowlisted?] -> _handleReceive

  success -> produced token delivered to recipient@destination   (VaultDelivered, MessageProcessed)
  revert  -> inbound token captured (one-slot hash commitment)   (MessageFailed)

  either way, unused LZ-delivered native -> failedMessageHandler (DeliveredValueRefunded), else reserve
  recover: refundToSource (anyone, unless onlyLocalRefund) | handler retryFailedMessage / refundLocal
```

No admin role appears anywhere in the recovery path; recovery is permissionless or handler-driven.
