# MultiChannelBridgeAdapter

A minimal, reusable transport base that receives and sends tokens over Chainlink CCIP, LayerZero V2 OFT
(Omnichain Fungible Token), and Stargate V2, including CCIP to Solana (SVM, the Solana Virtual Machine
message format). It has one inbound path and four outbound send helpers. On receipt it normalizes the
delivery and hands the tokens plus arbitrary data to a single hook that applications implement.
`CrossChainVaultAdapter` (synchronous ERC-4626) inherits this base through the `RouteRegistry` routing
mixin.

Source: [`src/multibridge/MultiChannelBridgeAdapter.sol`](../../../src/multibridge/MultiChannelBridgeAdapter.sol) (abstract).

## What it does

### Receive

- CCIP: `ccipReceive(Client.Any2EVMMessage)`. Only the configured router may call it. The source chain
  selector must be allowlisted (`setCcipSource`); the CCIP sender is recorded but not authenticated. The
  selector check runs inside the isolated `processInbound` call, so a delivery from a non-allowlisted
  chain is captured as a recoverable failed message rather than reverting (its tokens are real).
- LayerZero: `lzCompose(...)`. Only the configured endpoint may call it, and the `(srcEid, oft)` pair (EID
  is the LayerZero endpoint ID) must be allowlisted (`setLzOft`). A non-allowlisted compose reverts at
  the entrypoint: it credits no tokens, so there is nothing to capture. The OFT compose is decoded with
  `OFTComposeMsgCodec`.
- Both paths normalize into one struct and call the hook:

  ```solidity
  struct Inbound {
      Channel channel;                // CCIP | LayerZero
      uint64  srcId;                  // CCIP sourceChainSelector | LZ srcEid
      bytes32 sender;                 // CCIP sender word | OFT composeFrom
      bytes32 guid;                   // CCIP messageId | LZ guid
      Client.EVMTokenAmount[] tokens; // tokens already credited to this contract
      bytes   data;                   // arbitrary application payload
      address lzOft;                  // LZ: the local OFT/pool that delivered; CCIP: address(0)
  }
  function _handleReceive(Inbound calldata inbound) internal virtual; // the application implements this
  ```

Stargate inbound arrives as an OFT compose (a Stargate pool is an `IOFT`), so it uses the same
`lzCompose` path. A Solana inbound sender is a 32-byte word, normalized like any other. Receiving needs no
rail-specific code; only the send helpers differ.

### Send

Internal helpers the application calls:

```solidity
_sendViaCcip(uint64 dstSelector, address receiver, address token, uint256 amount,
             bytes data, uint256 dstGasLimit, address feeToken) returns (bytes32 messageId, uint256 fee);
_sendViaOft(uint32 dstEid, bytes32 to, address oft, uint256 amount, uint256 minAmount,
            bytes composeMsg, bytes extraOptions) returns (bytes32 guid, uint256 fee);
_sendViaStargate(uint32 dstEid, bytes32 to, address pool, uint256 amount, uint256 minAmountLD,
                 bytes extraOptions) returns (bytes32 guid, uint256 fee);   // Stargate V2, taxi mode
_sendViaCcipSvm(uint64 dstSelector, bytes32 tokenReceiver, address token, uint256 amount)
                returns (bytes32 messageId, uint256 fee);                    // CCIP to Solana
```

Each helper checks its own outbound allowlist (`setCcipDestination`, `setLzDestination`,
`setStargateDestination`); `_sendViaCcipSvm` also requires the selector to be marked as an SVM lane
(`setCcipSvmConfig`). View helpers: `quoteCcip(...)`, `quoteOft(...)`, `quoteStargate(...)`, and
`lzReceiveOption(gas)`. Native fees are paid from the contract balance (fund it by sending native to
`receive()`); `_sendViaCcip` also accepts an ERC-20 fee token.

CCIP `extraArgs` are built in one place, the `_buildCcipExtraArgs` hook, which encodes CCIP v1
`GenericExtraArgsV2` (gas limit plus out-of-order execution).

