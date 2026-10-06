# Fees, timing, and slippage

## Fees

A cross-chain transfer can include up to three costs:

1. Gas on your origin chain, plus the bridge network's fee for carrying your tokens. You pay these in the origin transaction.
2. A return-leg cost for delivering the output to your chosen chain. Depending on the route, this is either a small flat fee taken from the tokens you send, or a gas prepayment your front end attaches to the transaction. Your front end shows which applies. Unused prepayment is returned to the recovery handler named in your transfer, if there is one.
3. The vault's own fees, if the vault charges any. The adapter does not add vault fees.

Delivery on the vault's own chain has no return-leg cost.

## Timing

- Bridge delivery takes as long as the underlying bridge network (CCIP, LayerZero, or Stargate) takes to finalize and deliver on the destination. This is minutes in the normal case and depends on the chains involved.
- The vault completes the deposit or redemption in the same transaction that receives your tokens.

## Slippage

You set a minimum amount out per transfer. It is a floor on the tokens delivered to your recipient, measured end to end. If the exchange rate at execution would deliver less, the transfer does not execute. Your tokens are held for a refund instead. You never receive less than your floor without a refund path.
