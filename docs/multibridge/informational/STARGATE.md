# Stargate rail and outbound route registry

Stargate V2 is the third outbound transport, next to CCIP and LayerZero OFT (Omnichain Fungible
Token). It covers chains where USDT is not a USDT0 OFT, such as Avalanche and BNB Chain. A small route
registry selects the rail per destination. Validate each Stargate lane on a fork or testnet before
mainnet use (see [`KNOWN_LIMITATIONS.md`](./KNOWN_LIMITATIONS.md)).

---

## 1. Why

USDT0 (LayerZero OFT plus its Legacy Mesh) reaches many EVM and non-EVM chains, including Solana, over
`_sendViaOft`. Avalanche, BNB Chain, and Base carry native or third-party USDT that is not a USDT0 OFT.
Stargate V2 delivers canonical, native USDC and USDT to the chains it supports (not USDT on Base). See
[`NATIVE_USDT.md`](./NATIVE_USDT.md) for how this applies to USDT on Ethereum and BNB Chain.

The key implementation fact: `IStargate is IOFT`. A Stargate pool exposes the OFT surface (`token`,
`approvalRequired`, `quoteSend`, `send`) plus the Stargate-native `sendToken`, which also returns a "bus"
`Ticket`. The adapter sends in instant "taxi" mode (`SendParam.oftCmd == ""`), so the Stargate transport
mirrors the OFT one and the `Ticket` is ignored.

## 2. The two pieces

### a. Transport: `MultiChannelBridgeAdapter._sendViaStargate`

- `_sendViaStargate(dstEid, to, pool, amount, minAmountLD, extraOptions)` is gated by a dedicated
  `s_stargateDestAllowed[dstEid]` allowlist (`setStargateDestination`). It builds a taxi-mode
  `SendParam`, quotes with `IStargate.quoteSend`, and calls `IStargate.sendToken{value: fee}`.
- `quoteStargate(...)` is the matching view helper, mirroring `quoteOft`.
- The pool charges an LP (liquidity provider) fee, so the recipient receives less than `amount`;
  `minAmountLD` floors that. Only ERC-20 Stargate pools are supported (native-ETH pools take value, not
  an approval).

Inbound from Stargate needs only configuration. A Stargate delivery arrives as a LayerZero OFT compose,
so it uses the `lzCompose` path. Allowlist the hub-side pool: `setLzOft(srcEid, stargatePool, true)`.

### b. Routing: the `RouteRegistry` mixin

[`src/multibridge/routing/RouteRegistry.sol`](../../../src/multibridge/routing/RouteRegistry.sol) holds
`s_route[token][destination] => Route{ enabled, rail, endpoint, dstId }`, set with
`setRoute(token, destination, route)` (`DEFAULT_ADMIN_ROLE`). Each route records its rail, so the same
token can leave for different chains over different rails: for example USDT over USDT0 (`LZ_OFT`) to
Arbitrum but over `STARGATE` to BNB Chain.

```solidity
enum Rail { LZ_OFT, CCIP, STARGATE, CCIP_SVM, LOCAL }
struct Route { bool enabled; Rail rail; address endpoint; uint64 dstId; } // no slippage field
```

`_routeOut` precedence (called by the vault adapter):

1. Registry (authoritative): if `s_route[token][destination].enabled`, send over `route.rail` to
   `route.dstId` through `route.endpoint`. For Stargate, `minAmountLD` is the user's `minAmountOut`.
2. Legacy default (fallback): otherwise `destination ≤ uint32.max` means a LayerZero EID (endpoint ID)
   sent through `s_oftForToken[token]`, and a larger value means a CCIP chain selector.
   `destination = 0` without an enabled `LOCAL` route reverts (`LocalDestinationRequiresRoute`).

`s_oftForToken` / `setOftForToken` also serve the LayerZero refund bounce (`_oftFor`) when the
delivering OFT is not recorded.

### Defense in depth

A delivery needs both an enabled route and the base's per-rail outbound allowlist entry for the concrete
`dstId` (`setStargateDestination` / `setLzDestination` / `setCcipDestination`). `setRoute` also checks
`IOFT(endpoint).token() == token` and requires `dstId` to fit a LayerZero EID (`uint32`) for
`LZ_OFT`/`STARGATE`.

### Slippage

Slippage is not a route field. The user's per-transaction `minAmountOut` (in the `VaultMessage`) is the
single end-to-end floor. For a Stargate leg it is passed as the pool's `minAmountLD`, so the pool's
`sendToken` reverts on the hub if the post-fee amount would fall below it, and the base captures the
inbound for recovery. A front end sizes `minAmountOut` from a quote
(for example the pool's `quoteOFT`) minus the user's tolerance.

## 3. Operator setup (USDT to BNB Chain over Stargate)

```solidity
app.setStargateDestination(BNB_EID, true);                       // base allowlist
app.setRoute(USDT, BNB_EID, Route({                              // registry route
    enabled: true, rail: Rail.STARGATE,
    endpoint: STARGATE_USDT_POOL, dstId: BNB_EID                 // slippage = user's per-tx minAmountOut
}));
// inbound from BNB Chain (optional): app.setLzOft(BNB_EID, STARGATE_USDT_POOL, true);
```

`factory.deploy` does not set Stargate destinations or routes; the admin sets them after deploy.
`DeployProduction` installs them in the same broadcast as the deploy (see
[`DEPLOYMENT_CONFIG.md`](../operator/DEPLOYMENT_CONFIG.md)).

## 4. Failure handling

A Stargate-leg revert (`minAmountLD` breach, destination not allowlisted, insufficient native fee)
reverts `_handleReceive`, so the vault action rolls back and the base captures the inbound token as a
recoverable failed message: permissionless `refundToSource`, or the handler's `retryFailedMessage` /
`refundLocal`.

## 5. Tests

[`test/multibridge/stargate/StargateRoute.t.sol`](../../../test/multibridge/stargate/StargateRoute.t.sol)
covers redeem with USDT out over Stargate, registry precedence over the legacy default, LP-fee breach with
capture and permissionless bounce-back, destination-not-allowlisted capture, an inbound deposit from
Stargate, and `setRoute` validation (token mismatch, admin-only). `MockStargate` models the LP fee
(`amountReceived < amountSent`) and the `sendToken` / `Ticket` shape.

## 6. Scope and limits

- Native USDT is never a CCIP token. CCIP carries tokens with a CCIP pool, such as the vault share token.
- Stargate's token roster is small (USDC, USDT, ETH, and a few others). It widens chain reach, not the
  number of tokens per vault.
- Base USDT is not in Stargate's USDT pool set; Avalanche and BNB Chain are.
