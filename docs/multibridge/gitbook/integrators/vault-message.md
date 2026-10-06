# The VaultMessage

Every origination carries one ABI-encoded `VaultMessage`:

```solidity
struct VaultMessage {
    uint256 minAmountOut;
    uint64 destination;
    bytes32 recipient;
    address failedMessageHandler;
    bool onlyLocalRefund;
}
```

Encode with `abi.encode(vaultMessage)`. Place it in `message.data` for CCIP or `composeMsg` for LayerZero and Stargate.

## Fields

### minAmountOut

The user's floor on the delivered amount, in output-token units: shares on deposit, assets on redeem. The adapter enforces it end-to-end on the delivered amount. A breach reverts the handling and captures the tokens for recovery. Set `0` to disable the floor.

### destination

The outbound route key. Use the key the issuer registered, typically the destination LayerZero EID or CCIP selector. `0` means `LOCAL`: deliver on the hub chain with a direct transfer.

If the issuer set no route for the pair, a legacy default applies: values up to `uint32.max` are treated as LayerZero EIDs, larger values as CCIP selectors. Do not rely on the default. Confirm route keys with the issuer.

### recipient

The beneficiary as `bytes32`. For an EVM destination, the address occupies the low 20 bytes. For Solana, use the full 32-byte wallet address of the token-account owner. Never pass an associated token account (ATA). The offramp derives the ATA from the wallet. An ATA passed here derives an off-curve owner and locks the tokens permanently.

### failedMessageHandler

Optional. The address allowed to call `retryFailedMessage` and `refundLocal` if handling fails. It also receives any surplus native prefund refund on LayerZero origins. Set it to an address that can receive native. With `address(0)`, only the permissionless `refundToSource` path exists.

Set a handler for every transfer your front end originates. It is the difference between flexible recovery and refund-to-source only.

### onlyLocalRefund

Opt-in. When `true` and a handler is set, blocks the permissionless `refundToSource`, so only the handler can recover. Ignored when no handler is set, so a message can never be frozen. Use it when a refund to the source sender would be wrong, for example when the source sender is a contract that cannot receive the token.

## What is not in the message

Outbound gas limits are issuer configuration (`setDestinationGas`). The message is intentionally small for size-constrained origins such as Solana.
