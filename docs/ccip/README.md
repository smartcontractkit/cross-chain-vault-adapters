# CCIP implementation: CrossChainERC4626Adapter

## Disclaimer

Please note, this repo contains community examples only - these are not Chainlink products or services and are not supported or maintained by Chainlink. This code represents an example of using a Chainlink product or service, and is intended for demonstration and educational purposes only. It is provided “AS IS” and “AS AVAILABLE” without warranties of any kind, may not have been audited, and may omit checks or error handling. Each party intending to use this example code does so entirely at their own risk and must perform its own audits, security and code review, key management, and testing before any production deployment and ensure the operation and performance of such code matches expectations. Neither Chainlink Labs nor the Chainlink Foundation deploys, operates, monitors, maintains or endorses any deployment of this code. Note that this is not a Chainlink product, feature or service, and there are no commitments made with respect to the code, including compatibility with future Chainlink releases. You should not rely on this code without first conducting your own technical, engineering, and security review. This code is also outside the scope of any Chainlink bug bounty programs. Neither Chainlink Labs, the Chainlink Foundation, nor Chainlink node operators are responsible for outcomes due to errors in this example or how it is deployed or operated, or liable for any resulting claims or damages. Use of the Chainlink Network is subject to the Chainlink Foundation Terms of Service, which provides important information and disclosures. By using this code, you acknowledge and agree to these terms.

## Overview

