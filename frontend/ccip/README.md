# CCIP adapter frontend (reference implementation)

> **Reference implementation only.** This app shows one way to build a frontend for the
> CCIP `CrossChainERC4626Adapter`. It has **not been audited**, is **not intended for
> production use**, and may omit checks, validation, or error handling. Use it as a starting
> point and reference, and review it yourself before relying on it. See the repository
> [`DISCLAIMER`](../../DISCLAIMER).

A static single-page dashboard for `CrossChainERC4626Adapter` deployments. You paste an adapter
address and pick the network it is deployed on (the hub). The app reads the adapter's on-chain
state and lets you send CCIP deposit and redeem messages to it from an EVM (Ethereum Virtual Machine) or Solana source chain,
track them, and recover failed messages.

It talks directly to chain RPCs and to the public CCIP API (`https://api.ccip.chain.link`). There is
no backend.

Built with Vite, React, Reown AppKit (ethers adapter) for EVM wallets, `@solana/wallet-adapter`
for Solana wallets, `viem`, and `@chainlink/ccip-sdk`.

## Supported contracts

| Contract | Accepted `typeAndVersion()` |
| --- | --- |
| `CrossChainERC4626Adapter` (`src/ccip/`) | `CrossChainERC4626Adapter <x.y.z>` (currently `CrossChainERC4626Adapter 1.0.0`) |

Any other value, including the factory (`CrossChainERC4626AdapterFactory 1.0.0`), is rejected when
loading. The ABI the app uses lives in [`client/src/lib/adapter/abi.ts`](client/src/lib/adapter/abi.ts)
and mirrors [`src/ccip/CrossChainERC4626Adapter.sol`](../../src/ccip/CrossChainERC4626Adapter.sol).

## Prerequisites

- Node.js 20.11 or later (CI uses 24) and pnpm 10 (the repo pins `pnpm@10.11.1` via `packageManager`)
- An EVM wallet (for example MetaMask or any WalletConnect wallet) for EVM source chains and for
  recovery transactions on the hub
- Optionally a Solana wallet (Phantom, Solflare, or Backpack) to send from Solana
- A Reown (WalletConnect) Cloud project ID from <https://cloud.reown.com> to enable EVM wallet
  connection

## Setup

Install from the **repository root** (this app is a pnpm workspace package):

```bash
pnpm install
```

Then create the app's environment file:

```bash
cp frontend/ccip/.env.example frontend/ccip/.env
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
pnpm --filter ./frontend/ccip dev        # dev server (http://localhost:5173)
pnpm --filter ./frontend/ccip build      # static build into frontend/ccip/dist
pnpm --filter ./frontend/ccip preview    # serve the build (http://localhost:4173)
pnpm --filter ./frontend/ccip typecheck  # tsc --noEmit
```

## Using the app

The app uses hash routing, so page URLs look like `/#/` and `/#/monitor`.

### Vault Dashboard (`/#/`)

1. Paste an adapter address, choose the hub network, and click **Load adapter**. A known Ethereum
   Sepolia deployment is offered as a preset; add your own in
   [`client/src/config/adapters.config.ts`](client/src/config/adapters.config.ts).
2. The app verifies `typeAndVersion()`, then reads scalars and roles and scans the adapter's event
   logs (up to 4,000,000 blocks back, in chunks, cached per adapter in `localStorage`) to discover
   vaults, source chains, fees, and failed messages. The first load of a busy adapter on a public RPC
   can take a while.

The header shows the adapter identity, router, and the deposit and redeem killswitches. The tabs are:

- **Vaults**: every ERC-4626 vault enabled on the adapter (from `TargetEnabled` events), with share
  and underlying metadata, totals, and exchange rate. **Deposit** and **Redeem** open the send form:
  pick an EVM or Solana source chain, the amount, the beneficiary, the return mode (deliver on the hub
  or return to the source chain), an optional `localRefundAddress`, and slippage. The form calls the
  adapter's `preview()`, derives `minimumOut`, estimates destination gas, quotes the CCIP fee, runs a
  validation checklist, and then sends the CCIP programmable token transfer from the connected wallet.
- **Messages**: messages sent from this browser, with their CCIP lifecycle status from the CCIP API
  and links to the CCIP Explorer.
- **Failed**: messages the adapter captured as failed. Anyone can call `refundFailedMessage` (the
  connected wallet pays the CCIP fee: the estimate plus 20%, with any excess returned) to bounce tokens back to the source chain. The message's
  `localRefundAddress` can instead call `recoverFailedMessageLocally` on the hub.
- **Activity**: a feed of the adapter's events.
- **Config**: configured source chains, return-leg asset fees, collected fees, per-source CCV (CCIP v2 Cross-Chain Verifier) and
  finality configuration, and role holders.

### Message Monitor (`/#/monitor`)

Searches the public CCIP API for messages by sender or receiver address and shows their status, with
links to the CCIP Explorer.

## Deploying the static build

`pnpm --filter ./frontend/ccip build` writes a
self-contained static site to `frontend/ccip/dist`. Host it on any static file host. Because
routing is hash based, no server-side rewrite rules are needed.

Set `BASE_PATH` at build time when the site is served from a sub-path. For a GitHub Pages project
site at `https://<org>.github.io/<repo>/`:

```bash
BASE_PATH=/<repo>/ pnpm --filter ./frontend/ccip build
```

Then publish the contents of `frontend/ccip/dist` (for example with the
`actions/upload-pages-artifact` and `actions/deploy-pages` GitHub Actions). Provide the `VITE_*`
variables to the build environment (for example as repository variables), since they are baked in at
build time.

## Project layout

```text
frontend/ccip/
├── client/
│   ├── index.html
│   ├── public/                 # favicons
│   └── src/
│       ├── pages/              # vault-dashboard.tsx (/), receiver-monitor.tsx (/monitor)
│       ├── components/vault/   # dashboard sections, send dialog, failed-message recovery
│       ├── components/ui/      # shadcn/ui primitives
│       ├── config/             # networks (ccip.config.ts, web3.config.ts, solana.config.ts), presets
│       ├── context/            # EVM (Reown AppKit) and Solana wallet providers
│       └── lib/adapter/        # ABI, state reader, payload encoding, send, recovery, status
├── .env.example
├── vite.config.ts
└── package.json
```

## Related

- Contracts and design: [`docs/ccip/README.md`](../../docs/ccip/README.md)
- Frontend integration guide (how to build your own frontend):
  [`docs/ccip/cross-chain-erc4626-adapter-frontend-integration-guide.md`](../../docs/ccip/cross-chain-erc4626-adapter-frontend-integration-guide.md)
- User journey:
  [`docs/ccip/cross-chain-erc4626-adapter-user-journey.md`](../../docs/ccip/cross-chain-erc4626-adapter-user-journey.md)
- Contract reference:
  [`docs/ccip/cross-chain-erc4626-adapter-contract-reference.md`](../../docs/ccip/cross-chain-erc4626-adapter-contract-reference.md)
- Live-network E2E harness: [`e2e/ccip/`](../../e2e/ccip/README.md)
- The multibridge adapter frontend: [`frontend/multibridge/`](../multibridge/README.md)

## License

MIT, see the repository [`LICENSE`](../../LICENSE).
