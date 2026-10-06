# Fees and prefunding

A cross-chain transfer has two fee components:

1. The source bridge fee, paid by the user on the origin chain in the origin transaction. Quote it from the origin rail (`IRouterClient.getFee` for CCIP, `quoteSend` for an OFT (LayerZero Omnichain Fungible Token), `quoteOFT`/`quoteSend` for Stargate).
2. The return leg, the hub's outbound send of the produced token. Who pays depends on the origin rail.

## Return leg by origin rail

| Origin rail | Return leg funding | Integrator action |
|---|---|---|
| CCIP | The issuer's reserve pays the native fee. The issuer may skim a flat fee in the inbound token. | Read `s_inboundFees(outboundToken, destination)` and show the skim to the user. Reject amounts at or below the skim. |
| LayerZero or Stargate | The user prefunds by attaching hub-native value to the compose send. | Read `s_requireLzReturnPrefunded()`. When `true`, quote the hub outbound fee and attach at least that value. |
| Any, with `destination = 0` (LOCAL) | No return leg fee. | Attach nothing. Any attached value is returned to the `failedMessageHandler` (or kept in the reserve without one). |

## Reading the skim fee

`setInboundFee` keys are `(outboundToken, destination)`:

| Flow | `outboundToken` | Fee denominated in |
|---|---|---|
| Deposit, shares out | `address(vault)` | Asset |
| Redeem, asset out | `address(asset)` | Vault shares |

The skim comes off the inbound amount before the vault action. Display the net amount to the user. A message whose amount is at or below the fee fails with `InboundFeeExceedsAmount`.

## Prefunding on LayerZero and Stargate origins

Attach the prefund as the compose `value` on the origin send. The bridge delivers it to the hub as native.

- If prefunding is required and missing, the message fails with `ReturnNotPrefunded` and is captured for recovery. If the value is below the quoted fee, it fails with `ReturnFeeNotPrefunded`.
- Surplus refunds as native to the message's `failedMessageHandler`, best-effort. With no handler, or if the handler rejects native, the surplus stays in the issuer's reserve. Always set a handler that can receive native, or the user's overpayment is lost to the issuer's float.
- Quote the hub-side outbound fee before origination and add a buffer for gas movement between quote and delivery.
