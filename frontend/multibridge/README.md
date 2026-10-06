# Multibridge adapter frontend (reference implementation)

> **Reference implementation only.** This app shows one way to build a frontend for the multibridge
> vault adapter. It has **not been audited**, is **not intended for production use**,
> and may omit checks, validation, or error handling. Use it as a starting point and reference, and
> review it yourself before relying on it. See the repository [`DISCLAIMER`](../../DISCLAIMER).

A static single-page dashboard for the synchronous ERC-4626 adapter, `CrossChainVaultAdapter`, built on
`MultiChannelBridgeAdapter` + `RouteRegistry`. You paste an adapter address and pick the network it
is deployed on (the hub). The app reads the adapter's on-chain state and lets you send deposit and
redeem messages to it over CCIP (Chainlink Cross-Chain Interoperability Protocol, from EVM or Solana),
LayerZero OFT (Omnichain Fungible Token), or Stargate, track them, and recover failed messages.
Deploy the adapter first; see [`docs/multibridge/README.md`](../../docs/multibridge/README.md#deploy).

It talks directly to chain RPCs, the public CCIP API (`https://api.ccip.chain.link`), and the
LayerZero Scan testnet API. There is no backend.

Built with Vite, React, Reown AppKit (ethers adapter) for EVM wallets, `@solana/wallet-adapter`
for Solana wallets, `viem`, `@chainlink/ccip-sdk`, and `@layerzerolabs/lz-v2-utilities`.

## Supported contracts

| Contract | Accepted `typeAndVersion()` | Notes |
| --- | --- | --- |
| `CrossChainVaultAdapter` (`src/multibridge/examples/`) | `CrossChainVaultAdapter <x.y.z>` (currently `CrossChainVaultAdapter 1.0.0`) | ERC-4626, CCIP v1 lanes plus LayerZero OFT and Stargate |

Any other value is rejected when loading, including the factory
(`CrossChainVaultAdapterFactory 1.0.0`), the abstract base, and other adapter kinds. The ABI the app
uses lives in [`client/src/lib/adapter/abi.ts`](client/src/lib/adapter/abi.ts) and mirrors
[`src/multibridge/`](../../src/multibridge/) (`MultiChannelBridgeAdapter.sol`, `routing/RouteRegistry.sol`,
and `examples/CrossChainVaultAdapter.sol`).

## Prerequisites

- Node.js 20.11 or later (CI uses 24) and pnpm 10 (the repo pins `pnpm@10.11.1` via `packageManager`)
- An EVM wallet (for example MetaMask or any WalletConnect wallet) for EVM source chains and for
  recovery transactions on the hub
- Optionally a Solana wallet (Phantom, Solflare, or Backpack) to send over CCIP from Solana
- A Reown (WalletConnect) Cloud project ID from <https://cloud.reown.com> to enable EVM wallet
  connection

## Setup

Install from the **repository root** (this app is a pnpm workspace package):

```bash
pnpm install
```

Then create the app's environment file:

```bash
cd frontend/multibridge
cp .env.example .env
```

| Variable | Required | Purpose |
| --- | --- | --- |
| `VITE_REOWN_PROJECT_ID` | Yes, for EVM wallets | Reown (WalletConnect) Cloud project ID. Without it the app still loads and reads state, but the EVM wallet button is disabled. |
| `VITE_SOLANA_DEVNET_RPC` | No | Solana devnet RPC URL. Defaults to the public devnet endpoint. |
| `VITE_SOLANA_MAINNET_RPC` | No | Solana mainnet-beta RPC URL. Defaults to the public mainnet endpoint. |
| `VITE_RPC_<chainId>` | No | EVM RPC override for one chain, for example `VITE_RPC_11155111` for Ethereum Sepolia. Honored for chain ids 1, 10, 56, 137, 8453, 42161, 43114, 11155111, 421614, 84532, 11155420, 43113, 80002, and 97. Other chains use the public RPC listed in [`client/src/config/ccip.config.ts`](client/src/config/ccip.config.ts). |

Every `VITE_*` value is embedded in the built JavaScript and is visible to anyone who loads the
page. Do not put secrets in `.env`. Public RPCs are rate limited; for anything beyond light testing,
set a dedicated RPC URL for the hub chain.

## Scripts

Run from the repository root:

```bash
pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge dev        # dev server (http://localhost:5173)
pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge build      # static build into frontend/multibridge/dist
pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge preview    # serve the build (http://localhost:4173)
pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge typecheck  # tsc --noEmit
```

## Using the app

The app uses hash routing, so page URLs look like `/#/` and `/#/monitor`.

### Vault Dashboard (`/#/`)

1. Paste an adapter address, choose the hub network, and click **Load adapter**.
2. The app verifies `typeAndVersion()`, then reads scalars and roles and scans the adapter's event
   logs (up to 4,000,000 blocks back, in chunks, cached per adapter in `localStorage`) to discover
   allowlists, routes, fees, and failed messages. The first load on a public RPC can take a few
   minutes.

The header shows the hub network, CCIP router, LayerZero endpoint, your roles on the adapter, and
whether LayerZero return legs must be prefunded. The tabs are:

- **Vaults**: the adapter's fixed ERC-4626 vault with share and underlying metadata, totals, and
  exchange rate. **Deposit asset** and **Redeem shares** open the send form: pick a source chain and
  rail (CCIP, LayerZero OFT, or Stargate), the amount, a return destination, the beneficiary, and
  slippage. Optional settings are the return-leg prefund, a `failedMessageHandler` (the hub address
  allowed to retry or refund locally if the message fails), and **Local refund only**
  (`onlyLocalRefund`, which disables the permissionless bounce-to-source when a handler is set). The
  form previews the vault output, derives `minAmountOut`, checks the inbound allowlist, quotes the
  fee, and sends from the connected wallet. The app message is the `VaultMessage` struct
  (`minAmountOut`, `destination`, `recipient`, `failedMessageHandler`, `onlyLocalRefund`), encoded in
  [`client/src/lib/adapter/message.ts`](client/src/lib/adapter/message.ts).
- **Messages**: messages sent from this browser, with the transport status (CCIP API or LayerZero
  Scan) and the application outcome on the hub (`isFailed` / `isRefunded`). A delivered transport
  message can still have failed in the app, so both are shown.
- **Failed**: messages the adapter captured as failed. The adapter stores only a hash of each failed
  `Inbound`, so the app rebuilds the full `Inbound` from the `MessageFailed` event and passes it to
  the recovery call. **Bounce to source** (`refundToSource`) is permissionless unless the message set
  `onlyLocalRefund` with a handler. **Retry** (`retryFailedMessage`) and **Refund local**
  (`refundLocal`) are restricted to the message's `failedMessageHandler`.
- **Activity**: a feed of the adapter's events.
- **Config**: inbound sources, outbound destinations, Solana (SVM) CCIP lanes, outbound routes
  (produced token to destination), OFT-per-token mappings, destination gas, inbound fees, collected
  fees, and role holders.

### Where send-form options come from

Some inputs to the send form cannot be read from the hub adapter, such as the OFT adapter or
Stargate pool on the source chain. They come from an optional registry in
[`client/src/config/adapters.config.ts`](client/src/config/adapters.config.ts) (the file documents
the entry shape). Without an entry for the loaded adapter:

- source chains are the adapter's allowlisted CCIP sources, with the CCIP rail only;
- return destinations are the adapter's enabled on-chain routes for the token the action produces.

Add an entry to offer LayerZero OFT and Stargate sources or a curated list of return destinations.
The addresses used by the E2E harness are in [`config/multibridge/sepolia.json`](../../config/multibridge/sepolia.json).

### Message Monitor (`/#/monitor`)

Searches the public CCIP API for CCIP messages by sender or receiver address and shows their status,
with links to the CCIP Explorer.

## Limitations

- LayerZero OFT and Stargate status tracking uses the LayerZero Scan **testnet** API and explorer
  links.

## Deploying the static build

`pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge build` writes a self-contained
static site to `frontend/multibridge/dist`. Host it on any static file host. Because routing is hash
based, no server-side rewrite rules are needed.

Set `BASE_PATH` at build time when the site is served from a sub-path. For a GitHub Pages project
site at `https://<org>.github.io/<repo>/`:

```bash
BASE_PATH=/<repo>/ pnpm --filter @chainlink/cross-chain-vault-adapters-frontend-multibridge build
```

Then publish the contents of `frontend/multibridge/dist` (for example with the
`actions/upload-pages-artifact` and `actions/deploy-pages` GitHub Actions). Provide the `VITE_*`
variables to the build environment (for example as repository variables), since they are baked in at
build time.

## Project layout

```text
frontend/multibridge/
├── client/
│   ├── index.html
│   ├── public/                 # favicons
│   └── src/
│       ├── pages/              # vault-dashboard.tsx (/), receiver-monitor.tsx (/monitor)
│       ├── components/vault/   # dashboard sections, send dialog, failed-message recovery
│       ├── components/ui/      # shadcn/ui primitives
│       ├── config/             # networks (ccip, LayerZero, Solana, AppKit), adapter registry
│       ├── context/            # EVM (Reown AppKit) and Solana wallet providers
│       └── lib/adapter/        # ABI, state reader, VaultMessage encoding, send, recovery, status
├── .env.example
├── vite.config.ts
└── package.json
```

## Related

- Contracts and design: [`docs/multibridge/README.md`](../../docs/multibridge/README.md)
- Failed-message handling:
  [`docs/multibridge/informational/FAILED_MESSAGE_RESOLUTION.md`](../../docs/multibridge/informational/FAILED_MESSAGE_RESOLUTION.md)
- Live-network E2E harness: [`e2e/multibridge/`](../../e2e/multibridge/)
- The CCIP adapter frontend: [`frontend/ccip/`](../ccip/)

## License

MIT, see the repository [`LICENSE`](../../LICENSE).
