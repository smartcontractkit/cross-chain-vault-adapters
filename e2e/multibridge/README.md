# Multibridge E2E harness

TypeScript scripts that exercise a deployed multibridge `CrossChainVaultAdapter` end to end. They originate
real deposit and redeem transfers from a spoke chain to the hub adapter over CCIP, LayerZero OFT (Omnichain Fungible Token), or
Stargate, recover failed messages, and print an adapter's on-chain configuration.

These scripts send real transactions from the key in your `.env`. Use testnets or Tenderly Virtual TestNets and
a throwaway key.

## Two environments

| | Sepolia testnets | Tenderly Virtual TestNets |
|---|---|---|
| Config | [`config/multibridge/sepolia.json`](../../config/multibridge/sepolia.json) | Copy [`config/multibridge/tenderly.example.json`](../../config/multibridge/tenderly.example.json) to `config/multibridge/tenderly.json` |
| Hub | Ethereum Sepolia | A mainnet fork |
| Spokes | Arbitrum Sepolia, BNB testnet, Avalanche Fuji | One spoke fork |
| Message relay | Real CCIP and LayerZero delivery | Not automatic: deliver on the hub yourself, for example by impersonating the router or endpoint; see [TENDERLY_E2E.md](../../docs/multibridge/development/TENDERLY_E2E.md) |
| Scenarios | Named, under `scenarios` (select with `SCENARIO`) | A single `scenario` block |

## Setup

1. Install dependencies from the repo root: `pnpm install`.
2. `cp e2e/multibridge/.env.example e2e/multibridge/.env` and fill in `PRIVATE_KEY`, the RPC URLs, and `CONFIG`
   (`config/multibridge/sepolia.json` or `config/multibridge/tenderly.json`). Every variable is documented in
   [`.env.example`](.env.example).
3. Deploy the adapter to the hub. `sepolia.json` ships without adapter addresses, so you deploy your own:

   ```bash
   bash script/multibridge/deploy-factory-sepolia.sh    # implementation + factory; paste both into hub.* in the config
   bash script/multibridge/deploy-adapter-sepolia.sh    # clone + routes; writes deployments/multibridge/11155111.json
   ```

   The deploy helpers sign with `PRIVATE_KEY` when it is set, otherwise with the Foundry keystore named by
   `FOUNDRY_ACCOUNT` (default `vaultdeployer`), and verify on Etherscan when `ETHERSCAN_API_KEY` is set. Then
   set `adapters.usdt.app` (and `adapters.usdc.app` if you deploy the USDC adapter with
   `deploy-adapter-usdc-sepolia.sh`) to the new clone; the harness reads the adapter address from there (or
   from `ADAPTER`). For Tenderly, run `script/multibridge/tenderly/DeployVaultAdapter.s.sol` as described in
   [TENDERLY_E2E.md](../../docs/multibridge/development/TENDERLY_E2E.md).
4. Fund the originator on the spoke with gas and the source token of the scenario you run: the asset for a
   deposit, or the bridged vault share for a redeem (set `spokes.<key>.shareToken` in the config, or
   `SPOKE_<KEY>_SHARE_TOKEN` in `.env`, for example `SPOKE_ARBITRUM_SEPOLIA_SHARE_TOKEN`).

## Commands

Run from the repo root. `pnpm e2e:multibridge <script>` runs a script from [`package.json`](package.json) inside
`e2e/multibridge`.

| Command | What it does |
|---|---|
| `pnpm e2e:multibridge initiate` | Originates the scenario selected by `SCENARIO` (or the single Tenderly `scenario`) and prints the message id |
| `pnpm e2e:multibridge initiate:deposit:fuji:usdc` | USDC deposit from Fuji over CCIP; shares return to Fuji over CCIP |
| `pnpm e2e:multibridge initiate:redeem:fuji:usdc` | Share redeem from Fuji over CCIP; USDC returns over CCIP |
| `pnpm e2e:multibridge initiate:stargate:arbitrum` / `:bsc` | USDT deposit over Stargate; shares return over CCIP |
| `pnpm e2e:multibridge initiate:redeem:arbitrum` / `:bsc` | Share redeem over CCIP; USDT returns over Stargate |
| `pnpm e2e:multibridge initiate:usdt0` | USDT0 OFT scenario (expects `UnsupportedToken` unless the vault asset matches) |
| `pnpm e2e:multibridge initiate:fail:<deposit\|redeem>:<arbitrum\|bsc\|fuji:usdc>` | Same flows with `minAmountOut` forced to the maximum, so the hub captures the message as failed |
| `GUID=<id> pnpm e2e:multibridge recover:status` | Shows whether a message was captured as failed on the hub |
| `GUID=<id> pnpm e2e:multibridge recover:refund` | Calls `refundToSource` for a failed message, bouncing the tokens back to the sender on the source chain |
| `ADAPTER=<clone> pnpm e2e:multibridge inspect:adapter` | Prints the adapter's roles, transport, allowlists, routes, and fees, and compares them with the config (reads `HUB_RPC_URL`) |
| `pnpm e2e:multibridge typecheck` | Type-checks the harness |

`initiate` prints the source transaction hash and the CCIP message id or LayerZero guid. Track CCIP messages on the
[CCIP Explorer](https://ccip.chain.link) and LayerZero messages on [LayerZero Scan](https://testnet.layerzeroscan.com)
(testnet). After a failure, recover with `recover:refund` or see
[FAILED_MESSAGE_RESOLUTION.md](../../docs/multibridge/informational/FAILED_MESSAGE_RESOLUTION.md) for the
handler-only paths.

The shell wrappers [`script/multibridge/run-spoke-e2e.sh`](../../script/multibridge/run-spoke-e2e.sh) and
[`run-fuji-usdc-e2e.sh`](../../script/multibridge/run-fuji-usdc-e2e.sh) run a full sequence of scenarios, including the
failure and recovery flows, and write per-step logs and a `summary.md` to `logs/spoke-e2e-<timestamp>/` and
`logs/fuji-usdc-e2e-<timestamp>/`. Both accept `--only <group>`, `--recover-fail`, and `--dry-run`; run them with
`--help` for the full list.

## The message the harness sends

[`src/message.ts`](src/message.ts) ABI-encodes the adapter's `VaultMessage`
`(uint256 minAmountOut, uint64 destination, bytes32 recipient, address failedMessageHandler, bool onlyLocalRefund)`
from the scenario's `message` block. `onlyLocalRefund` is optional and defaults to `false`. When it is `true` and a
`failedMessageHandler` is set, only that handler can recover a failed message (`retryFailedMessage` or
`refundLocal`), and the permissionless `refundToSource` used by `recover:refund` is disabled. See
[vault-message.md](../../docs/multibridge/gitbook/integrators/vault-message.md) for every field.

## Troubleshooting

- `config file not found`: set `CONFIG`, or create `config/multibridge/tenderly.json` from the example.
- `missing required env var ...`: the named variable is empty or unset in `e2e/multibridge/.env`.
- `unknown SCENARIO`: set `SCENARIO` to a key under `scenarios` in the config.
- `recover` can't find the message: set `FROM_BLOCK` to a block shortly before the transfer; public RPCs reject
  log searches from the earliest block.
- Set `E2E_DEBUG=1` for full stack traces.
