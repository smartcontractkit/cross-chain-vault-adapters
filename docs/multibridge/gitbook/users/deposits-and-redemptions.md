# Deposits and redemptions

The vault lives on one chain. You do not need to be on that chain to use it.

## A cross-chain deposit

1. You send the vault's asset (for example USDC or USDT) from your chain, in one transaction from your wallet or the front end you use.
2. A bridge network carries the tokens and your instructions to the vault's chain.
3. The adapter deposits your tokens into the vault and receives vault shares.
4. The adapter sends the shares to the recipient address on the chain you chose. You can receive them on your origin chain, on the vault's chain, or on any other supported chain.

## A cross-chain redemption

The same flow in reverse. You send your vault shares in. The adapter redeems them and sends the asset to the recipient on the chain you chose.

## What you control per transfer

| Choice | Meaning |
|---|---|
| Destination chain | Where the output tokens are delivered. Any chain the vault issuer has enabled. |
| Recipient | The address that receives the output. It can differ from your sending address. |
| Minimum amount out | A floor on what you receive. If the transfer cannot meet it, no exchange happens and your tokens are held for a refund. |

## Settlement

The vault settles instantly. One transaction on the vault's chain completes your deposit or redemption, and delivery follows immediately.

## What the vault issuer can and cannot do

The issuer chooses which chains and tokens are enabled, configures routes, and sets fees. The issuer cannot take your tokens or block a refund of a failed transfer. No issuer key can move user funds.
