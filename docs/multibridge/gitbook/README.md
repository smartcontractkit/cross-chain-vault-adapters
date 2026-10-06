# Cross-Chain Vault Adapter

The cross-chain vault adapter lets users deposit into and redeem from a single vault from other chains. The vault lives on one home chain, called the hub. Users send tokens from any allowed source chain, called a spoke. The adapter performs the vault action on the hub and delivers the result to a destination the user chose.

The adapter moves tokens over three bridge networks: Chainlink CCIP (Cross-Chain Interoperability Protocol), LayerZero V2 OFT (Omnichain Fungible Token), and Stargate V2. It reaches Solana over CCIP and LayerZero.

Use this adapter when the vault's deposit asset (or its share token) is bridged over LayerZero OFT or Stargate. If both the deposit asset and the share token are CCIP-enabled, use the [CCIP implementation](../../ccip/README.md) instead; see [Choosing an implementation](../../../README.md#choosing-an-implementation).

## Who this book is for

| You are | Read |
|---|---|
| A vault issuer who will operate an adapter | [Vault issuers](issuers/deploying-an-adapter.md) |
| A front end or protocol integrating cross-chain deposits | [Front end integrators](integrators/originating-transfers.md) |
| A user making cross-chain deposits or redemptions | [Users](users/deposits-and-redemptions.md) |

All three groups should read [How it works](overview/how-it-works.md) first.

## System layers

| Layer | Contract | Function |
|---|---|---|
| Transport | `MultiChannelBridgeAdapter` | Receives and sends tokens over CCIP, LayerZero V2 OFT, and Stargate V2. Captures failed deliveries for recovery. |
| Routing | `RouteRegistry` | Selects one of five delivery rails per `(token, destination)` pair. |
| Vault adapter | `CrossChainVaultAdapter` | Performs the ERC-4626 deposit or redeem and delivers the result in one hub transaction. |

Each deployment serves exactly one ERC-4626 vault. The adapter implementation is `CrossChainVaultAdapter` (`typeAndVersion` `CrossChainVaultAdapter 1.0.0`).

## Core properties

- The issuer does not custody user funds. The adapter admin configures lanes and fees. It cannot move user tokens or funds in flight.
- Recovery of failed deliveries is permissionless or driven by a handler the user named in the message. No admin role appears in any recovery path. The issuer can pause new processing, but refunds keep working while paused.
- The user picks the path. The issuer picks the universe. The issuer allowlists source chains, destinations, and rails. The user chooses an allowed destination per transfer.
- Adapters are non-upgradeable EIP-1167 clones of a fixed implementation. Behavior changes only by deploying a new adapter.

## Security status

See [Known limitations](reference/limitations.md) for trust assumptions. Verify all router, endpoint, and pool addresses against official directories before mainnet use.