The CCIP-SVM helper encodes `Client.SVMExtraArgsV1`. Its `tokenReceiver` is the recipient's wallet
address (the token-account owner), never an associated token account (ATA): the offramp derives the ATA
automatically, and an ATA here locks the tokens permanently. See [`SOLANA.md`](../informational/SOLANA.md).
The refund bounce to a CCIP source uses the same SVM encoding when that source selector is marked SVM.

### Configure

| Function | Role |
|---|---|
| `setCcipSource`, `setLzOft`, `setCcipDestination`, `setLzDestination`, `setStargateDestination`, `setCcipSvmConfig` | `DEFAULT_ADMIN_ROLE` |
| `pause`, `unpause` | `DEFAULT_ADMIN_ROLE` |
| `recoverNative` (native balance only) | `DEFAULT_ADMIN_ROLE` |
| `transferAdmin(account, feeSetter, feeCollector)` | `DEFAULT_ADMIN_ROLE` |

The admin has no token-recovery function: there is no `rescueToken` or admin refund, and captured
tokens are recovered through the paths below. The vault adapter adds fee functions on separate roles:
`FEE_SETTER_ROLE` (`setInboundFee`, `setRequireLzReturnPrefunded`) and `FEE_COLLECTOR_ROLE`
(`withdrawCollectedFee`), so bots can manage fees without the admin key.

## How an application uses it

The base is clone-friendly (`Initializable`): applications initialize rather than construct, so the
published implementation is deployed once and cloned (EIP-1167) per vault.

```solidity
contract MyApp is MultiChannelBridgeAdapter {
    constructor() { _disableInitializers(); } // the implementation is inert; only clones are used

    function initialize(address ccipRouter, address lzEndpoint, address initialAdmin) external initializer {
        __MultiChannelBridgeAdapter_init(ccipRouter, lzEndpoint, initialAdmin);
    }

    function _handleReceive(Inbound calldata inbound) internal override {
        // inbound.tokens are already held by this contract; inbound.data is the instruction.
        // For example: decode data, deposit inbound.tokens[0] into a vault, then bridge the result
        // with _sendViaCcip(...) (a CCIP token such as a vault share) or _sendViaOft(...) (an OFT such as USDT0).
    }
}
```

`__MultiChannelBridgeAdapter_init` grants `initialAdmin` `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and
`FEE_COLLECTOR_ROLE`. Applications that want failed-message handlers also override
`failedMessageHandler(bytes)` and `onlyLocalRefund(bytes)` to parse their payload, and `_oftFor(token)`
if they accept LayerZero inbound.

[`test/multibridge/adapter/MultiChannelBridgeAdapter.t.sol`](../../../test/multibridge/adapter/MultiChannelBridgeAdapter.t.sol)
contains an `ExampleApp` that records each delivery and, when `data` carries a forwarding instruction,
re-sends the received token over the chosen rail.

## Failure handling

The base runs `_handleReceive` inside an isolated external self-call (`processInbound`) wrapped in
`try/catch`:

- Success: emits `MessageProcessed(guid)`.
- Revert: the failure is caught. A fixed-size hash commitment (`keccak256(abi.encode(inbound))`) is
  stored in `s_failedInboundHash[guid]`, bounding the storage cost regardless of payload size, and the
  full `abi.encode(inbound)` is emitted in `MessageFailed(guid, channel, message, reason)`. The tokens the
  channel delivered stay in the contract.

### Delivered native value

`lzCompose` is `payable`, so a sender can attach native value to prepay the outbound return leg. The base
forwards it to `_handleReceive` and afterwards returns the unused remainder (the surplus over the fee on
success, or the full amount on failure) to the message's `failedMessageHandler` as native, best-effort,
emitting `DeliveredValueRefunded`. If the message names no handler, or the transfer fails, the surplus
stays in the contract's native reserve. CCIP cannot deliver native value to a receiver, so CCIP returns
are funded from the reserve.

### Recovery

Resolution needs no owner or admin. The base reads a per-message handler and a local-only flag from the
payload through application hooks. A malformed or dataless transfer has no handler and can only be
bounced back to source.

```solidity
// Application hooks (defaults: no handler, permissionless bounce allowed). A payload that fails to
// decode is treated as "no handler" and "not local-only".
function failedMessageHandler(bytes calldata data) external view virtual returns (address);
function onlyLocalRefund(bytes calldata data) external view virtual returns (bool);

