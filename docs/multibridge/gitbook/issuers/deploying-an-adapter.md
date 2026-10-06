# Deploying an adapter

One factory call deploys a configured adapter. The factory clones a published implementation as an EIP-1167 minimal proxy, initializes it with the CCIP router, the LayerZero endpoint, and the vault, installs allowlists and fees, optionally funds the native reserve, and grants all roles to your `owner` address. The handoff is one step. There is no accept transaction.

## Implementation and factory

`CrossChainVaultAdapterFactory` is bound to the published `CrossChainVaultAdapter` implementation (`typeAndVersion` `CrossChainVaultAdapter 1.0.0`, synchronous ERC-4626). `script/multibridge/DeployImplementationAndFactory.s.sol` deploys both, once per chain; from the repository root run `pnpm multibridge:deploy-factory --rpc-url <RPC_URL> --account <KEYSTORE> --broadcast --verify`, which uses the deploy compiler settings (`FOUNDRY_PROFILE=deploy`). Each vault issuer then calls `factory.deploy(DeployConfig)`.

## Prerequisites

CCT is the CCIP Cross-Chain Token standard, OFT is LayerZero's Omnichain Fungible Token standard, and an EID is a LayerZero endpoint ID.

| Prerequisite | Who provides it |
|---|---|
| CCIP router address and chain selectors | Chainlink CCIP directory |
| LayerZero endpoint and EIDs | LayerZero deployments |
| CCT pool for the share token, per CCIP lane | You, if shares leave the hub over CCIP |
| OFT peers and DVN (decentralized verifier network) configuration | Token issuer, if the asset or shares leave over LayerZero |
| Stargate pool on hub and spoke | Stargate, if you use Stargate rails |
| Native reserve on the adapter | You, via `fundWei` at deploy or by sending native later |

USDC over CCIP uses the USDC pools Chainlink supports on each lane. No issuer deployment is needed for it; confirm the lane lists USDC in the CCIP directory.

## DeployConfig

```solidity
struct DeployConfig {
    address ccipRouter;
    address lzEndpoint;
    address owner;                 // final admin; must not be the factory
    address feeCollector;          // overrides FEE_COLLECTOR_ROLE holder when non-zero
    address vault;
    uint32[] lzSrcEids;            // inbound LayerZero sources
    address[] lzSrcOfts;           // paired OFT per source EID
    uint64[] ccipSrcSelectors;     // inbound CCIP sources
    uint64[] ccipDstSelectors;     // outbound CCIP destinations
    uint32[] lzDstEids;            // outbound LayerZero destinations
    address[] oftTokens;           // token -> OFT map
    address[] ofts;
    bool requireLzReturnPrefunded; // require native prefund on LZ/Stargate origins
    address[] inboundFeeOutboundTokens;
    uint64[] inboundFeeDestinations;
    uint256[] inboundFeeAmounts;
}
```

`factory.deploy(DeployConfig)` grants `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` to `owner`. A non-zero `feeCollector` receives `FEE_COLLECTOR_ROLE` instead of `owner`.

Registry routes (`setRoute`), Stargate destinations (`setStargateDestination`), and Solana lanes (`setCcipSvmConfig`) are not installed by the factory. Apply them after the handoff as the new admin. The production script does this for you.

## Production deployment

Use `script/multibridge/DeployProduction.s.sol` (`pnpm multibridge:deploy`) with a multi-network configuration. The script resolves a high-level config (home chain, vault, routes) against the `script/multibridge/config/Networks.sol` address book and installs the full route registry. See `docs/multibridge/operator/DEPLOYMENT_CONFIG.md` in the repository for field-level detail.

Some entries in `Networks.sol` are flagged `VERIFY`. Reconfirm every address you use against the official Chainlink, LayerZero, and Stargate directories before mainnet deployment.

## Immutable after initialization

| Field | Reason |
|---|---|
| `vault` | Bound at `initialize` |
| `ccipRouter`, `lzEndpoint` | Bound at `initialize` |

To change any of these, deploy a new adapter. Allowlists, routes, fees, and gas settings remain updatable on a live clone.
