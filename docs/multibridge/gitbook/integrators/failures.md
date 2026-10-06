# Tracking and failure handling

## Events to index

| Event | Meaning |
|---|---|
| `VaultDelivered` | Succeeded. Vault action done and output sent. |
| `MessageFailed(guid, ...)` | Handling reverted. Inbound tokens captured for recovery. |
| `DeliveredValueRefunded` | Surplus LayerZero-delivered native returned to the `failedMessageHandler`. |

Track a transfer end to end by its `guid`: the CCIP `messageId` from the [CCIP Explorer](https://ccip.chain.link), or the LayerZero `guid` from [LayerZero Scan](https://layerzeroscan.com).

## When a message fails

Any handling failure (`minAmountOut` breach, missing prefund, paused vault or adapter, malformed payload, missing route or allowlist entry) rolls back atomically. The inbound tokens are captured on the adapter. Nothing is lost and no admin is needed.

### Check state

```solidity
isFailed(guid)           // true = captured and actionable
isRefunded(guid)         // true = already resolved
failedMessageHash(guid)  // hash commitment over the captured delivery
```

The adapter stores only a hash commitment. Reconstruct the full `Inbound` struct by decoding the `message` field of the `MessageFailed` event. The recovery calls verify the reconstruction against the stored hash.

### Resolve

| Call | Who may call | Effect |
|---|---|---|
| `refundToSource{value: fee}(inbound)` | Anyone | Sends the held tokens back to the source sender over the inbound rail. Blocked when the message set `onlyLocalRefund = true` with a handler. |
| `retryFailedMessage{value: fee}(inbound)` | The `failedMessageHandler` | Re-executes the message after the cause clears, for example after the issuer fixes a route or funds arrive. |
| `refundLocal(inbound, to)` | The `failedMessageHandler` | Transfers the held tokens to a hub-local address. |

The caller pays the outbound bridge fee with `msg.value`. The issuer's reserve is never used for recovery.

### Common failure reasons

Decode `reason` from `MessageFailed` or the hub transaction trace: `MinAmountOutNotMet`, `ReturnNotPrefunded`, `ReturnFeeNotPrefunded`, `InboundFeeExceedsAmount`, `UnauthorizedCcipSource`, `EnforcedPause`.

## Front end recovery flow

1. On origination, store the `guid` with the user's transfer record.
2. Watch the adapter for `VaultDelivered` with that `guid`. If `MessageFailed` fires instead, surface the failure.
3. Offer the user a retry (if your handler address controls `retryFailedMessage` and the cause is transient) or a refund to source.
4. After resolution, confirm `isRefunded(guid)` is true, or that the retry emitted `MessageRecovered` and `VaultDelivered`.

Use your own contract or operational wallet as the `failedMessageHandler` so your front end can drive `retryFailedMessage` and `refundLocal` on behalf of users.
