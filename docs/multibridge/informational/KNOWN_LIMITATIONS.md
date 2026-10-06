# Known limitations

Accepted limitations and trust assumptions of the code, gathered for reviewers and operators. Validate
every lane you enable on a fork or testnet before using it with real funds.

## Trust & custody

- **No operator custody, and no operator rescue.** The admin can configure lanes/routes and withdraw the
  adapter's native balance (`recoverNative`); it can never touch user or failed **ERC-20** tokens. The
  trade-off: two edges are **permanently unrecoverable** rather than operator-recoverable — (a) tokens
  sent **directly** to the adapter outside any message, and (b) a malformed, handler-less transfer of a
  token that also blocks transfer back to the source sender.
- **Unrefunded LZ prepay becomes operator float.** A LayerZero compose `value` (prepaid return-leg funding)
  that goes unused is refunded to the message's `failedMessageHandler` as native ETH (best-effort). If the
  message sets no handler, or the native refund fails (the handler rejects ETH), the surplus is left in
  the adapter's native reserve and is therefore recoverable by the operator via `recoverNative` — i.e.
  unrefunded native prepay is treated as operator float by design. (Native only; there is no WETH path.)
- **Admin is trusted for configuration.** Allowlists, routes, OFT map, and gas are admin-set;
  run the admin behind a **multisig + timelock** for mainnet. Fee setters/collectors have a narrower
  surface (fee config and withdrawal only).
- **Emergency pause.** `pause()` / `unpause()` (admin) gate inbound processing: while paused,
  `processInbound` reverts, so inbound deliveries are captured as recoverable failed messages (fail-safe)
  rather than executing, and `retryFailedMessage` is blocked; `refundToSource` / `refundLocal` recovery
  still works so captured funds stay retrievable.

## Bridging / rails

- **Address book must be re-verified.** `script/multibridge/config/Networks.sol` is compiled from official sources but
  some values are flagged `VERIFY` (CCIP routers for OP/Base/Polygon/Avalanche/BNB, the OP Stargate-USDC
  pool). Reconfirm every value you use before mainnet. (See [`DEPLOYMENT_CONFIG.md`](../operator/DEPLOYMENT_CONFIG.md).)
- **Token-level prerequisites are yours.** CCIP token pools (CCT, the CCIP Cross-Chain Token standard)
  for CCIP-routed tokens, OFT (Omnichain Fungible Token) peers and DVNs (decentralized verifier networks)
  for LayerZero, and Stargate pools for the asset must exist on each lane (not provisioned by this repo).
- **Stargate is ERC-20-pool only** (a native-ETH pool fails `setRoute`'s `token()` check), and **native USDT is
  never a CCIP token** (use `LZ_OFT`/`STARGATE`).
- **Rebasing, inflationary, and fee-on-transfer tokens are UNSUPPORTED** — for both the vault asset and
  the share token. The adapters measure every produced amount by their own **balance delta** around the
  vault call (`_deposit`/`_redeem`; the ERC-4626 return values are deliberately not trusted), which
  assumes `balanceOf(adapter)` changes only because of the current action. The adapter can legitimately
  hold pre-existing balances of the produced token (accrued `s_collectedFees`, unrecoverable dust), so a
  token whose balances grow on their own (rebasing/inflationary) would have that growth mis-attributed
  to — and delivered with — the in-flight message, and a fee-on-transfer token breaks the 1:1 delivery
  assumptions of the rails. The underlying CCIP and LayerZero rails do not support such tokens either;
  operate the adapters only with standard, non-rebasing, full-amount-transfer ERC-20s.
- **Solana:** `tokenReceiver` must be the recipient's **wallet address** (the token-account owner) —
  **never an ATA** (associated token account): the offramp derives the ATA from the wallet automatically, and an ATA supplied here
  derives an off-curve owner, permanently locking the tokens. Only token-only transfers to wallets are
  supported: `setCcipSvmConfig` requires `computeUnits == 0`, so a Solana receiver *program* cannot be
  targeted. (See [`SOLANA.md`](./SOLANA.md).)
- **LayerZero shared-decimals dust** can be left in the adapter and is unrecoverable (no rescue).
- **CCIP sender length.** `ccipReceive` requires a 32-byte CCIP `sender` (EVM and Solana senders both
  are); any other length reverts at the entrypoint instead of being captured.
- **Slippage is the user's per-transaction `minAmountOut`, enforced END-TO-END on the DELIVERED amount**
  — a MEASURED recipient balance-delta check for LOCAL, a source-side check for CCIP/CCIP_SVM (valid
  only under the rails' 1:1 transfer assumption — the destination balance cannot be observed from the
  source chain, so route only standard 1:1 tokens over CCIP), and the bridge's `minAmountLD` for
  LZ_OFT/STARGATE. There is no operator-set per-route slippage parameter. A breach reverts and is captured
  for recoverable retry/refund (no silent loss).

## Deployment / ops

- **Cross-chain delivery is not automatic between forks.** Tenderly Virtual TestNets do not run the CCIP
  DON (decentralized oracle network) or LayerZero DVNs and executors. The e2e harness only originates on
  the spoke; delivery on the hub needs a relay, for example impersonating the router or endpoint. (See
  [`TENDERLY_E2E.md`](../development/TENDERLY_E2E.md).)
- **Admin handoff is one-step.** `transferAdmin(account, feeSetter, feeCollector)` grants admin to
  `account` and revokes it from the caller in one step (no pending-accept window). It reverts a
  self-transfer (which would leave zero admins on the non-upgradeable clone) and optionally migrates the
  caller's fee roles in the same call — pass `address(0)` for a fee role to leave it unchanged. The deploy
  scripts pass the fee roles, so nothing is stranded on hand-off. Run the admin behind a multisig.
- **`transferAdmin` with zero fee-role addresses is a PARTIAL handoff.** Passing `address(0)` for
  `feeSetter` / `feeCollector` keeps that role exactly where it sits — including on the *outgoing*
  administrator. After `transferAdmin(newAdmin, address(0), address(0))` the old admin key still holds
  `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE`, so it can keep changing fee policy and withdrawing collected
  fees until the new admin calls `revokeRole` on it. For a complete handoff, always pass explicit non-zero
  fee-role recipients (the production deploy scripts do). This is by design: the zero-address form exists
  for rotating only the admin key while dedicated fee bots keep their roles.
- **Non-upgradeable by design** (EIP-1167 clones of a fixed implementation) — no storage gaps; do not fork
  into a UUPS/Transparent deployment without explicit storage-layout management.
