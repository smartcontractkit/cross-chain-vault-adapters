# Tenderly E2E: deploy and originate cross-chain vault transfers

End-to-end harness for exercising the vault adapter on Tenderly Virtual TestNets (mainnet forks). You
deploy the adapter on the hub (the chain where the ERC-4626 vault lives) through the factory, then
originate a deposit or redeem from a spoke with the official SDKs: the Chainlink CCIP SDK
(`@chainlink/ccip-sdk`) for CCIP, and the LayerZero options SDK (`@layerzerolabs/lz-v2-utilities`) plus
the OFT (Omnichain Fungible Token) contract for LayerZero. On the hub, the adapter performs the vault
action and sends the result onward.

```text
 spoke fork (source)                         hub fork (vault chain)
 ┌───────────────────┐    relay (see §4)    ┌──────────────────────────┐
 │ originate (SDK):  │  ───────────────────▶│ adapter.ccipReceive /    │
 │  ccipSend /       │                      │   lzCompose → deposit/   │
 │  OFT.send + data  │                      │   redeem → send result   │
 └───────────────────┘                      └──────────────────────────┘
```

Two steps, one shared config (`config/multibridge/tenderly.json`):

| Step | Tool | Runs on |
|------|------|---------|
| 1. Deploy and activate the adapter through the factory | Foundry script | hub RPC |
| 2. Originate a deposit or redeem | TypeScript with the CCIP/LayerZero SDKs (`e2e/multibridge/`) | spoke RPC |

For real testnet delivery instead of forks, use the Sepolia flow in
[`e2e/multibridge/README.md`](../../../e2e/multibridge/README.md).

---

## 0. Prerequisites

- Two Tenderly Virtual TestNets (for example Ethereum as hub, Arbitrum as spoke), each with an admin RPC
  URL.
- Foundry (`forge`), Node.js 20.11 or later, and pnpm, with `pnpm install` run at the repo root.
- The mainnet addresses for each fork: CCIP router, LayerZero EndpointV2, the ERC-4626 vault and its
  asset, and the OFTs for any LayerZero-routed token. The token lanes (CCT pools, the CCIP Cross-Chain Token standard; OFT peers) must already
  be configured for the tokens you route; that is a property of the tokens, not of this adapter.
- Native gas for your deployer and originator on each fork (Tenderly faucet), and the source token for
  the originator.

## 1. Configure

```bash
cp config/multibridge/tenderly.example.json config/multibridge/tenderly.json   # fill in hub, spoke, vaultAdapter, scenario
cp e2e/multibridge/.env.example e2e/multibridge/.env                            # RPC URLs + originator PRIVATE_KEY
```

In `e2e/multibridge/.env`, set `CONFIG=config/multibridge/tenderly.json` (the example file defaults to
the Sepolia config), and set `HUB_RPC_URL` and `SPOKE_A_RPC_URL` (or whatever names `rpcUrlEnv` uses in
your config) to the Virtual TestNet RPCs.

`config/multibridge/tenderly.json` drives both steps. Field meanings are inline in
[`config/multibridge/tenderly.example.json`](../../../config/multibridge/tenderly.example.json); the key
blocks:

