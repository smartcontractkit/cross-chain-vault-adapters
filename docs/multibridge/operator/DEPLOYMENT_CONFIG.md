# Production deployment config and address book

Define a **home chain** (where the ERC-4626 vault lives), the **vault**, and a list of **supported
network → token → rail** routes. [`DeployProduction`](../../../script/multibridge/DeployProduction.s.sol)
resolves every CCIP selector, LayerZero EID (endpoint ID), router, endpoint, and Stargate pool from the
[`Networks`](../../../script/multibridge/config/Networks.sol) address book, so you never paste raw interop
addresses. Dry-run it on a Tenderly Virtual TestNet mainnet fork before a mainnet broadcast.

> **Verify before mainnet.** The address book was compiled from official sources (Chainlink
> `chain-selectors` + CCIP directory, LayerZero metadata, Stargate V2 docs, USDT0 docs). Addresses change
> and docs go stale — reconfirm every value you actually use against the official directory for that chain
> before broadcasting real funds. Entries marked `VERIFY` in `Networks.sol` are lower-confidence.

---

## 1. Files

| File | Role |
|---|---|
| [`script/multibridge/config/Networks.sol`](../../../script/multibridge/config/Networks.sol) | **Address book** — CCIP selectors/routers, LZ EIDs/endpoint, Stargate pools, USDT0 OFTs, native USDT/USDC, keyed by chain. Authoritative for scripts. |
| [`config/multibridge/deployment.example.json`](../../../config/multibridge/deployment.example.json) | **Deployment config schema** — copy to `config/multibridge/deployment.json` and fill in. |
| [`script/multibridge/DeployProduction.s.sol`](../../../script/multibridge/DeployProduction.s.sol) | Resolver + deploy: clones via the factory (deployer = temp admin), installs the route registry, hands off via `transferAdmin` to the real admin. |
| `test/multibridge/script/DeployProductionResolve.t.sol` | Unit-tests the config→plan resolution (no broadcast). |

## 2. The address book (mainnet)

CCIP chain selectors and LZ EIDs are stable; **routers, endpoints, and pools must be reconfirmed**. LZ
EndpointV2 is `0x1a44076050125825900e736c501f859c50fE728c` on every EVM chain below.

| Chain | key | CCIP selector | LZ EID | CCIP router | Stargate USDT pool | Stargate USDC pool | USDT0 OFT |
|---|---|---|---|---|---|---|---|
| Ethereum | `ethereum` | 5009297550715157269 | 30101 | 0x80226fc0…46f7D | 0x933597…3973 | 0xc02639…89C7 | 0x6C96dE32…1dee |
| Arbitrum | `arbitrum` | 4949039107694359620 | 30110 | 0x141fa0…DdE8 | 0xcE8CcA…bB7D0 | 0xe8CDF2…d0d3 | 0x14E4A1…8D92 |
| Optimism | `optimism` | 3734403246176062136 | 30111 | 0x320669…Ce0f (VERIFY) | 0x19cFCE…07dD | _not set (VERIFY)_ | 0xF03b4d…A0aD |
| Base | `base` | 15971525489660198786 | 30184 | 0x881e3A…58bCD (VERIFY) | _(none)_ | 0x27a16d…5d26 | _(none)_ |
| Polygon | `polygon` | 4051577828743386545 | 30109 | 0x849c5E…5Bfe (VERIFY) | 0xd47b03…d4d7 | 0x9Aa02D…7fe4 | 0x6BA103…9e13 |
| Avalanche | `avalanche` | 6433500567565415381 | 30106 | 0xF4c7E6…805dB (VERIFY) | 0x12dC92…2CeE | 0x5634c4…6e47 | _(none)_ |
| BNB | `bnb` | 11344663589394136015 | 30102 | 0x34B03C…59FE (VERIFY) | 0x138EB3…ebc63 | 0x962Bd4…6057 | _(none)_ |
| Solana | `solana` | 124615329519749607 | 30168 | _destination only (SVM)_ | _(none)_ | _(none)_ | _(none)_ |

(VERIFY) marks values flagged `VERIFY` in `Networks.sol`: not yet cross-checked against the live CCIP
directory. Solana is a destination only (it cannot be the home chain), so its EVM address fields are
zero. Native USDT/USDC token addresses are also
in `Networks.sol`. **Base has no canonical USDT**; **BNB USDT is 18-decimal**.

## 3. Deployment config

```jsonc
{
  "home": {
    "network": "ethereum",                 // a key in the address book
    "owner":   "0x…",                      // final admin (multisig); receives DEFAULT_ADMIN_ROLE + FEE_SETTER_ROLE
    "feeCollector": "0x…",                 // optional FEE_COLLECTOR_ROLE holder; zero => owner
    "vault":   "0x…",                      // the ERC-4626 vault on the home chain
    "asset":   "0xdAC17…",                 // vault underlying
    "assetSymbol": "USDT",                 // selects the Stargate pool (USDT|USDC)
    "assetOft":  "0x6C96dE32…",            // home-local LZ OFT for the asset (USDT0 adapter); LZ_OFT routes + inbound bounce
    "share":     "0x…vault",               // share token (== vault for ERC-4626)
    "shareOft":  "0x0",                    // home-local LZ OFT for the share (if you bridge shares over LZ)
    "fundWei":   500000000000000000,       // native prefunding for outbound fees
    "defaultSvmComputeUnits": 0,           // CCIP_SVM compute budget; must be 0 (setCcipSvmConfig rejects others)
    "factory": "0x0", "implementation": "0x0" // optional: reuse existing
  },

  "routes": [                              // one entry per (network, token, rail). NO extra keys per object.
    { "network": "arbitrum",  "token": "asset", "rail": "LZ_OFT"   },
    { "network": "bnb",       "token": "asset", "rail": "STARGATE" },
    { "network": "solana",    "token": "asset", "rail": "LZ_OFT"   },
    { "network": "optimism",  "token": "share", "rail": "CCIP"     },
    { "network": "solana",    "token": "share", "rail": "CCIP_SVM" }
  ],

  "inbound": {                             // allowlist deposits/redeems originating from spokes
    "lzSrcEids":  [30110, 30168],          // (srcEid, home-local OFT that delivers via lzCompose)
    "lzSrcOfts":  ["0x6C96dE32…", "0x6C96dE32…"],
    "ccipSrcSelectors": [3734403246176062136]
  },

  "returnLegFees": {                       // installed by factory.deploy
    "requireLzReturnPrefunded": true,      // LZ/Stargate spokes: users must attach compose value
    "inboundFees": [                       // CCIP spokes: flat skim before vault action
      { "outboundToken": "share", "destination": 3734403246176062136, "fee": 5000000 }
    ]
  }
}
```

