# Fees and the native reserve

The return leg is the outbound send that delivers the produced token after the vault action. Two funding mechanisms exist. Pick per spoke, based on how that spoke sends inbound traffic.

| Spoke sends via | You set | Who pays the native outbound fee |
|---|---|---|
| CCIP | `setInboundFee(outboundToken, destination, fee)` | Your reserve, always |
| LayerZero or Stargate | `setRequireLzReturnPrefunded(true)` | The user, via attached native value |
| Either, to `LOCAL` | Nothing | Nobody. Local delivery has no fee. |

## CCIP spokes: token skim

CCIP cannot deliver native gas, so your reserve pays the router's native fee on every outbound send. To recoup this, skim a flat fee in the inbound token before the vault action:

```solidity
setInboundFee(outboundToken, destination, fee)  // FEE_SETTER_ROLE
```

| Flow | `outboundToken` | `fee` denominated in |
|---|---|---|
| Deposit, shares out | `address(vault)` | Asset (USDT, USDC) |
| Redeem, asset out | `address(asset)` | Vault shares |

- `destination` must equal the route key users put in `VaultMessage`. It is not necessarily the wire `dstId` inside the route struct.
- `fee = 0` disables the skim for that pair.
- Size the fee at or above the expected native return cost for that route, expressed in inbound-token units, plus a buffer. Quote with `IRouterClient.getFee` or the LayerZero quote functions on a fork. Revisit when gas prices move.
- A message whose amount is at or below the fee fails with `InboundFeeExceedsAmount` and is captured for recovery.

Skimmed tokens accrue in `s_collectedFees`. Withdraw with `withdrawCollectedFee(token, recipient, amount)`, which requires `FEE_COLLECTOR_ROLE`.

## LayerZero and Stargate spokes: user prefund

Do not use `setInboundFee` on these paths. Require users to attach hub-native value on the compose send:

```solidity
setRequireLzReturnPrefunded(true)  // FEE_SETTER_ROLE
```

With this flag on, an inbound LayerZero or Stargate message with no attached value fails with `ReturnNotPrefunded` and is captured for recovery. Whether or not the flag is on, a message that attaches less than the outbound fee fails with `ReturnFeeNotPrefunded`. Surplus prefund refunds as native to the message's `failedMessageHandler`, best-effort. With no handler, or if the handler rejects native, the surplus stays in your reserve.

With the flag off, your reserve pays for LayerZero-origin return legs. Avoid this in production.

## The reserve

The reserve is the adapter's native balance. Fund it with `fundWei` at deploy or send native to the adapter at any time.

- Size it for peak concurrent CCIP-origin returns times the quoted native fee per route.
- Monitor `address(adapter).balance` and top up before it runs out. An outbound send that cannot be funded fails the message, and the tokens are captured for recovery.
- `recoverNative(to, amount)` (`DEFAULT_ADMIN_ROLE`) withdraws native only. It can withdraw any amount of the native balance, so take only the excess; it cannot move user tokens or captured failed-message tokens.
- The reserve is never drawn for recovery sends. Callers fund those with `msg.value`.
