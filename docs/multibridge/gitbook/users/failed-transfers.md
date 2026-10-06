# If a transfer fails

A transfer can fail on the vault's chain: the price moved below your floor, the vault or the adapter was paused, or a route was disabled. Failure does not lose your tokens. The adapter holds them and records the failure. The design has no path for anyone, including the vault issuer, to take held tokens.

## Recovery options

| Option | Who can trigger it | Result |
|---|---|---|
| Refund to source | Anyone | Your tokens return to the sending address on your origin chain. |
| Retry | The handler named in your transfer, usually your front end | The transfer re-executes after the cause clears. |
| Local payout | The handler | Your tokens are delivered to an address on the vault's chain. |

Refund to source is permissionless. Even if the front end you used disappears, any party can trigger the refund, and the issuer cannot block it. The refund trigger pays the bridge fee for the return trip. The one exception is a transfer that opted into handler-only recovery (`onlyLocalRefund`): then only the named handler can resolve it.

## What to do

1. Use your transfer's tracking ID. Front ends show it, and the public bridge explorers ([CCIP Explorer](https://ccip.chain.link) for CCIP, [LayerZero Scan](https://layerzeroscan.com) for LayerZero and Stargate) let you follow the message.
2. Check the front end's transfer status page. Most front ends detect failures and offer retry or refund directly.
3. If the front end does not resolve it, request a refund to source. Any wallet can call `refundToSource` on the adapter with the failed message data. The issuer's documentation or support channel can provide the exact call.
