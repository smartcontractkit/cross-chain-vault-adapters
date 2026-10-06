# Monitoring and recovery

## Daily signals

| Signal | How to read it |
|---|---|
| Native reserve | `address(adapter).balance` |
| Accrued skim fees | `s_collectedFees(token)` |
| Fee configuration | `s_inboundFees(outboundToken, destination)`, `s_requireLzReturnPrefunded()` |
| Paused state | `paused()` |
| Failed messages | `MessageFailed` events on the adapter |

## Failed messages

When message handling reverts, the inbound tokens stay on the adapter and `MessageFailed(guid, ...)` fires. The adapter stores a fixed-size hash commitment per failure, not the full message.

### 1. Get the guid

| Channel | Source |
|---|---|
| CCIP | `messageId` on [ccip.chain.link](https://ccip.chain.link) |
| LayerZero and Stargate | `guid` on [LayerZero Scan](https://layerzeroscan.com) |

### 2. Check state

```solidity
isFailed(guid)           // true = actionable
isRefunded(guid)         // true = already resolved
failedMessageHash(guid)  // hash commitment over the captured delivery
```

Reconstruct the full `Inbound` struct by decoding the `message` field of the adapter's `MessageFailed` event. The contract verifies the reconstruction against the stored hash.

### 3. Resolve

```solidity
refundToSource{value: bridgeFee}(inbound);     // anyone (unless onlyLocalRefund + handler): bounce to the source sender
retryFailedMessage{value: bridgeFee}(inbound); // failedMessageHandler only
refundLocal(inbound, to);                      // failedMessageHandler only: hub-local payout
```

The caller pays the outbound bridge fee with `msg.value`. The reserve is not spent on recovery.

You can run these calls as a service for your users, but nothing requires you to. Any party can execute `refundToSource`.

### Common failure reasons

Decode `reason` from the `MessageFailed` event or the transaction trace:

| Reason | Cause |
|---|---|
| `MinAmountOutNotMet` | Produced amount below the user's `minAmountOut` on a `LOCAL`, `CCIP`, or `CCIP_SVM` route. On `LZ_OFT` and `STARGATE` routes the bridge's own slippage error appears instead. |
| `ReturnNotPrefunded` | LayerZero or Stargate origin attached no native value while prefunding is required. |
| `ReturnFeeNotPrefunded` | Attached value below the quoted outbound fee. |
| `InboundFeeExceedsAmount` | Inbound amount at or below the configured skim fee. |

Other causes include a paused adapter (`EnforcedPause`), a CCIP source that is not allowlisted (`UnauthorizedCcipSource`), a paused or reverting vault, an unsupported inbound token, a malformed payload, a missing outbound allowlist entry, an empty native reserve, and a non-EVM recipient on a `LOCAL` or `CCIP` route.
