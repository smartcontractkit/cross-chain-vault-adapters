# Roles and emergency controls

The adapter uses OpenZeppelin AccessControl with three roles.

| Role | Typical holder | Main calls |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Multisig | Allowlists, `setCcipSvmConfig`, `setRoute`, `setOftForToken`, `setDestinationGas`, `recoverNative`, `pause`, `unpause`, `transferAdmin`, `grantRole`, `revokeRole` |
| `FEE_SETTER_ROLE` | Fee bot | `setInboundFee`, `setRequireLzReturnPrefunded` |
| `FEE_COLLECTOR_ROLE` | Treasury bot | `withdrawCollectedFee` |

At factory deploy, all three roles go to `owner`. A non-zero `feeCollector` in the config receives the collector role instead. Grant fee roles to dedicated bots with `grantRole` and revoke them from the admin key. Fee bots do not need the admin key.

Run the admin behind a multisig, with a timelock for mainnet.

## What the admin cannot do

The admin has no path to user funds. It cannot move tokens in flight, captured failed-message tokens, or vault positions. `recoverNative` moves only the adapter's native balance, never ERC-20 tokens. Recovery of failed messages is permissionless or handler-driven and needs no role.

## Admin handoff

```solidity
transferAdmin(newAdmin, feeSetter, feeCollector)  // DEFAULT_ADMIN_ROLE
```

One step. The call grants admin to `newAdmin` and revokes it from the caller. A self-transfer reverts.

The fee-role arguments migrate those roles only when non-zero. With `address(0)`, the role stays where it sits, including on the outgoing admin. After `transferAdmin(newAdmin, address(0), address(0))` the old admin key still holds `FEE_SETTER_ROLE` and `FEE_COLLECTOR_ROLE` until the new admin revokes them. For a complete handoff, pass explicit non-zero fee-role recipients. Use the zero-address form only when dedicated fee bots should keep their roles across an admin rotation.

## Emergency pause

`pause()` (admin only) halts:

- Inbound processing. New deliveries are captured as recoverable failed messages instead of executing, and `retryFailedMessage` is blocked.

Refund paths stay live while paused, so captured funds always remain retrievable:

- `refundToSource(...)`, permissionless (unless the message set `onlyLocalRefund` with a handler).
- `refundLocal(...)`, handler only.

`unpause()` resumes processing; messages captured while paused stay captured until recovered.

These paths still move tokens back to the source sender or to a handler-chosen address. To fully halt outbound flow over a compromised route, also remove its outbound allowlist entry and disable the route with `setRoute(enabled = false)`.
