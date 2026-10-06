# Failed message resolution

Operator guide for recovering inbound cross-chain messages that the hub vault adapter **captured** after
processing failed. Applies to all apps built on
[`MultiChannelBridgeAdapter`](../../../src/multibridge/MultiChannelBridgeAdapter.sol) (including
[`CrossChainVaultAdapter`](../../../src/multibridge/examples/CrossChainVaultAdapter.sol)).

**No owner/admin role is required.** Recovery is permissionless or delegated to the message's
`failedMessageHandler`. The operator's prefunded native reserve is **never** spent on recovery — callers
fund outbound bridge fees via `msg.value`.

See also: [`MULTI_CHANNEL_BRIDGE_ADAPTER.md`](../development/MULTI_CHANNEL_BRIDGE_ADAPTER.md) (design),
[`RETURN_LEG_HANDLING.md`](./RETURN_LEG_HANDLING.md) (return-leg fees), [`FUNCTIONALITY.md`](./FUNCTIONALITY.md)
(success/failure table).

---

## Lifecycle (what happened on the hub)

1. A spoke user bridged a token **in** over CCIP or LayerZero (an OFT, the LayerZero Omnichain Fungible
   Token standard, or a Stargate pool).
2. The channel credited the token to the hub adapter and called `ccipReceive` / `lzCompose`.
3. The adapter ran `_handleReceive` inside a `try/catch` self-call. The pause check and the CCIP source
   allowlist check run inside that call too, so a delivery while paused or from a non-allowlisted CCIP
   source is captured like any other failure. (A LayerZero compose from a non-allowlisted `(srcEid, oft)`
   reverts instead; it carries no tokens.)
4. **Success** → `MessageProcessed(guid)` and the vault action + outbound delivery complete.
5. **Revert** → the vault action rolls back atomically; the **inbound token stays in the adapter**; the
   full delivery is committed in one storage slot and `MessageFailed` is emitted.

```text
Spoke originate  →  CCIP/LZ relay  →  Hub adapter ccipReceive/lzCompose
                                              │
                                    try _handleReceive
                                              │
                         ┌────────────────────┴────────────────────┐
                         ▼                                         ▼
                 MessageProcessed                           MessageFailed
                 (done)                                     (captured — resolve below)
```

---

## Step 1 — Get the message id (`guid`)

The `guid` is the **hub-side** identifier for the delivery. Use it for all status checks and recovery
calls.

