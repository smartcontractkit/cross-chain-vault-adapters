# Originating a transfer

The hub adapter has no public deposit or redeem function. OFT is LayerZero's Omnichain Fungible Token standard; EID is a LayerZero endpoint ID. It is driven only by an inbound bridge delivery. To originate, send the token to the hub adapter over a rail, with the ABI-encoded `VaultMessage` as the payload.

The inbound token selects the action. The vault's asset triggers a deposit. The vault's share token triggers a redemption.

## Origination calls per rail

| Origin rail | Call on the source chain | Payload placement |
|---|---|---|
| CCIP | `IRouterClient.ccipSend(hubSelector, message)` with `tokenAmounts = [{token, amount}]` and `receiver = hubAdapter` | `message.data = abi.encode(vaultMessage)` |
| LayerZero OFT | `IOFT.send(SendParam{dstEid: hubEid, to: hubAdapter, composeMsg, ...})` | `composeMsg = abi.encode(vaultMessage)` |
| Stargate | `IStargate.sendToken(SendParam{dstEid: hubEid, to: hubAdapter, composeMsg, ...})` | `composeMsg = abi.encode(vaultMessage)` |

## What happens on the hub

1. The source chain locks or burns the token and emits the cross-chain message.
2. On the hub, the CCIP router calls `ccipReceive`, or the LayerZero endpoint calls `lzCompose`. Stargate inbound arrives as an OFT compose. The adapter checks the delivery: CCIP against the source chain selector allowlist (a miss is captured for refund), LayerZero and Stargate against the `(srcEid, oft)` allowlist (a miss reverts).
3. The adapter performs the deposit or redeem and delivers the produced token to `recipient` over the route registered for `(producedToken, destination)`. `destination = 0` delivers on the hub with a direct transfer.

On success the adapter emits `VaultDelivered`.

## Integration checklist

Before showing a lane to users, confirm with the issuer or read from the adapter:

- The source chain is on the inbound allowlist.
- A route exists for the produced token to each destination you offer.
- The fee mode for the origin rail. See [Fees and prefunding](fees-and-prefunding.md).
- The origin's compose gas settings match what the issuer expects. Outbound hub gas is issuer-set (`setDestinationGas`); it is not in the message.

## Same-chain users

Users already on the hub chain interact with the vault directly. It is a standard ERC-4626 vault. The adapter exists for cross-chain origination. `destination = 0` covers the reverse case: a spoke-originated action whose output should land on the hub.

## Solana origins

Solana origination works over CCIP (allowlist the Solana selector with `setCcipSource`), LayerZero OFT, and Stargate. The `VaultMessage` is deliberately small for size-constrained origins. The adapter normalizes the 32-byte Solana sender like any other source, and a refund to source returns tokens to that 32-byte sender.
