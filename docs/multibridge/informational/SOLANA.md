# Solana support: sending and receiving over all rails

Solana is non-EVM: it uses 32-byte addresses and, over CCIP, the SVM (Solana Virtual Machine) message
format. The adapter reaches Solana over CCIP, LayerZero OFT (Omnichain Fungible Token), and Stargate, in
both directions. Tests: [`test/multibridge/solana/Solana.t.sol`](../../../test/multibridge/solana/Solana.t.sol).
Validate each Solana lane on a testnet before mainnet use.

---

## Overview

The adapter carries recipients and senders as `bytes32` throughout (`VaultMessage.recipient`, the OFT
`to`, the normalized inbound `sender`), so most Solana paths need no special handling:

| Direction | CCIP | LayerZero (OFT) | Stargate |
|---|---|---|---|
| **Send to Solana** | SVM encoding (`CCIP_SVM` rail) | `bytes32 to` | `bytes32 to` |
| **Receive from Solana** | 32-byte `sender` (`_toBytes32`) | `composeFrom` | compose (`lzCompose`) |
| **Refund bounce to Solana** | SVM encoding | `bytes32 to` | LayerZero path |

CCIP is the exception: EVM CCIP encodes the recipient as `abi.encode(address)` (20 bytes), which cannot
hold a 32-byte Solana address, so CCIP's Solana lanes use a different message shape.

## The CCIP to Solana (SVM) path

Chainlink CCIP delivers to Solana with `Client.SVMExtraArgsV1`:

```solidity
EVM2AnyMessage{
  receiver: abi.encode(bytes32(0)),   // token-only transfer: 32-byte ZERO word (no destination program).
                                      // The FeeQuoter requires the SVM receiver to be exactly 32 bytes;
                                      // empty bytes revert every getFee/send on a real Solana lane.
  data: "",
  tokenAmounts: [{token, amount}],
  feeToken: address(0),               // native fee
  extraArgs: Client._svmArgsToBytes(SVMExtraArgsV1{
    computeUnits: 0,                  // must be 0 for token-only (enforced by setCcipSvmConfig)
    accountIsWritableBitmap: 0,
    allowOutOfOrderExecution: true,   // always true for SVM lanes
    tokenReceiver: <32-byte Solana recipient WALLET address (owner, NOT an ATA)>,
    accounts: []
  })
}
```

In the base (`MultiChannelBridgeAdapter`):

- `_sendViaCcipSvm(dstSelector, tokenReceiver, token, amount)` checks the CCIP destination allowlist and
  that the selector is an SVM lane, then calls the `_ccipSendSvm(...)` core.
- `s_ccipSvm[selector] => CcipSvmConfig{ enabled, computeUnits, allowOutOfOrderExecution }`, set by
  `setCcipSvmConfig(selector, enabled, computeUnits)`. `computeUnits` must be 0 when enabling
  (`SvmComputeUnitsNotZero` otherwise) and `allowOutOfOrderExecution` is always `true`. The config is
  keyed by selector, so it governs both the outbound send and the inbound bounce.
- `_bridgeBackToSource`: if the CCIP source selector is an SVM lane, the refund bounces back to the full
  32-byte Solana sender over SVM.

In the routing layer (`RouteRegistry`), the `Rail.CCIP_SVM` rail dispatches a route to
`_sendViaCcipSvm` with the message's 32-byte `recipient` as the Solana token receiver. `setRoute` rejects
a `CCIP_SVM` route whose selector is not an enabled SVM lane (`SvmLaneNotEnabled`). `LZ_OFT` and
`STARGATE` routes pass the 32-byte `recipient` through unchanged.

## Operator setup (USDC or share token to Solana over CCIP)

```solidity
app.setCcipDestination(SOLANA_SELECTOR, true);              // outbound allowlist
app.setCcipSvmConfig(SOLANA_SELECTOR, true, 0);             // mark as SVM lane (computeUnits must be 0)
app.setRoute(token, SOLANA_SELECTOR, Route({
    enabled: true, rail: Rail.CCIP_SVM,
    endpoint: address(0), dstId: SOLANA_SELECTOR // CCIP needs no endpoint; slippage is the user's minAmountOut
}));
// inbound from Solana over CCIP (any sender on the chain): app.setCcipSource(SOLANA_SELECTOR, true);
```

USDT to Solana goes over LayerZero (USDT0 Legacy Mesh) or Stargate instead; both accept a 32-byte
recipient:

```solidity
app.setLzDestination(SOLANA_EID, true);
app.setRoute(USDT, SOLANA_EID, Route({ enabled: true, rail: Rail.LZ_OFT, endpoint: USDT0_OFT, dstId: SOLANA_EID }));
// or Stargate:
app.setStargateDestination(SOLANA_EID, true);
app.setRoute(USDT, SOLANA_EID, Route({ enabled: true, rail: Rail.STARGATE, endpoint: STARGATE_USDT_POOL, dstId: SOLANA_EID }));
```

`SOLANA_EID` is Solana's LayerZero endpoint ID. The mainnet selector and EID are in
[`Networks.sol`](../../../script/multibridge/config/Networks.sol).

## Which token over which rail

- **Native USDT to Solana:** LayerZero (USDT0 Legacy Mesh) or Stargate. Never CCIP: native USDT is not a
  CCIP token.
- **USDC or the share token to Solana:** CCIP over the `CCIP_SVM` rail (needs a CCIP token pool on Solana
  for that token), or Stargate for USDC.
- Receiving from Solana works for any token the rail delivers as a local EVM token on the hub.

## Tests

`test/multibridge/solana/Solana.t.sol` sends to Solana over each rail and asserts that the full 32-byte
recipient survives (CCIP: decodes `SVMExtraArgsV1.tokenReceiver`; LayerZero and Stargate: the mock's
recorded `to`). It also receives a deposit from Solana over LayerZero, receives over CCIP and then
refund-bounces back to the 32-byte Solana sender over SVM, and covers `setCcipSvmConfig` set, clear, and
admin-only access.

## Caveats

- **Compute units and accounts:** for a token transfer to a Solana wallet, `computeUnits = 0` and empty
  `accounts` are correct, and `setCcipSvmConfig` enforces `computeUnits == 0` (the FeeQuoter rejects a
  non-zero budget when the receiver is the zero word). Targeting a Solana receiver program is not
  supported.
- **Identifiers:** the selectors and EIDs in the tests are illustrative. Use the values in `Networks.sol`
  and confirm them, and the destination token pools, against the official CCIP, LayerZero, and Stargate
  directories.
- **`tokenReceiver` must be the recipient's wallet address (the token-account owner), never an
  associated token account (ATA).** The Solana offramp derives the recipient's ATA from this wallet
  address. Supplying an ATA makes the offramp derive a token account owned by the ATA's own public key,
  an off-curve address no signature can be produced for, which permanently locks the bridged tokens.
  Encode the wallet address as the message `recipient`.
