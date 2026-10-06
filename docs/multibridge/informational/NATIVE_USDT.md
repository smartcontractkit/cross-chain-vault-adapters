# Native USDT on Ethereum and BNB Chain

Native USDT can be the vault asset on the two chains where USDT is not a plain standard token:
Ethereum (6 decimals, non-standard ERC-20) and BNB Chain (18 decimals). No contract changes are needed;
this page explains why and how to wire USDT to a rail.

## What "native USDT" means on each chain

| Chain | USDT contract | Decimals | Issuer | Quirks the adapter must tolerate |
|---|---|---|---|---|
| **Ethereum** | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | 6 | Tether | No-bool `transfer`/`approve`/`transferFrom`; approve race (allowance must be zeroed first); latent `basisPointsRate`/`maximumFee` (0 today); blocklist; pausable |
| **BNB Chain** | `0x55d398326f99059fF775485246999027B3197955` | **18** | Binance-bridged (BSC-USD) | 18 decimals; standard BEP-20 returns |

## How it is tested

- [`test/multibridge/mocks/MockUsdt.sol`](../../../test/multibridge/mocks/MockUsdt.sol) is a test double
  for native USDT: configurable decimals, no-bool `transfer`/`transferFrom`/`approve`, the approve-race
  revert, a latent fee (`basisPointsRate`/`maximumFee`), and a blocklist. It deliberately does not
  inherit `IERC20` (its functions return nothing, like the deployed Tether contract).
- [`test/multibridge/usdt/NativeUsdt.t.sol`](../../../test/multibridge/usdt/NativeUsdt.t.sol) drives
  native USDT through the vault adapter end to end:
  - 6-decimal Ethereum USDT: deposit to shares, redeem to USDT, two back-to-back deposits (`forceApprove`
    survives the approve race), and a check that the raw `transfer` returns no data (so `SafeERC20` is
    required and used).
  - 18-decimal BNB USDT: deposit to shares, redeem to USDT with the OFT (LayerZero Omnichain Fungible Token) shared-decimals (6) dust
    correctly floored (`amount % 1e12`).

The adapter's `SafeERC20.forceApprove` approvals and balance-delta accounting make native USDT work as
the vault asset on both chains. The adapter assumes no decimals and never reads `decimals()`.

## Wiring native USDT to a bridge rail

The vault's asset is the hub chain's USDT (6 decimals on Ethereum, 18 on BNB Chain). How USDT crosses
chains depends on the rail.

### Ethereum (USDT0 over LayerZero)

Native Ethereum USDT is the USDT0 lockbox underlying, so it moves over LayerZero through the USDT0 OFT
adapter (`0x6C96dE32CEa08842dcc4058c14d3aaAD7Fa41dee`):

```solidity
app.setOftForToken(USDT_ETH, USDT0_OFT_ADAPTER);   // legacy outbound default + LayerZero bounce
app.setLzOft(srcEid, USDT0_OFT_ADAPTER, true);     // inbound USDT over USDT0 (lzCompose)
app.setLzDestination(dstEid, true);                // outbound allowlist
app.setRoute(USDT_ETH, dstEid, Route({ enabled: true, rail: Rail.LZ_OFT,
    endpoint: USDT0_OFT_ADAPTER, dstId: dstEid })); // explicit route (recommended)
app.setDestinationGas(dstEid, gas);                // optional; default 200,000
```

Inbound (USDT0 unlock to native USDT plus compose) uses `lzCompose`; outbound (lock USDT, mint USDT0 on
the destination) uses `_sendViaOft`. `srcEid` and `dstEid` are LayerZero endpoint IDs.

### BNB Chain (Stargate)

BNB Chain USDT is not on USDT0. Its cross-chain rail is Stargate V2 (`Rail.STARGATE` in `RouteRegistry`,
backed by `_sendViaStargate`). See [`STARGATE.md`](./STARGATE.md).

- **Inbound from BNB Chain to the hub:** a Stargate V2 pool is an `IOFT`, so it delivers the token and
  calls `lzCompose` on the receiver. Allowlist the hub's Stargate USDT pool as the inbound OFT:
  `app.setLzOft(bscEid, HUB_STARGATE_USDT_POOL, true)`.
- **Outbound from the hub to BNB Chain:** register a Stargate route for the asset and allowlist the
  destination:

  ```solidity
  app.setStargateDestination(bscEid, true);
  app.setRoute(USDT_HUB, bscDestKey, Route({ enabled: true, rail: Rail.STARGATE,
      endpoint: HUB_STARGATE_USDT_POOL, dstId: bscEid }));
  ```

  The route registry lets the same adapter send USDT to USDT0 chains over the USDT0 OFT and to BNB Chain
  over Stargate.

## Decimals and amount math

- Ethereum USDT (6) over a 6-shared-decimal OFT: `decimalConversionRate = 1`, so there is no dust.
- BNB USDT (18) over a 6-shared-decimal OFT: rate `1e12`, so the outbound amount is floored to 6 shared
  decimals and the sub-unit dust stays in the adapter (unrecoverable by design; see
  [`KNOWN_LIMITATIONS.md`](./KNOWN_LIMITATIONS.md)). The adapter measures balance deltas instead of
  assuming decimals.

## Summary

All of the following is configuration only:

- Native USDT as the vault asset (6-decimal non-standard Ethereum USDT and 18-decimal BNB USDT), covered
  by the mock and tests above.
- USDT in and out over USDT0 / LayerZero (Ethereum and the other USDT0 chains).
- USDT in and out over Stargate to chains without USDT0 (BNB Chain, Avalanche), through `Rail.STARGATE`
  and the route registry.
