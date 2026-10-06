# Security policy

## Reporting a vulnerability

Report vulnerabilities through [chain.link/security](https://chain.link/security) or by email to
security@chainlink.io. Do not open a public GitHub issue, pull request, or discussion for a security report.

Include the affected contract or file, the impact, and the steps or a proof of concept to reproduce it.

## Scope

The contracts are in [`src/`](src/):

- `src/ccip/`: `CrossChainERC4626Adapter` and `CrossChainERC4626AdapterFactory`
- `src/multibridge/`: `MultiChannelBridgeAdapter`, `RouteRegistry`, `CrossChainVaultAdapter`,
  `CrossChainVaultAdapterFactory`, and their base contracts

The deploy scripts, E2E harnesses (`e2e/`), and reference frontends (`frontend/`) are examples. They have not been
audited and are not intended for production use as-is.

This code is outside the scope of any Chainlink bug bounty programs. See the [`DISCLAIMER`](DISCLAIMER).
