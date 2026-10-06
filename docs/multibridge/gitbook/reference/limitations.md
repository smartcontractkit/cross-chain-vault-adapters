# Known limitations

Accepted limitations and trust assumptions of the current code.

## Custody and recovery edges

- No party can rescue tokens sent directly to the adapter outside a bridge message. There is no admin token-recovery path, by design.
- A malformed, handler-less transfer of a token that also blocks transfer back to the source sender is unrecoverable.
- Unrefunded LayerZero native prepay becomes issuer float. If a message sets no `failedMessageHandler`, or the handler rejects native, surplus prepay stays in the reserve, and the issuer can reclaim it with `recoverNative`.
- LayerZero shared-decimals dust can accumulate on the adapter and is unrecoverable.

## Token restrictions

Rebasing, inflationary, and fee-on-transfer tokens are unsupported, for both the vault asset and the share token. The adapters measure produced amounts by their own balance delta around the vault call. Tokens whose balances change on their own break this measurement, and the underlying rails do not support them either. Use only standard, non-rebasing, full-amount-transfer ERC-20 tokens.

## Administration

- The admin is trusted for configuration: allowlists, routes, the OFT (LayerZero Omnichain Fungible Token) map, gas, and fee policy. Run the admin behind a multisig with a timelock for mainnet. The admin has no path to user funds.
- Admin handoff is one step, with no pending-accept window. `transferAdmin` with zero-address fee-role arguments is a partial handoff: the outgoing admin keeps the fee roles until revoked.
- Adapters are non-upgradeable EIP-1167 clones with no storage gaps. Do not fork into an upgradeable deployment without explicit storage-layout management.

## Addresses

`script/multibridge/config/Networks.sol` is compiled from official sources, and some values are flagged `VERIFY`. Reconfirm every address before mainnet use.