Use this implementation when both the vault's deposit asset and its share token are CCIP-enabled on the chains you
serve. If either moves over LayerZero OFT or Stargate, use the [multibridge implementation](../multibridge/README.md)
instead. See [Choosing an implementation](../../README.md#choosing-an-implementation).

`CrossChainERC4626Adapter` is a standalone Chainlink CCIP (Cross-Chain Interoperability Protocol) adapter that
enables cross-chain deposits into and redemptions from ERC-4626 vaults. It is deployed on the chain where the vault
lives and receives CCIP token transfers from EVM (Ethereum Virtual Machine) and SVM (Solana Virtual Machine) source
chains.

The contract is designed to be used in two ways:

- deploy it as-is when you want a direct, minimal ERC-4626 adapter with defensive CCIP handling
- clone it and modify the message processing logic when you need custom vault behavior, custom payload rules, or custom post-processing

The architecture is intentionally simple, flat, and direct:

- the adapter is contained in one primary contract file
- inheritance is kept to the minimum needed for CCIP reception, roles, and reentrancy protection
- inbound processing, failed-message storage, and outbound returns are all explicit in the same contract
- the default ERC-4626 logic is easy to inspect and replace

`CrossChainERC4626AdapterFactory` deploys and configures an adapter in one transaction and hands the roles to the
configured accounts.

## Purpose

The adapter accepts a CCIP token transfer, decodes a small payload, and then decides whether to:

- deposit the inbound asset into an ERC-4626 vault and produce vault shares
- redeem inbound vault shares into the underlying asset
- deliver the resulting token locally on the destination chain
- or bridge the resulting token back to the source chain

This makes it possible to treat an ERC-4626 vault as a cross-chain endpoint without needing a large inheritance tree or a deeply abstract architecture.

## User journey summary

1. A source-side app or user sends a CCIP message carrying exactly one token and a 128-byte payload:
   `abi.encode(address target, bytes32 beneficiary, uint256 minimumOut, uint256 deliveryAndRefund)`. The same
   payload is used for EVM and SVM sources. `deliveryAndRefund` packs `returnToSourceChain` (bit 0) and an optional
   `localRefundAddress` on the destination chain (bits 1..160; `address(0)` disables local recovery).
2. The CCIP router calls `ccipReceive()` on the adapter. The adapter checks only that the caller is its router, then
   runs `processMessage()` in an external self-call wrapped in `try`/`catch`.
3. `processMessage()` checks that the source chain selector is configured, the payload is valid, and the vault
   `target` is enabled.
4. If the inbound token is the vault asset, the adapter deposits; if it is the vault share token, it redeems.
5. The output is delivered locally to `beneficiary`, or bridged back to `beneficiary` on the source chain. Return
   legs may be charged a flat adapter fee and use `extraArgs` configured by the admin, never taken from the payload.
6. If anything in `processMessage()` reverts, the adapter stores the message as failed and emits `MessageFailed`.
   CCIP still reports the message as `SUCCESS`. Anyone can then refund the tokens to the original sender on the
   source chain, or the `localRefundAddress` can recover them on the destination chain.

The full flow is in the [user journey](cross-chain-erc4626-adapter-user-journey.md).

## Deploy, configure, and verify

The recommended flow uses the Foundry scripts in `script/ccip/`, driven by the root `.env` file (see
[`.env.example`](../../.env.example)). `--rpc-url ccip` resolves to `RPC_URL` from that file.

```bash
cp .env.example .env                                  # fill in ROUTER, roles, VAULT_TARGET, CHAIN_SELECTORS, ...
pnpm ccip:deploy --rpc-url ccip                       # dry run
pnpm ccip:deploy --rpc-url ccip --account deployer --broadcast
pnpm ccip:configure --rpc-url ccip --account admin --broadcast   # CCIP v2 lane settings and native funding
pnpm ccip:check --rpc-url ccip                        # read-only report with warnings
```

`pnpm ccip:deploy` deploys a factory (or reuses `FACTORY`) and a configured adapter, and writes
`deployments/ccip/<chainId>.json`. The [deployment guide](cross-chain-erc4626-adapter-deployment-guide.md) covers
every option, deploying through an existing factory from a block explorer, and the adapter-only constructor deploy.

## CCIP v1 and CCIP v2 lanes

The adapter works on both CCIP v1 lanes and CCIP v2 lanes. Inbound messages need no lane-specific setup beyond
`setChainType`. The lane version matters in two places:

| Setting | CCIP v1 lane | CCIP v2 lane |
| --- | --- | --- |
| Return and refund `extraArgs` to that chain (`setEvmReturnLaneFormat`) | Leave unset or set `LEGACY_EXTRA_ARGS_V2` (`GenericExtraArgsV2`) | Set `GENERIC_EXTRA_ARGS_V3_BASIC` (`GenericExtraArgsV3`) |
| Requested finality per returned token (`setEvmReturnRequestedFinality`) | Not used | Optional; unset means wait for finality |
| Inbound finality and CCV (Cross-Chain Verifier) policy (`setInboundFinality`, `setCCVsConfig`) | Not used | Optional; read by CCIP through `getCCVsAndFinalityConfig` |

`pnpm ccip:configure` applies all of these from `.env`. The adapter does not detect the lane version: a wrong format
shows up as a `getFee` or `ccipSend` revert on the return leg. SVM return legs always use a fixed Solana
`extraArgs` layout. Details are in the
[operator guide](cross-chain-erc4626-adapter-operator-guide.md#ccip-stack-version-and-return-leg-extraargs-evm).

## Owner responsibilities

The admin (`DEFAULT_ADMIN_ROLE`) should:

- set valid source chain selectors with the correct chain family
- enable the intended ERC-4626 target vaults
- enable or disable deposit and redeem processing as needed
- configure return-leg `extraArgs` and finality for CCIP v2 lanes
- keep enough native gas token in the adapter to pay the outbound CCIP fees of return transfers (refunds are paid by the caller of `refundFailedMessage`)
- monitor failed messages and help users refund or recover them
- maintain the CCV and finality policy if the lanes rely on it

The fee operators should:

- set return-leg fee schedules through `FEE_SETTER_ROLE`, and revisit them as CCIP fee quotes and asset prices move
- withdraw collected fees through `FEE_COLLECTOR_ROLE`

## Live-network E2E tests

[`e2e/ccip/`](../../e2e/ccip/README.md) sends real CCIP deposits, redeems, and failure cases on public testnets to a
deployed adapter, then refunds or recovers the failed ones. Configure `e2e/ccip/.env`, then run
`pnpm e2e:ccip suite --list` to see the scenarios and `pnpm e2e:ccip suite --wait` to run them. The
[test catalog](../../e2e/ccip/TEST-CATALOG.md) lists every automated and manual check.

## Reference frontend

[`frontend/ccip/`](../../frontend/ccip/README.md) is an unaudited example dashboard: paste an adapter address to read
its state, send deposits and redeems from an EVM or Solana wallet, and refund or recover failed messages. Run it with
`pnpm --filter ./frontend/ccip dev`. To build your own, see the
[frontend integration guide](cross-chain-erc4626-adapter-frontend-integration-guide.md).

## Commands

Run everything from the repository root; see the [root README](../../README.md) for setup and the full CI gate list.

```bash
pnpm install
pnpm test:ccip                  # Foundry unit tests for this implementation
pnpm solhint:ccip               # lint src/ccip
pnpm e2e:ccip typecheck         # type-check the live-network E2E harness
pnpm e2e:ccip suite --list      # list live E2E scenarios
pnpm --filter ./frontend/ccip typecheck
```

The CCIP implementation compiles with its pinned settings (solc 0.8.24, `via_ir`,
`optimizer_runs = 1`, EVM version cancun), pinned in `foundry.toml` through `compilation_restrictions`, so no
profile flag is needed to deploy. The bytecode uses no Cancun-only opcode, so it runs on any chain with Shanghai
(`PUSH0`) support. `pnpm solhint:ccip` is ratcheted at the existing 17 warnings, because the contract sources
are frozen.

## Documentation map

| Document | Covers |
| --- | --- |
| [User journey](cross-chain-erc4626-adapter-user-journey.md) | Step-by-step message flow, success and failure paths |
| [Deployment guide](cross-chain-erc4626-adapter-deployment-guide.md) | Scripts, `.env` variables, factory deploy from a block explorer, adapter-only deploy |
| [Operator guide](cross-chain-erc4626-adapter-operator-guide.md) | Roles, configuration, CCIP v1 and v2 return-leg settings, monitoring, failed-message handling |
| [Contract reference](cross-chain-erc4626-adapter-contract-reference.md) | Constructor and factory arguments, every function, event, error, struct, enum, and constant |
| [Frontend integration guide](cross-chain-erc4626-adapter-frontend-integration-guide.md) | Reading adapter state, building payloads and CCIP sends, recovery flows from a UI |
| [E2E harness](../../e2e/ccip/README.md) and [test catalog](../../e2e/ccip/TEST-CATALOG.md) | Live-network testing |
| [Reference frontend](../../frontend/ccip/README.md) | Example dashboard |

## Useful paths

- adapter contract: `src/ccip/CrossChainERC4626Adapter.sol`
- factory contract: `src/ccip/CrossChainERC4626AdapterFactory.sol`
- deploy, configure, and check scripts: `script/ccip/`
- Foundry tests: `test/ccip/`
- deployment records: `deployments/ccip/`
- E2E harness: `e2e/ccip/`
- reference frontend: `frontend/ccip/`

## Notes

- CCIP contracts come from the `@chainlink/contracts-ccip@2.0.0` npm release; OpenZeppelin is imported through the versioned `@openzeppelin/contracts@4.8.3` and `@openzeppelin/contracts@5.0.2` aliases in `remappings.txt`.
- Build artifacts are written to `foundry-artifacts/` and the compiler cache to `foundry-cache/`.
- `CrossChainERC4626Adapter` is meant to stay readable and editable rather than highly abstract. Its handlers are not `virtual`: to change behavior, fork the contract and redeploy.