| Inbound channel | `guid` is | Where to find it |
|-----------------|-----------|------------------|
| **CCIP** | CCIP `messageId` | [CCIP Explorer](https://ccip.chain.link) after the spoke tx confirms; e2e prints `messageId:` |
| **LayerZero** | LZ `guid` | [LayerZero Scan](https://layerzeroscan.com) (testnets: [testnet.layerzeroscan.com](https://testnet.layerzeroscan.com)); e2e prints `guid:` |

### From e2e / test runs

After `pnpm e2e:multibridge initiate` (or a spoke e2e step), the CLI prints the `GUID` and the recovery
commands (it prints them in the `pnpm run` form used inside `e2e/multibridge`; from the repo root use):

```bash
GUID=0x… pnpm e2e:multibridge recover:status
GUID=0x… pnpm e2e:multibridge recover:refund
```

Spoke e2e summaries (`logs/spoke-e2e-*/summary.md`) also record **Message id / guid** per step.

### From Etherscan (hub adapter)

1. Open the hub adapter clone (e.g. `adapters.usdt.app` in `config/multibridge/sepolia.json`).
2. **Events** → filter `MessageFailed` (or `MessageProcessed` to confirm success).
3. The indexed `guid` topic is the id you need.

### From the hub delivery tx

Open the hub transaction that executed `ccipReceive` or `lzCompose` on the adapter. The `guid` appears in
`MessageFailed` / `MessageProcessed` / `TokensReceived` logs on that tx.

---

## Step 2 — Check whether the message failed (and is recoverable)

### View functions

Call on the **hub adapter** address:

| Function | Returns | Meaning |
|----------|---------|---------|
| `isFailed(guid)` | `bool` | `true` = captured, awaiting resolution (retry or refund) |
| `isRefunded(guid)` | `bool` | `true` = terminal; tokens already returned (bounce or local refund) |
| `failedMessageHash(guid)` | `bytes32` | The stored capture: `keccak256(abi.encode(inbound))`; non-zero = same as `isFailed` |

> The contract stores **only this fixed-size hash commitment** per failure (bounding capture cost
> regardless of payload size). The full `Inbound` is emitted in the `MessageFailed` event — decode its
> `message` field (`abi.decode(message, (Inbound))`) to reconstruct it for inspection and recovery.

**Typical states**

| `isFailed` | `isRefunded` | Meaning |
|------------|--------------|---------|
| `false` | `false` | Not captured — still in flight, already succeeded, or wrong `guid` |
| `true` | `false` | **Actionable** — tokens held on hub; pick a recovery path |
| `false` | `true` | Already resolved via `refundToSource` or `refundLocal` |
| `true` | `true` | Cannot occur (a refund clears the failure slot) |

A successful `retryFailedMessage` also clears `isFailed` but leaves `isRefunded` false; look for
`MessageRecovered`.

### Events (historical context)

| Event | When | Useful fields |
|-------|------|----------------|
| `TokensReceived(channel, srcId, sender, guid, tokenCount)` | Inbound credited, before app logic | Confirms delivery arrived |
| `MessageProcessed(guid)` | `_handleReceive` succeeded | Terminal success |
| `MessageFailed(guid, channel, message, reason)` | `_handleReceive` reverted | **`message`** = ABI-encoded `Inbound`; **`reason`** = revert data |
| `MessageRecovered(guid, caller)` | `retryFailedMessage` succeeded | Retry path worked |
| `MessageRefunded(guid, to, reason)` | `refundToSource` or `refundLocal` finished | Terminal refund |
| `DeliveredValueRefunded(guid, to, amount)` | Unused LZ compose `value` returned as native ETH to the handler (best-effort; else kept in reserve) | Separate from token capture |

### Decode the failure reason

The `reason` bytes on `MessageFailed` are the caught revert. Common errors:

| Error | Typical cause |
|-------|----------------|
| `MinAmountOutNotMet(amount, minAmountOut)` | Produced or delivered amount below the message's `minAmountOut` (`LOCAL`, `CCIP`, `CCIP_SVM`); on `LZ_OFT`/`STARGATE` the bridge enforces `minAmountLD` and reverts with its own error |
| `UnsupportedToken(token)` | Inbound token is neither vault asset nor vault share |
| `UnexpectedTokenCount(n)` | CCIP message carried ≠ 1 token |
| `ReturnNotPrefunded()` | LZ inbound, `requireLzReturnPrefunded == true`, no compose `value` |
| `ReturnFeeNotPrefunded(fee, delivered)` | LZ compose `value` < outbound bridge fee |
| `InboundFeeExceedsAmount(amount, fee)` | CCIP inbound amount ≤ configured inbound fee |
| `UnauthorizedCcipSource(selector)` | CCIP source chain not allowlisted (`setCcipSource`) |
| `EnforcedPause()` | Adapter was paused when the message arrived |
| `CcipDestNotAllowed` / `LzDestNotAllowed` / `StargateDestNotAllowed` | Route's `dstId` missing from the outbound allowlist |
| `LocalDestinationRequiresRoute()` / `OftNotConfigured(token)` | `destination = 0` without a `LOCAL` route, or no route and no OFT for the legacy LayerZero default |
| `NonEvmLocalRecipient` / `NonEvmCcipRecipient` / `ZeroRecipient` | `recipient` not usable on the route's rail |
| `InsufficientNativeFee(required, available)` | Adapter native balance below the outbound fee |

Decode with `cast decode-error <reason> --sig "<Error(types)>"`, or inspect the hub transaction trace.
An empty or non-ABI payload (for example a malformed `VaultMessage`) fails inside `abi.decode` with no
reason data.

### Read the application payload

For `CrossChainVaultAdapter`, `inbound.data` decodes as `VaultMessage`:

```solidity
struct VaultMessage {
    uint256 minAmountOut;
    uint64 destination;
    bytes32 recipient;
    address failedMessageHandler;
    bool onlyLocalRefund; // opt-in: block the permissionless refundToSource (requires a handler)
}
```

On the adapter (view):

```solidity
failedMessageHandler(bytes data) → address
```

Pass the `data` field from the reconstructed `Inbound`. `address(0)` means `retryFailedMessage` and
`refundLocal` are unavailable; only `refundToSource` remains. `onlyLocalRefund(bytes data) → bool` reads
the local-only flag the same way.

---

## Step 3 — Reconstruct the `Inbound` and resolve

The contract stores only the hash commitment, so recovery callers supply the full captured `Inbound`,
which is verified on-chain against the commitment (`InboundMismatch` on any deviation). Reconstruct it
from the `MessageFailed` event:

```solidity
// message = the `message` field of MessageFailed(guid, channel, message, reason)
Inbound memory inbound = abi.decode(message, (Inbound));

adapter.refundToSource{value: fee}(inbound);
adapter.retryFailedMessage{value: fee}(inbound);   // handler only
adapter.refundLocal(inbound, to);                  // handler only
```

**E2e** (reconstructs the `Inbound` from the event automatically):

```bash
GUID=0x… pnpm e2e:multibridge recover:status    # status only
GUID=0x… pnpm e2e:multibridge recover:refund    # calls refundToSource
```

Optional: `REFUND_VALUE_WEI` (default `50000000000000000`, 0.05 ETH) for the bounce bridge fee, and
`FROM_BLOCK=<n>` to bound the event scan on RPCs with a `getLogs` range limit.

### Inspect before recovering (optional)

Decode the same reconstructed `Inbound` to preview channel, tokens, and `inbound.data` (as
`VaultMessage`); check `keccak256(abi.encode(inbound)) == failedMessageHash(guid)` to confirm the
reconstruction is faithful before submitting.

---

## Step 4 — Choose a recovery path

```text
                    Message captured (isFailed == true)
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
           Transient fix?    Permanent bad route?   No handler /
           (slippage, gas,   (wrong destination,     malformed data?
            prefund, etc.)    unsupported rail)              │
                    │               │                      │
                    ▼               ▼                      ▼
         retryFailedMessage    refundLocal          refundToSource
         (handler only)        (handler only)       (anyone, unless
                    │               │                onlyLocalRefund)
                    │               │                      │
                    └───────────────┴──────────────────────┘
                     All clear isFailed (refunds also set isRefunded)
```

### Path A — `refundToSource(inbound)` (permissionless)

| | |
|---|---|
| **Who** | Anyone (keeper, user, operator), unless the message set `onlyLocalRefund` with a handler |
| **Effect** | Sends held token(s) back to **`inbound.sender`** on the **source chain**, over the **same channel** (CCIP or LZ; LZ bounces use `inbound.lzOft`) |
| **Native fee** | **Caller pays** via `msg.value`; surplus refunded; reserve never drawn |
| **Terminal** | Sets `isRefunded`; emits `MessageRefunded` |
| **When to use** | Malformed/dataless transfers; slippage you do not want to retry; no `failedMessageHandler`; safe default |

Etherscan: `refundToSource((uint8,uint64,bytes32,bytes32,(address,uint256)[],bytes,address))` → payable
→ paste the `Inbound` fields decoded from `MessageFailed.message` and attach enough ETH for the CCIP/LZ
bounce quote.

### Path B — `retryFailedMessage(inbound)` (handler only)

| | |
|---|---|
| **Who** | `failedMessageHandler` from `VaultMessage` (must be non-zero); blocked while the adapter is paused |
| **Effect** | Re-runs full `_handleReceive` (vault action + outbound delivery) |
| **Native fee** | **Handler pays** outbound via `msg.value` if needed |
| **On success** | `MessageRecovered`; failure slot cleared |
| **On revert** | Whole tx reverts; message **stays** `isFailed` — use `refundLocal` or `refundToSource` instead |
| **When to use** | Transient failure (for example temporary liquidity, a fixed route or allowlist, a refilled reserve, or the prefund now attached as `msg.value`). The message itself, including `minAmountOut`, cannot change |

### Path C — `refundLocal(inbound, to)` (handler only)

| | |
|---|---|
| **Who** | `failedMessageHandler` only |
| **Effect** | Transfers held inbound token(s) to local address `to` on the **hub** (no bridge) |
| **Native fee** | None |
| **Terminal** | Sets `isRefunded`; emits `MessageRefunded` |
| **When to use** | Route/destination permanently wrong; refund user on hub instead of bouncing |

### Handler vs no handler

| `failedMessageHandler` in message | `retryFailedMessage` | `refundLocal` | `refundToSource` |
|-----------------------------------|----------------------|---------------|------------------|
| `address(0)` | Reverts `NoHandler` | Reverts `NoHandler` | **Allowed** |
| Non-zero, `onlyLocalRefund=false` | Handler only | Handler only | **Allowed** (fallback) |
| Non-zero, `onlyLocalRefund=true` | Handler only | Handler only | **Blocked** (`LocalRefundOnly`) |

**Keeper vs handler race:** by default `refundToSource` is permissionless even when a
`failedMessageHandler` is set, so the first caller wins — a keeper may bounce to source before a handler
runs `retryFailedMessage`. A sender who wants to prevent that sets **`onlyLocalRefund = true`** in the
message: `refundToSource` is then blocked (`LocalRefundOnly`) and only the handler can resolve the
failure. NO-FREEZE: the flag is ignored when no handler is set, so a handler-less message can never be
frozen — it always stays permissionlessly refundable.

---

## Fees and reserve policy

| Action | Draws operator reserve? | Who pays bridge native |
|--------|-------------------------|-------------------------|
| Original happy-path delivery | Yes (CCIP return / default LZ policy) | Reserve or LZ compose `value` |
| `refundToSource` | **No** | Recovery caller (`msg.value`) |
| `retryFailedMessage` | **No** | Handler (`msg.value`) |
| `refundLocal` | **No** | N/A (local ERC-20 transfer) |

If recovery would reduce the contract balance below the pre-call reserve baseline, the tx reverts
`RetryReserveDrawn`.

**Quoting bounce fees:** simulate or quote the outbound CCIP/LZ send from the hub back to `inbound.srcId`
for `inbound.tokens[0]`; add headroom. E2e defaults to `0.05` ETH (`REFUND_VALUE_WEI`).

Return-leg **inbound skim** fees (`setInboundFee` / `withdrawCollectedFee`) are separate from recovery
fees and use `FEE_SETTER_ROLE` / `FEE_COLLECTOR_ROLE` — see [`RETURN_LEG_HANDLING.md`](./RETURN_LEG_HANDLING.md).
Recovery itself requires no admin or fee role.

---

## E2e test suites

### Spoke e2e (USDT — intentional fail scenarios)

Fail scenarios force `minAmountOut` to the maximum, so the hub reverts `MinAmountOutNotMet` and captures
the message. Run recovery automatically:

```bash
bash script/multibridge/run-spoke-e2e.sh --only fail --recover-fail
```

This polls `recover:status` until `isFailed`, then runs `recover:refund` (`refundToSource`).

Manual per-message:

```bash
GUID=0x… pnpm e2e:multibridge recover:status
GUID=0x… pnpm e2e:multibridge recover:refund
```

### Fuji USDC e2e

Same pattern for `fail-deposit-fuji-usdc` / `fail-redeem-fuji-usdc` (uses `adapters.usdc.app`):

```bash
bash script/multibridge/run-fuji-usdc-e2e.sh --only fail --recover-fail
```

---

## Manual resolution on Etherscan

1. Confirm `isFailed(guid) == true` on the hub adapter.
2. Reconstruct the `Inbound` from the `MessageFailed` event's `message` field (Events tab; decode as the
   `Inbound` tuple) — inspect tokens / decode `VaultMessage` from it.
3. Choose path A/B/C above.
4. Submit tx from the correct account (anyone for `refundToSource`; handler for B/C), passing the
   reconstructed `Inbound`.
5. Confirm `isRefunded(guid) == true` or `MessageRecovered` emitted.

**Hub adapter addresses** (Sepolia): the clones you deployed, recorded in `config/multibridge/sepolia.json` → `adapters.usdt.app` / `adapters.usdc.app`.

---

## Recovery errors (troubleshooting)

| Revert | Cause |
|--------|-------|
| `MessageNotFailed(guid)` | Not captured, already resolved, or wrong `guid` |
| `InboundMismatch(guid)` | Supplied `Inbound` does not hash to the stored commitment — re-decode it from `MessageFailed.message` verbatim |
| `NoHandler(guid)` | Handler-only path but `failedMessageHandler == 0` |
| `NotHandler(caller, handler)` | Wrong signer for `retryFailedMessage` / `refundLocal` |
| `RetryReserveDrawn(shortfall)` | `msg.value` too low or tx tried to spend reserve |
| `LocalRefundOnly(guid)` | `refundToSource` on a message that set `onlyLocalRefund` with a handler; the handler must recover it |
| `EnforcedPause()` | `retryFailedMessage` while the adapter is paused (refunds still work) |
| `RefundRouteNotConfigured(token)` | LZ bounce with no delivering OFT recorded and no `setOftForToken` mapping |

---

## Quick reference

| Goal | Call |
|------|------|
| Is it stuck? | `isFailed(guid)`, `isRefunded(guid)` |
| Inspect captured payload | decode `MessageFailed.message` as `Inbound` (verify vs `failedMessageHash(guid)`) |
| Bounce to spoke sender | `refundToSource{value: fee}(inbound)` |
| Retry happy path | `retryFailedMessage{value: fee}(inbound)` |
| Pay user on hub | `refundLocal(inbound, to)` |
| Automated bounce (e2e) | `GUID=0x… pnpm e2e:multibridge recover:refund` |
