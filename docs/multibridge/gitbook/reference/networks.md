# Networks and rails

Supported tokens are the vault's asset (USDT or USDC) and its share token. EID is the LayerZero endpoint ID, OFT is LayerZero's Omnichain Fungible Token standard, and CCT is the CCIP Cross-Chain Token standard. The matrix shows how each moves to and from a network and over which rail. Each entry assumes the token-level prerequisite exists: a Chainlink-supported USDC pool on the CCIP lane, a CCT pool the issuer deploys for the share token, USDT0 OFT peers for USDT over LayerZero, and Stargate pools per lane.

| Network | LZ EID / CCIP selector | USDT | USDC | Share token | Same-chain |
|---|---|---|---|---|---|
| Ethereum | 30101 / 5009297550715157269 | USDT0 (`LZ_OFT`), Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Arbitrum | 30110 / 4949039107694359620 | USDT0, Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Optimism | 30111 / 3734403246176062136 | USDT0, Stargate | CCIP, Stargate (verify) | CCIP | `LOCAL` |
| Polygon | 30109 / 4051577828743386545 | USDT0, Stargate | Stargate, CCIP | CCIP | `LOCAL` |
| Base | 30184 / 15971525489660198786 | None (no supported rail) | Stargate, CCIP | CCIP | `LOCAL` |
| Avalanche | 30106 / 6433500567565415381 | Stargate (no USDT0) | Stargate, CCIP | CCIP | `LOCAL` |
| BNB | 30102 / 11344663589394136015 | Stargate (no USDT0; 18 decimals) | Stargate, CCIP | CCIP | `LOCAL` |
| Solana | 30168 / 124615329519749607 | USDT0 (`LZ_OFT`), Stargate | Stargate, `CCIP_SVM` | `CCIP_SVM` | N/A |

## Rules

- Native USDT is never a CCIP token. It moves over USDT0 (`LZ_OFT`) or Stargate only.
- Base has no supported USDT rail. The third-party bridged "USDT" on Base is not Tether-issued, has no USDT0 OFT and no Stargate pool, and USDT is never CCIP. Treat Base USDT as unsupported unless the issuer provisions a dedicated rail for that specific token.
- USDC moves over CCIP and `CCIP_SVM` on Chainlink-supported USDC pools, with no issuer deployment, or over Stargate. Confirm each lane in the CCIP directory.
- The share token moves over CCIP and `CCIP_SVM` via a CCT pool the issuer deploys per lane. Until a lane's pool exists, that lane does not carry shares.
- `LOCAL` delivers any token on the hub chain by direct transfer.
- Solana recipients must be wallet addresses (token-account owners), never associated token accounts (ATAs). An ATA in the recipient field locks the tokens permanently.

## Verification

Selectors and EIDs come from `script/multibridge/config/Networks.sol` in the repository. Some entries are flagged `VERIFY`. Reconfirm every router, pool, and selector against the official Chainlink CCIP, LayerZero, and Stargate directories before mainnet use.
