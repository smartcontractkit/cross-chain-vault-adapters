# Multibridge implementation

The multibridge implementation is a cross-chain ERC-4626 vault adapter that receives and sends tokens
over Chainlink CCIP (Cross-Chain Interoperability Protocol), LayerZero V2 OFT (Omnichain Fungible
Token), and Stargate V2, including CCIP to Solana. A user sends the vault's asset or share token from a
source chain with a small `VaultMessage`. The adapter on the vault's chain deposits or redeems in the same
transaction and delivers the result to the destination and recipient the user chose. If anything fails,
the inbound tokens are captured on the adapter and can be recovered without the operator.

Use this implementation when the vault's deposit asset (or its share token) is bridged over LayerZero OFT
or Stargate. If both the deposit asset and the share token are CCIP-enabled, use the
[CCIP implementation](../ccip/README.md) instead; see
[Choosing an implementation](../../README.md#choosing-an-implementation).

This release ships one adapter, `CrossChainVaultAdapter` (`typeAndVersion` `CrossChainVaultAdapter
1.0.0`), deployed as EIP-1167 clones by `CrossChainVaultAdapterFactory`. It encodes CCIP messages with
CCIP v1 `GenericExtraArgsV2`. For CCIP v2 lanes, use the CCIP implementation
(`CrossChainERC4626Adapter`, see [`../ccip/README.md`](../ccip/README.md)).

## Architecture

| Layer | Contract | Role |
|---|---|---|
| Transport | [`MultiChannelBridgeAdapter`](../../src/multibridge/MultiChannelBridgeAdapter.sol) | Receives over CCIP (`ccipReceive`) and LayerZero compose (`lzCompose`, which also carries Stargate), normalizes each delivery into one `Inbound` struct, and calls the `_handleReceive` hook. Provides the send helpers (`_sendViaCcip`, `_sendViaOft`, `_sendViaStargate`, `_sendViaCcipSvm`), the Solana (SVM) encoding, pause, and failed-message capture and recovery (`refundToSource`, `retryFailedMessage`, `refundLocal`). |
| Routing | [`RouteRegistry`](../../src/multibridge/routing/RouteRegistry.sol) | Per `(token, destination)` route that selects one of five rails: `LZ_OFT`, `CCIP`, `STARGATE`, `CCIP_SVM` (Solana), or `LOCAL` (same-chain transfer). Enforces `minAmountOut` on the delivered amount. |
| Vault adapter | [`CrossChainVaultAdapter`](../../src/multibridge/examples/CrossChainVaultAdapter.sol) | One ERC-4626 vault per clone. Asset in means deposit, share in means redeem. Adds return-leg fee policy (CCIP inbound fee skim, LayerZero prefund requirement). |
| Factory | [`CrossChainVaultAdapterFactory`](../../src/multibridge/CrossChainVaultAdapterFactory.sol) on [`VaultAdapterFactoryBase`](../../src/multibridge/VaultAdapterFactoryBase.sol) | `deploy(DeployConfig)` clones the published implementation, initializes it, installs allowlists, the OFT map and return-leg fees, optionally funds the native reserve, and hands all roles to `owner` in one transaction. |
| Roles | [`AdapterRoles`](../../src/multibridge/AdapterRoles.sol) | `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE`, next to OpenZeppelin's `DEFAULT_ADMIN_ROLE`. |
| Interface | [`IStargate`](../../src/multibridge/stargate/IStargate.sol) | Minimal Stargate V2 interface. |

The `VaultMessage` carried in the inbound payload has five fields: `minAmountOut`, `destination`,
`recipient`, `failedMessageHandler`, and `onlyLocalRefund`. See
[`gitbook/integrators/vault-message.md`](gitbook/integrators/vault-message.md).

## Build and test

Run everything from the repository root; see the [root README](../../README.md) for setup.

```bash
pnpm install
pnpm test:multibridge       # unit, integration, and deploy-script tests (excludes fork tests)
pnpm test:fork              # Ethereum Sepolia fork tests (HUB_RPC_URL, defaults to a public RPC)
pnpm solhint:multibridge    # lint src/multibridge
pnpm sizes                  # contract sizes under the deploy profile
```

Deploy with `FOUNDRY_PROFILE=deploy` (`via_ir`, `optimizer_runs = 1`). It produces the deployment
bytecode. Under that profile `CrossChainVaultAdapter` is 24,457 bytes of runtime code, within the
EIP-170 limit. The bytecode targets the `paris` EVM version, so it deploys on any EVM chain.

## Deploy

JSON configuration for the deploy scripts lives in [`config/multibridge/`](../../config/multibridge/).
Scripts write deployment outputs to `deployments/multibridge/<chainId>.json`.

1. Publish the implementation and factory once per chain with
   [`DeployImplementationAndFactory`](../../script/multibridge/DeployImplementationAndFactory.s.sol):

   ```bash
   pnpm multibridge:deploy-factory --rpc-url <RPC_URL> --account <KEYSTORE> --broadcast --verify
   ```

2. Deploy an adapter in one of two ways:
   - Call `factory.deploy(DeployConfig)` directly (for example from a block explorer). Field-by-field
     guide: [`operator/DEPLOYMENT.md`](operator/DEPLOYMENT.md). Routes are then set by the admin with
     `setRoute`.
   - Run [`DeployProduction`](../../script/multibridge/DeployProduction.s.sol)
     (`pnpm multibridge:deploy`) with `config/multibridge/deployment.json`. It resolves a home chain,
     vault, and `routes[]` list (each route is a network, token, and rail) against the
     [`Networks`](../../script/multibridge/config/Networks.sol) address book and installs the whole route
     registry in the same broadcast. See [`operator/DEPLOYMENT_CONFIG.md`](operator/DEPLOYMENT_CONFIG.md).

3. Configure lanes, routes, and fees, and operate the adapter:
   [`operator/OPERATOR_GUIDE.md`](operator/OPERATOR_GUIDE.md) and
   [`informational/RETURN_LEG_HANDLING.md`](informational/RETURN_LEG_HANDLING.md).

## End-to-end testing and frontend

- Sepolia testnets (real CCIP and LayerZero delivery): [`e2e/multibridge/README.md`](../../e2e/multibridge/README.md).
  The Sepolia config ships without adapter addresses; deploy the adapter first with
  `bash script/multibridge/deploy-factory-sepolia.sh` and `bash script/multibridge/deploy-adapter-sepolia.sh`.
- Tenderly Virtual TestNets (mainnet forks): [`development/TENDERLY_E2E.md`](development/TENDERLY_E2E.md).
- Reference frontend (unaudited) to load an adapter, send deposits and redemptions, and recover failed
  messages: [`frontend/multibridge/README.md`](../../frontend/multibridge/README.md).

## Documentation map

| Doc | Purpose |
|---|---|
| **Operators** | |
| [`operator/OPERATOR_GUIDE.md`](operator/OPERATOR_GUIDE.md) | Roles, routes, fees, monitoring, pause, recovery, Sepolia scripts |
| [`operator/DEPLOYMENT.md`](operator/DEPLOYMENT.md) | Implementation and factory publication; `factory.deploy(DeployConfig)` field by field |
| [`operator/DEPLOYMENT_CONFIG.md`](operator/DEPLOYMENT_CONFIG.md) | `DeployProduction` config and the mainnet address book |
| **How the system works** | |
| [`informational/FUNCTIONALITY.md`](informational/FUNCTIONALITY.md) | Flows, roles, message format, supported-token matrix, success and failure modes |
| [`informational/RETURN_LEG_HANDLING.md`](informational/RETURN_LEG_HANDLING.md) | Return-leg fees, native reserve, CCIP skim versus LayerZero prefund |
| [`informational/FAILED_MESSAGE_RESOLUTION.md`](informational/FAILED_MESSAGE_RESOLUTION.md) | Finding, inspecting, and recovering captured messages |
| [`informational/STARGATE.md`](informational/STARGATE.md) | Stargate V2 rail and the route registry |
| [`informational/SOLANA.md`](informational/SOLANA.md) | Solana over CCIP (SVM), LayerZero, and Stargate |
| [`informational/NATIVE_USDT.md`](informational/NATIVE_USDT.md) | Native USDT on Ethereum and BNB Chain |
| [`informational/KNOWN_LIMITATIONS.md`](informational/KNOWN_LIMITATIONS.md) | Limits and trust assumptions |
| **Development** | |
| [`development/MULTI_CHANNEL_BRIDGE_ADAPTER.md`](development/MULTI_CHANNEL_BRIDGE_ADAPTER.md) | Transport base design, for building on or extending it |
| [`development/TENDERLY_E2E.md`](development/TENDERLY_E2E.md) | Tenderly fork E2E harness |
| **User-facing book** | |
| [`gitbook/`](gitbook/README.md) | GitBook for vault issuers, front end integrators, and users ([table of contents](gitbook/SUMMARY.md)) |