See [`RETURN_LEG_HANDLING.md`](../informational/RETURN_LEG_HANDLING.md) for how to size fees.

**`token`** is `"asset"` (USDT out on redeem) or `"share"` (vault token out on deposit). **`rail`**:

| Rail | Use | `endpoint` resolved to | `dstId` |
|---|---|---|---|
| `LZ_OFT` | USDT0 / any OFT (incl. **Solana**) | `assetOft` / `shareOft` | dest LZ EID |
| `STARGATE` | pooled stable, **asset only** (incl. Solana) | home Stargate pool for `assetSymbol` | dest LZ EID |
| `CCIP` | EVM, token has a CCIP pool | _(none)_ | dest CCIP selector |
| `CCIP_SVM` | **Solana** over CCIP | _(none)_ | Solana CCIP selector + SVM lane config |
| `LOCAL` | **same chain** — ERC-20 sent straight to the recipient, no bridge, no fee | _(none)_ | `0` (the `LOCAL_DESTINATION` sentinel; `network` ignored) |

> **LOCAL delivery.** If the user routes to `destination = 0` and a `Rail.LOCAL` route is registered for
> the produced token, the app transfers the token directly to the recipient on the home chain instead
> of bridging: fee 0, no return leg (a LayerZero compose's prepaid value is returned to the message's
> `failedMessageHandler`, or kept in the reserve when there is none). The recipient must be an EVM
> address (a 32-byte non-EVM recipient is rejected and captured for recovery).

> Each `routes[]` object must contain **only** `network`/`token`/`rail`, including `LOCAL` entries. `vm.parseJson` decodes the
> array positionally by alphabetical key, so any extra key (e.g. a comment) shifts the decode. Slippage
> is not configured here — it is the user's per-transaction `minAmountOut`.

## 4. Deploy (Tenderly or mainnet)

Run from the repository root:

```bash
cp config/multibridge/deployment.example.json config/multibridge/deployment.json   # fill in
pnpm multibridge:deploy --rpc-url "$HOME_RPC_URL" --account <KEYSTORE> --broadcast --slow
```

`pnpm multibridge:deploy` runs `script/multibridge/DeployProduction.s.sol:DeployProduction` with
`FOUNDRY_PROFILE=deploy` (the deploy compiler settings); extra arguments pass through to `forge script`.
Environment overrides: `CONFIG` (config path, default `config/multibridge/deployment.json`) and
`DEPLOYER` (the broadcasting address, default `msg.sender`; it must be the address that signs, because it
becomes the temporary admin).

One broadcast: clone the official implementation via the factory (deployer = temporary admin) → install
the route registry (routes + Stargate/SVM/outbound allowlists) → `transferAdmin` (admin + fee roles) to `home.owner` when the
deployer differs from `home.owner`. Addresses are written to `deployments/multibridge/<chainId>.json`.

**Implementation + factory reuse.** With `home.factory` set, the script clones from that factory's bound
implementation. Otherwise it deploys a new `CrossChainVaultAdapterFactory` bound to `home.implementation`,
publishing a fresh `CrossChainVaultAdapter` first when `home.implementation` is also zero.

For multi-chain Tenderly E2E (originate a deposit on a spoke fork and settle it on the hub fork), use the
single-scenario harness in [`TENDERLY_E2E.md`](../development/TENDERLY_E2E.md)
(`script/multibridge/tenderly/`); this production config is the hub-side, all-routes superset.

## 5. Notes & limits

- **Native USDT is never a CCIP token** — use `LZ_OFT` (USDT0) or `STARGATE`. `CCIP`/`CCIP_SVM` are for
  the share token (deploy a CCT, CCIP Cross-Chain Token, pool for it) or USDC.
- **Stargate carries the asset only** (`STARGATE` + `token:"share"` reverts). Its roster is USDC/USDT/ETH.
- **Solana**: `LZ_OFT`/`STARGATE` carry the 32-byte recipient as-is; `CCIP_SVM` uses the SVM encoding
  (see [`SOLANA.md`](../informational/SOLANA.md)). Solana SPL/program addresses are base58 — supply them per deployment.
- The resolver is unit-tested; the **on-chain values are not**. Dry-run on a Tenderly fork and verify
  the address book before mainnet. Sources: [chain-selectors](https://github.com/smartcontractkit/chain-selectors),
  [CCIP directory](https://docs.chain.link/ccip/directory/mainnet),
  [LayerZero](https://docs.layerzero.network), [Stargate](https://stargateprotocol.gitbook.io/stargate),
  [USDT0](https://docs.usdt0.to).
