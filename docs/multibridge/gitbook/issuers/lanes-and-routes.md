# Lanes and routes

You control which chains and rails your adapter serves. A delivery requires both an enabled route and the matching per-rail outbound allowlist entry. This is deliberate defense in depth.

## Per-spoke checklist

For each spoke chain you support:

```text
[ ] Inbound allowlist     setCcipSource(selector, true)  or  setLzOft(srcEid, oft, true)
[ ] Outbound allowlist    setCcipDestination / setLzDestination / setStargateDestination
[ ] Return route          setRoute(outToken, destination, Route{enabled, rail, endpoint, dstId})
[ ] Return-leg fee        see Fees and the native reserve
[ ] Optional gas          setDestinationGas(destination, gasLimit)
```

## Configuration surface

| Capability | Function | Role |
|---|---|---|
| Inbound CCIP sources | `setCcipSource(selector, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Inbound LayerZero and Stargate OFTs | `setLzOft(srcEid, oft, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound CCIP destinations | `setCcipDestination(selector, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound LayerZero destinations | `setLzDestination(eid, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Outbound Stargate destinations | `setStargateDestination(eid, allowed)` | `DEFAULT_ADMIN_ROLE` |
| Solana lanes | `setCcipSvmConfig(selector, enabled, computeUnits)` (`computeUnits` must be 0) | `DEFAULT_ADMIN_ROLE` |
| Route registry | `setRoute(token, destination, Route)` | `DEFAULT_ADMIN_ROLE` |
| Token to OFT mapping | `setOftForToken(token, oft)` | `DEFAULT_ADMIN_ROLE` |
| Destination gas | `setDestinationGas(destination, gas)` | `DEFAULT_ADMIN_ROLE` |

## Routes

```solidity
struct Route {
    bool enabled;
    Rail rail;        // LZ_OFT, CCIP, STARGATE, CCIP_SVM, LOCAL
    address endpoint; // OFT (LZ_OFT) or Stargate pool (STARGATE); address(0) for CCIP, CCIP_SVM, LOCAL
    uint64 dstId;     // wire identifier: LZ EID or CCIP selector; 0 for LOCAL
}
```

`setRoute(token, destination, route)` keys the route on the outbound token and the `destination` value users put in their `VaultMessage`. `setRoute` validates that the endpoint bridges the token (`IOFT(endpoint).token() == token`) and bounds `dstId` per rail. Stargate routes must use ERC-20 pools. Native-ETH pools are rejected.

The `destination` key is your registry key, often the destination EID or CCIP selector. `destination = 0` is reserved for `LOCAL` same-chain delivery and reverts unless a `LOCAL` route is set. If no route is set for any other key, a legacy default applies: values up to `uint32.max` are treated as LayerZero EIDs (sent through the `setOftForToken` mapping), larger values as CCIP selectors. A `CCIP_SVM` route requires the selector to be enabled with `setCcipSvmConfig` first.

Slippage is not a route field. Each user sets `minAmountOut` per transaction, and the adapter enforces it on the delivered amount.

## Inbound authentication

- CCIP deliveries are checked against the source chain selector allowlist (any sender on an allowlisted chain). A delivery from a non-allowlisted chain carries real tokens, so it is captured as a failed message that anyone can refund to its sender.
- LayerZero and Stargate deliveries must come from an allowlisted `(srcEid, oft)` pair. Stargate arrives as an OFT compose. A compose from a non-allowlisted pair reverts at the entrypoint and is not captured; it carries no tokens.

## Disabling a lane

To halt a route, remove the outbound allowlist entry for its `dstId` and call `setRoute` with `enabled = false`. Disabling only the route is not enough, because the legacy default then applies to that `destination`. To halt everything, see [Roles and emergency controls](roles-and-controls.md).