// Callers pass the Inbound reconstructed from the MessageFailed event; it is verified against the
// stored hash commitment (InboundMismatch on any deviation).
function refundToSource(Inbound calldata inbound) external payable;          // permissionless
function retryFailedMessage(Inbound calldata inbound) external payable;      // handler only
function refundLocal(Inbound calldata inbound, address to) external;         // handler only

function isFailed(bytes32 guid)          external view returns (bool);    // captured, unresolved
function isRefunded(bytes32 guid)        external view returns (bool);    // terminal: tokens returned
function failedMessageHash(bytes32 guid) external view returns (bytes32); // the stored commitment

// Override points for the source bounce
function _bridgeBackToSource(Inbound memory inbound) internal virtual;  // CCIP (EVM or SVM) or LZ
function _oftFor(address token) internal view virtual returns (address); // LZ fallback when lzOft is unset
```

- `refundToSource` bounces the held tokens to `inbound.sender` on the source chain over the channel they
  arrived on. Anyone can call it (for example a keeper bot), unless the payload set `onlyLocalRefund` and
  names a handler, in which case it reverts `LocalRefundOnly`.
- `retryFailedMessage` re-runs `processInbound` with the original delivery. If it reverts again, the
  whole transaction reverts and the message stays failed. It is blocked while the contract is paused.
- `refundLocal` sends the held tokens to a local address chosen by the handler.
- `refundToSource` and `refundLocal` mark the message refunded (terminal); a successful retry emits
  `MessageRecovered`. Both refund paths work while paused.

Design properties:

- The prefunded reserve is spent only by original deliveries. Recovery actions that send outbound
  (`retryFailedMessage`, `refundToSource`) are funded by the caller's `msg.value`, revert
  `RetryReserveDrawn` if they would draw the reserve down, and return any surplus to the caller.
- No handler means bounce-to-source only: the handler-only paths revert `NoHandler`.
- With a handler, the handler chooses between retry and local refund. `refundToSource` stays open to
  anyone as a fallback unless the sender set `onlyLocalRefund`. A handler-less message can never be
  frozen: the flag is ignored without a handler.

## Design choices and boundaries

- Transport and default error state only. No vault logic and no fee accounting; those belong to the
  application. The application decides what to do with a message (`_handleReceive`), who may recover it
  (`failedMessageHandler`, `onlyLocalRefund`), and how a bounce is routed (`_bridgeBackToSource`,
  `_oftFor`). No admin role can move captured tokens.
- Token hygiene for USDT-class tokens: `forceApprove` for every approval (USDT rejects non-zero to
  non-zero `approve` and omits boolean returns), and no decimals are assumed. Native USDT is not a CCIP
  token; use USDT0 (LayerZero OFT) or Stargate for it. CCIP is for tokens with a CCIP pool, such as a
  vault share token you provision.
- OFT token versus OFT contract: `_sendViaOft` takes the OFT contract; `IOFT(oft).token()` is the asset
  and `approvalRequired()` selects adapter (approve and lock) versus native (burn) behavior, so it works
  for USDT0, where the user token differs from the OFT contract.
- Authentication: callers other than the configured router or endpoint revert; destinations must be
  allowlisted before sends.
- Pause: `pause()` makes `processInbound` revert, so new deliveries are captured instead of executed
  and `retryFailedMessage` is blocked. Refunds stay available.
- Access control: `AccessControlUpgradeable` with `DEFAULT_ADMIN_ROLE`, plus `FEE_SETTER_ROLE` and
  `FEE_COLLECTOR_ROLE`. `transferAdmin` performs a one-step handoff. Non-upgradeable: clones
  delegatecall a fixed implementation, with no proxy admin or upgrade path.
