# How it works

## Hub and spoke

The vault lives on one hub chain. The adapter is a contract on the hub, bound to that vault at initialization. Users originate transfers from spoke chains. The adapter has no public deposit function. Only an inbound bridge delivery drives it.

## Lifecycle of a deposit

1. The user sends the vault's asset from a spoke chain to the adapter over CCIP, LayerZero OFT (Omnichain Fungible Token), or Stargate. The bridge message carries a small ABI-encoded `VaultMessage` payload.
2. The bridge delivers the tokens and the payload on the hub. The adapter checks the delivery against the issuer's allowlists: the source chain for CCIP, the `(source EID, OFT)` pair for LayerZero and Stargate. EID is the LayerZero endpoint ID.
3. The adapter deposits the asset into the vault and receives shares.
4. The adapter sends the shares to the `recipient` on the `destination` the user chose. The route registry selects the rail. `destination = 0` delivers on the hub with a direct transfer.

A redemption is the same flow with the tokens reversed. The user sends the share token in. The adapter redeems and delivers the asset.

## The five delivery rails

The issuer registers one route per `(token, destination)` pair. Each route names a rail:

| Rail | Transport | Typical use |
|---|---|---|
| `LZ_OFT` | LayerZero V2 OFT | USDT via USDT0, any OFT token. Reaches Solana. |
| `STARGATE` | Stargate V2 pooled liquidity | Canonical USDT and USDC to chains without OFT coverage. |
| `CCIP` | Chainlink CCIP (EVM) | USDC over Chainlink-supported USDC pools, or a share token over an issuer-deployed CCT (CCIP Cross-Chain Token) pool. |
| `CCIP_SVM` | Chainlink CCIP to Solana | Same as CCIP with a 32-byte recipient and SVM (Solana Virtual Machine) encoding. |
| `LOCAL` | Direct ERC-20 transfer | Same-chain delivery on the hub. No bridge and no fee. |

## Synchronous settlement

The adapter serves an ERC-4626 vault. On inbound delivery it deposits or redeems, then delivers the output, in one hub transaction. The `minAmountOut` check applies to the delivered amount (see Slippage below). The outbound bridge fee is paid by the issuer's reserve or by the user's prefund.

## Failure model

Both inbound entrypoints are `nonReentrant` and callable only by the configured router or endpoint. If the vault action or delivery reverts for any reason, including a paused adapter or a CCIP source that is not allowlisted, the transaction does not brick the transfer. The adapter captures the inbound tokens and emits `MessageFailed(guid, ...)`. Three recovery paths exist:

| Call | Who may call | Effect |
|---|---|---|
| `refundToSource` | Anyone, unless the message set `onlyLocalRefund` with a handler | Sends the held tokens back to the sender on the source chain over the inbound rail. |
| `retryFailedMessage` | The message's `failedMessageHandler` | Re-executes the message after the cause clears. |
| `refundLocal` | The message's `failedMessageHandler` | Sends the held tokens to a hub-local address. |

Recovery callers pay the outbound bridge fee with `msg.value`. No admin role appears in any recovery path. See [Tracking and failure handling](../integrators/failures.md).

## Slippage

`minAmountOut` in the `VaultMessage` is the user's floor on the delivered amount, in output-token units. Shares on deposit. Assets on redeem. The adapter enforces it end-to-end: a measured balance check for `LOCAL`, a source-side check for CCIP rails, and the bridge's `minAmountLD` for OFT and Stargate. A breach reverts and the tokens are captured for recovery. There is no issuer-set slippage parameter.