- **`hub` / `spoke`**: per-fork `ccipRouter`, `lzEndpoint`, `ccipChainSelector`, `lzEid` (LayerZero
  endpoint ID), `chainId`, and `rpcUrlEnv` (the env var holding that fork's RPC URL). On `hub` you may set
  `factory` / `implementation` to reuse published ones (zero means the deploy script publishes new ones).
- **`vaultAdapter`**: the `CrossChainVaultAdapterFactory.deploy(DeployConfig)` inputs: `owner`,
  `feeCollector`, `vault`, `fundWei`, the inbound allowlists (`ccipSrcSelectors`, and
  `lzSrcEids`/`lzSrcOfts` pairs of spoke EID and hub-local OFT), outbound destinations
  (`ccipDstSelectors`, `lzDstEids`), OFT registrations (`oftTokens`/`ofts`), and return-leg fees
  (`requireLzReturnPrefunded`, `inboundFees`). The loader also requires `asset` and `share` (the vault's
  underlying and share token, used to resolve `inboundFees[].outboundToken`); add them if your copy of the
  example does not have them. See [`DEPLOYMENT.md`](../operator/DEPLOYMENT.md#22-the-config-tuple--field-order-and-meaning)
  for every `DeployConfig` field.
- **`scenario`**: what step 2 originates: the inbound rail (`channel`: `ccip` or `layerzero`), the
  source token (plus `srcOft` for LayerZero), `amount`, the inbound gas limits, `returnLegValueWei`
  (native attached to a LayerZero compose to prepay the outbound return leg; 0 lets the hub's reserve
  fund it), and the `message`: `VaultMessage{ minAmountOut, destination, recipient,
  failedMessageHandler, onlyLocalRefund }` (`onlyLocalRefund` is optional and defaults to `false`).
  `destination` is the outbound key for the produced token: a CCIP selector (`> 4294967295`) or a
  LayerZero EID (`<= 4294967295`), allowlisted on that rail. Outbound gas is operator configuration, not
  part of the message. `failedMessageHandler` (optional) may retry or refund locally on failure; zero
  means only the permissionless bounce to source.

> **Allowlists:** for CCIP inbound the adapter checks the source chain selector only
> (`ccipSrcSelectors`). For LayerZero inbound it checks `(spoke eid, hub-local OFT)`, so
> `vaultAdapter.lzSrcOfts` is the OFT on the hub that delivers the token through `lzCompose`.

## 2. Deploy on the hub (Foundry)

```bash
set -a; source e2e/multibridge/.env; set +a   # load HUB_RPC_URL, PRIVATE_KEY, CONFIG

FOUNDRY_PROFILE=deploy forge script script/multibridge/tenderly/DeployVaultAdapter.s.sol:DeployVaultAdapter \
  --rpc-url "$HUB_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --slow
```

[`DeployVaultAdapter`](../../../script/multibridge/tenderly/DeployVaultAdapter.s.sol) publishes the
implementation and factory (unless reused), calls `factory.deploy{value: fundWei}(...)`, and writes
`deployments/multibridge/<hubChainId>.json` (`{ chainId, app, factory, implementation }`), which step 2
reads. The clone is operational immediately; `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and
`FEE_COLLECTOR_ROLE` go to `vaultAdapter.owner` (a non-zero `feeCollector` gets the collector role
instead). The script installs no registry routes, so outbound delivery uses the legacy default (EID or
selector by size, LayerZero sends through the `oftTokens`/`ofts` map). Add routes with `setRoute` as the
admin if you need `STARGATE`, `CCIP_SVM`, or `LOCAL`.

## 3. Originate a deposit or redeem from the spoke

Run from the repo root:

```bash
pnpm e2e:multibridge initiate                     # uses scenario.channel from the config
CHANNEL=layerzero pnpm e2e:multibridge initiate   # override the rail
```

- **CCIP** ([`e2e/multibridge/src/ccip.ts`](../../../e2e/multibridge/src/ccip.ts)): approves the source
  token to the router, then `@chainlink/ccip-sdk` (`EVMChain.fromUrl(...).sendMessage(...)`) sends a
  programmable token transfer (the token plus the ABI-encoded `VaultMessage` as `data`) to the hub
  adapter with `extraArgs.gasLimit = scenario.inboundGasLimit` (non-zero so CCIP invokes `ccipReceive`).
- **LayerZero** ([`e2e/multibridge/src/lz.ts`](../../../e2e/multibridge/src/lz.ts)): builds executor
  options with `@layerzerolabs/lz-v2-utilities` (`addExecutorLzReceiveOption` plus
  `addExecutorComposeOption`), quotes the OFT, approves if needed, and calls `OFT.send(...)` with the
  `VaultMessage` as the compose payload, so the hub endpoint invokes `lzCompose` on the adapter.

The script prints the source transaction hash and the CCIP `messageId` or LayerZero `guid`.

## 4. Deliver on the hub and observe

Virtual TestNets do not run the CCIP DON (decentralized oracle network) or LayerZero DVNs and executors,
and the harness does not relay messages. To complete a transfer, deliver it on the hub fork yourself, for
example by impersonating the hub's CCIP router and calling `ccipReceive`, or impersonating the LayerZero
endpoint and calling `lzCompose` with the OFT compose message.

`CrossChainVaultAdapter` is synchronous; a delivery either completes in one transaction or is captured:

- **Success:** the vault action runs and the produced token leaves the hub (`VaultDelivered`).
- **Failure** (malformed payload, unsupported token, `minAmountOut` breach, outbound-leg shortfall): the
  vault action rolls back and the base captures the inbound token; `isFailed(guid)` is true. Recovery
  needs no operator: anyone may call `refundToSource(inbound)` to bounce it back to the origin sender
  (unless the message set `onlyLocalRefund` with a handler), or the message's `failedMessageHandler` may
  call `retryFailedMessage` / `refundLocal`. `GUID=<id> pnpm e2e:multibridge recover:refund` does the
  bounce. See [`FAILED_MESSAGE_RESOLUTION.md`](../informational/FAILED_MESSAGE_RESOLUTION.md).

---

## Notes

- **Big numbers:** chain selectors and wei amounts may be JSON numbers or `0x`-hex strings; Foundry and
  the TypeScript loader both read them without precision loss.
- **CCIP SDK:** the harness uses `@chainlink/ccip-sdk`, which exposes `extraArgs` and the gas limit
  needed to invoke the receiver. See the [CCIP SDK documentation](https://docs.chain.link/ccip/tools/sdk).
