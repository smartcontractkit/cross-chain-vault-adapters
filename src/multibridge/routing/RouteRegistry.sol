// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IOFT } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

import { MultiChannelBridgeAdapter } from "../MultiChannelBridgeAdapter.sol";

/**
 * @title RouteRegistry
 * @notice Reusable outbound-delivery layer on top of {MultiChannelBridgeAdapter}: a per-`(token,
 *         destination)` route registry that picks one of five rails — LayerZero OFT, CCIP, Stargate V2,
 *         CCIP-to-Solana (SVM), or same-chain LOCAL — to deliver a produced token, plus the legacy
 *         `destination`-size default and the LayerZero refund-bounce wiring. It is application-agnostic:
 *         it knows nothing about vaults. Inheriting apps (e.g. the ERC-4626 cross-chain vault
 *         apps) call {_routeOut} to send a produced token onward and inherit the operator config surface
 *         ({setRoute}/{setOftForToken}/{setDestinationGas}).
 *
 * @dev Still abstract: the inheritor implements the base's {_handleReceive}. Routing precedence
 *      ({_routeOut}): an enabled {Route} is authoritative; otherwise the legacy default applies
 *      (`destination <= type(uint32).max` ⇒ LayerZero EID via {s_oftForToken}, else a CCIP selector). The
 *      base's per-rail outbound allowlist still gates every concrete `dstId` (defense in depth).
 */
abstract contract RouteRegistry is MultiChannelBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @notice Default destination gas used when the operator has not set one for a destination.
    uint128 internal constant DEFAULT_DST_GAS = 200_000;

    /// @notice Conventional `destination` key for same-chain (LOCAL) delivery: `0` is never a valid
    ///         LayerZero EID or CCIP chain selector, so it is a safe, unambiguous sentinel. The operator
    ///         registers a `Rail.LOCAL` route at this key (per produced token) and users send
    ///         `destination = 0` to have the produced token delivered on this chain. The contract keys the
    ///         registry by whatever value the operator chooses, so this is a documented default, not a
    ///         hard requirement.
    uint64 public constant LOCAL_DESTINATION = 0;

    /// @notice Outbound transport rail for a produced token. The registry ({s_route}) selects one per
    ///         (token, destination); see {setRoute} / {_routeOut}.
    /// @dev `LZ_OFT` = plain LayerZero OFT (e.g. USDT0); `CCIP` = Chainlink CCIP to an EVM chain (e.g.
    ///      a share token); `STARGATE` = Stargate V2 pooled liquidity (canonical native out — the USDT0
    ///      gap chains); `CCIP_SVM` = Chainlink CCIP to a Solana (SVM) chain (32-byte recipient); `LOCAL`
    ///      = same-chain delivery — transfer the produced ERC-20 straight to the recipient, no bridge, no
    ///      fee. The LayerZero/Stargate rails already carry a 32-byte `recipient`, so they reach Solana
    ///      as-is; only CCIP needs the distinct SVM encoding.
    enum Rail {
        LZ_OFT,
        CCIP,
        STARGATE,
        CCIP_SVM,
        LOCAL
    }

    /// @notice A configured outbound route for one (produced token, user-chosen `destination`) pair. It
    ///         records the rail explicitly, so the same token can leave for different chains over different
    ///         rails (e.g. USDT over USDT0/`LZ_OFT` to Arbitrum but over `STARGATE` to BNB).
    /// @param enabled     Whether this route is active (an unset/false route falls back to the legacy path).
    /// @param rail        Which transport to use.
    /// @param endpoint    The OFT (`LZ_OFT`) or Stargate pool (`STARGATE`) for the token; unused otherwise.
    /// @param dstId       The concrete destination id: a CCIP chain selector (`CCIP`/`CCIP_SVM`) or a
    ///                    LayerZero EID (`LZ_OFT`/`STARGATE`). Decoupled from the `destination` route key.
    /// @dev Slippage is NOT configured on the route. The per-transaction `minAmountOut` the user supplies
    ///      in the app message is the single end-to-end floor: {_routeOut} enforces it on the delivered
    ///      amount — a MEASURED recipient balance-delta check for LOCAL, a source-side check for
    ///      CCIP/CCIP_SVM (which therefore holds only under the rails' 1:1 transfer assumption — the
    ///      destination balance cannot be observed from this chain; route only standard 1:1 tokens over
    ///      CCIP), and the bridge's own `minAmountLD` for LZ_OFT/STARGATE (covers OFT dust removal and
    ///      the Stargate LP fee).
    struct Route {
        bool enabled;
        Rail rail;
        address endpoint;
        uint64 dstId;
    }

    /// @notice OFT used to bridge a token over LayerZero (set for whichever produced token is an OFT).
    ///         Used for the legacy outbound default AND for bouncing a LayerZero inbound back to source
    ///         ({_oftFor}). Outbound delivery prefers the {s_route} registry when a route is set.
    mapping(address token => address oft) public s_oftForToken;
    /// @notice Outbound route registry: per produced token, per user-chosen `destination` route key, the
    ///         rail + endpoint to deliver over. AUTHORITATIVE when `enabled`; otherwise {_routeOut} falls
    ///         back to the legacy `destination`-size discriminator over {s_oftForToken} / CCIP.
    mapping(address token => mapping(uint64 destination => Route route)) public s_route;
    /// @notice Operator-set destination gas (0 => use {DEFAULT_DST_GAS}). Keyed by the CONCRETE packed
    ///         destination id (LayerZero EID / CCIP selector): for an enabled route that is `route.dstId`;
    ///         only the legacy default path (no route) keys by the user-facing `destination` itself.
    mapping(uint64 destination => uint128 gasLimit) public s_dstGas;

    /// @notice The per-token LayerZero OFT map entry for `token` was set to `oft`.
    event OftForTokenSet(address indexed token, address indexed oft);
    /// @notice The outbound route for `(token, destination)` was set (see {Route} for the fields).
    event RouteSet(address indexed token, uint64 indexed destination, bool enabled, Rail rail, address endpoint, uint64 dstId);
    /// @notice The per-destination outbound gas for `destination` was set to `gasLimit` (0 => default).
    event DestinationGasSet(uint64 indexed destination, uint128 gasLimit);

    error OftNotConfigured(address token);
    error AssetOftMismatch(address oftToken, address token);
    error NonEvmLocalRecipient(bytes32 recipient);
    error NonEvmCcipRecipient(bytes32 recipient);
    error InvalidDstId(uint64 dstId);
    error ZeroRecipient();
    error MinAmountOutNotMet(uint256 amount, uint256 minAmountOut);
    error DestinationGasTooLarge(uint128 gasLimit);
    error LocalDestinationRequiresRoute();

    /*//////////////////////////////////////////////////////////////
                            ADMIN CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Registers the OFT that bridges `token` over LayerZero (asset and/or share token).
    /// @param token The token to map.
    /// @param oft The OFT/OFTAdapter whose `token()` is `token`; zero to clear.
    function setOftForToken(address token, address oft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oft != address(0)) {
            address oftToken = IOFT(oft).token();
            if (oftToken != token) revert AssetOftMismatch(oftToken, token);
        }
        s_oftForToken[token] = oft;
        emit OftForTokenSet(token, oft);
    }

    /// @notice Registers (or clears) the outbound route for a produced `token` to a user-facing
    ///         `destination` route key. When `route.enabled`, {_routeOut} sends over `route.rail` to
    ///         `route.dstId` via `route.endpoint`, taking precedence over the legacy default. The base
    ///         still gates the concrete `dstId` by its per-rail outbound allowlist — a route AND its
    ///         allowlist entry are both required (defense in depth).
    /// @param token       The produced token.
    /// @param destination The user-facing route key carried in the inbound message.
    /// @param route       The route; `enabled=false` clears it (falls back to the legacy default).
    function setRoute(address token, uint64 destination, Route calldata route) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (route.enabled) {
            if (route.rail == Rail.LZ_OFT || route.rail == Rail.STARGATE) {
                // OFT / Stargate: the endpoint must bridge exactly this token, and `dstId` is a LayerZero
                // EID (uint32) — reject a value that would silently truncate on send.
                if (route.endpoint == address(0)) revert ZeroAddress();
                address endpointToken = IOFT(route.endpoint).token();
                if (endpointToken != token) revert AssetOftMismatch(endpointToken, token);
                if (route.dstId > type(uint32).max) revert InvalidDstId(route.dstId);
            } else if (route.rail == Rail.CCIP || route.rail == Rail.CCIP_SVM) {
                // CCIP chain selectors occupy the high end of the uint64 space; requiring `> uint32.max`
                // keeps them unambiguous vs the legacy EID-sized default and catches a fat-fingered id.
                if (route.dstId <= type(uint32).max) revert InvalidDstId(route.dstId);
                // A CCIP_SVM route only makes sense to a selector marked as an SVM lane — reject at
                // configuration time so the invalid route fails immediately rather than on first use.
                if (route.rail == Rail.CCIP_SVM && !s_ccipSvm[route.dstId].enabled) revert SvmLaneNotEnabled(route.dstId);
            }
            // Rail.LOCAL carries no `dstId` (it is unused) and no endpoint.
        }
        s_route[token][destination] = route;
        emit RouteSet(token, destination, route.enabled, route.rail, route.endpoint, route.dstId);
    }

    /// @notice Operator sets the outbound destination gas for a packed `destination` (0 clears it back to
    ///         {DEFAULT_DST_GAS}). This is the LayerZero `lzReceive` option gas; CCIP deliveries from
    ///         {_routeOut} carry empty `data` and are always sent with gasLimit 0 (token-only transfers),
    ///         so this value does not apply to them. Key by the CONCRETE destination id the send targets:
    ///         an enabled route reads the gas for its `route.dstId`, NOT for the user-facing route key
    ///         (they may differ on decoupled routes).
    /// @param destination The packed destination (LayerZero EID or CCIP selector).
    /// @param gasLimit The destination execution gas. Bounded to `type(uint32).max`: CCIP v2
    ///        `GenericExtraArgsV3` carries a uint32 gas limit and its encoder reverts
    ///        `GasLimitTooLarge` at SEND time, so a larger value configured here would stall every
    ///        outbound send on a v2 lane until corrected — reject it at configuration time instead.
    ///        (No real destination needs more than ~4.29B gas, so the bound is not a limitation.)
    function setDestinationGas(uint64 destination, uint128 gasLimit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (gasLimit > type(uint32).max) revert DestinationGasTooLarge(gasLimit);
        s_dstGas[destination] = gasLimit;
        emit DestinationGasSet(destination, gasLimit);
    }

    /// @inheritdoc MultiChannelBridgeAdapter
    /// @dev Lets the base bounce a LayerZero inbound back to source using the token=>OFT map.
    /// @param token The token to resolve an OFT for.
    /// @return oft The LayerZero OFT that bridges `token`, or `address(0)` if unset.
    function _oftFor(address token) internal view virtual override returns (address) {
        return s_oftForToken[token];
    }

    /*//////////////////////////////////////////////////////////////
                              OUTBOUND ROUTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Delivers `amount` of `token` to `recipient` at `destination` over the registry-selected rail
    ///         (or the legacy default), enforcing `minAmountOut` as the floor on the DELIVERED amount. The
    ///         single outbound entrypoint for inheriting apps.
    /// @param token        The produced token to deliver.
    /// @param amount       The produced amount.
    /// @param minAmountOut The minimum the recipient must receive (output-token units). For LOCAL it is
    ///        MEASURED on the recipient's balance delta; for CCIP/CCIP_SVM it is a source-side check that
    ///        holds only under a 1:1 transfer assumption (the destination balance is unobservable here);
    ///        for LZ_OFT/STARGATE it is the bridge's `minAmountLD`, which the bridge checks when sending
    ///        (after dust removal / the LP fee). A breach reverts (the inheriting app then captures the inbound
    ///        for recoverable retry/refund).
    /// @param destination  The user-facing route key (`0`/LOCAL = same-chain).
    /// @param recipient    The beneficiary (peer bytes32 for OFT/Stargate/SVM; low-20-byte EVM for CCIP/LOCAL).
    /// @return fee     The native fee paid for the outbound send (0 for LOCAL).
    /// @return bridged Whether the delivery left this chain over a rail (false for LOCAL same-chain).
    function _routeOut(address token, uint256 amount, uint256 minAmountOut, uint64 destination, bytes32 recipient) internal returns (uint256 fee, bool bridged) {
        if (recipient == bytes32(0)) revert ZeroRecipient(); // never deliver/burn to the zero recipient

        Route memory route = s_route[token][destination];
        // An enabled route sends to `route.dstId`, so its gas is keyed by that concrete destination id;
        // only the legacy default (where the route key IS the packed destination) keys by `destination`.
        uint128 gas = s_dstGas[route.enabled ? route.dstId : destination];
        if (gas == 0) gas = DEFAULT_DST_GAS;

        if (route.enabled) {
            fee = _deliverViaRoute(route, token, amount, minAmountOut, recipient, gas);
            bridged = route.rail != Rail.LOCAL;
        } else if (destination <= type(uint32).max) {
            // `0` is the LOCAL_DESTINATION sentinel, never a valid LayerZero EID: without an enabled
            // LOCAL route it must revert (the inheriting app captures for recovery) — falling through
            // to a bridged send would contradict the sentinel's documented same-chain semantics.
            if (destination == LOCAL_DESTINATION) revert LocalDestinationRequiresRoute();
            // Legacy default: a small `destination` is a LayerZero EID, routed via the per-token OFT map.
            // The OFT enforces `minAmountLD = minAmountOut` when sending.
            address oft = s_oftForToken[token];
            if (oft == address(0)) revert OftNotConfigured(token);
            // forge-lint: disable-next-line(unsafe-typecast)
            (, fee) = _sendViaOft(uint32(destination), recipient, oft, amount, minAmountOut, "", lzReceiveOption(gas));
            bridged = true;
        } else {
            // Legacy default: a large `destination` is a CCIP chain selector (1:1 token transfer).
            // The delivery carries empty `data`, so send with gasLimit 0: it qualifies as a TOKEN-ONLY
            // transfer on the destination, which bypasses the CCIP v2 receiver finality gate — a
            // non-zero gas limit + non-zero requested finality permanently bricks delivery to a
            // v1-only receiver contract (tokens burned/locked at source, stranded outside recovery).
            if (amount < minAmountOut) revert MinAmountOutNotMet(amount, minAmountOut);
            (, fee) = _sendViaCcip(destination, _toEvmRecipient(recipient), token, amount, "", 0, address(0));
            bridged = true;
        }
    }

    /// @dev Dispatches a delivery over the registry-selected rail, enforcing `minAmountOut` on the
    ///      delivered amount. The base enforces the per-rail outbound allowlist on `route.dstId`.
    /// @param route The enabled outbound route.
    /// @param token The produced token to deliver.
    /// @param amount The produced amount.
    /// @param minAmountOut The minimum the recipient must receive (see {_routeOut}).
    /// @param recipient The beneficiary (peer bytes32 for OFT/Stargate/SVM; low-20-byte EVM for CCIP/LOCAL).
    /// @param gas Destination execution gas for the LayerZero `lzReceive` options. CCIP deliveries carry
    ///        empty `data` and are sent with gasLimit 0 (token-only), so they do not consume it.
    /// @return fee The native fee paid for the outbound send (0 for LOCAL).
    function _deliverViaRoute(Route memory route, address token, uint256 amount, uint256 minAmountOut, bytes32 recipient, uint128 gas) internal returns (uint256 fee) {
        if (route.rail == Rail.CCIP) {
            // CCIP CCT is a 1:1 token transfer with no destination `minAmountLD`, so floor on the source amount.
            // Empty `data` => send with gasLimit 0 so the message is a TOKEN-ONLY transfer (see the
            // legacy CCIP branch in {_routeOut} for why a non-zero gas limit is dangerous under v2).
            if (amount < minAmountOut) revert MinAmountOutNotMet(amount, minAmountOut);
            (, fee) = _sendViaCcip(route.dstId, _toEvmRecipient(recipient), token, amount, "", 0, address(0));
        } else if (route.rail == Rail.CCIP_SVM) {
            // Solana over CCIP: the full 32-byte recipient is the SVM token receiver (also a 1:1 transfer).
            if (amount < minAmountOut) revert MinAmountOutNotMet(amount, minAmountOut);
            (, fee) = _sendViaCcipSvm(route.dstId, recipient, token, amount);
        } else if (route.rail == Rail.LZ_OFT) {
            // The OFT enforces `minAmountLD` when sending (covers shared-decimals dust removal).
            // forge-lint: disable-next-line(unsafe-typecast)
            (, fee) = _sendViaOft(uint32(route.dstId), recipient, route.endpoint, amount, minAmountOut, "", lzReceiveOption(gas));
        } else if (route.rail == Rail.STARGATE) {
            // Pooled liquidity, canonical native out; the pool enforces `minAmountLD` after the LP fee.
            // forge-lint: disable-next-line(unsafe-typecast)
            (, fee) = _sendViaStargate(uint32(route.dstId), recipient, route.endpoint, amount, minAmountOut, lzReceiveOption(gas));
        } else {
            // Rail.LOCAL — same-chain: transfer the produced ERC-20 straight to the recipient, no fee.
            _deliverLocal(token, amount, minAmountOut, recipient);
            fee = 0;
        }
    }

    /// @dev Same-chain delivery: send the produced token directly to the recipient and enforce
    ///      `minAmountOut` on the recipient's MEASURED pre/post `balanceOf` delta — the only rail where
    ///      the delivered amount is observable on this chain, so the documented delivered-amount floor
    ///      holds even for a token that is not 1:1 on transfer (e.g. fee-on-transfer). The recipient must
    ///      be a plain EVM address (the high 12 bytes of the `bytes32` are zero) — a 32-byte non-EVM
    ///      (e.g. Solana) recipient cannot receive a local ERC-20 and is rejected rather than silently
    ///      truncated.
    /// @param token The produced token to transfer.
    /// @param amount The amount to transfer.
    /// @param minAmountOut The floor on the amount the recipient actually receives.
    /// @param recipient The beneficiary encoded as bytes32 (low 20 bytes = EVM address).
    function _deliverLocal(address token, uint256 amount, uint256 minAmountOut, bytes32 recipient) internal {
        if (uint256(recipient) >> 160 != 0) revert NonEvmLocalRecipient(recipient);
        address to = address(uint160(uint256(recipient)));
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        IERC20(token).safeTransfer(to, amount);
        uint256 delivered = IERC20(token).balanceOf(to) - balanceBefore;
        if (delivered < minAmountOut) revert MinAmountOutNotMet(delivered, minAmountOut);
    }

    /// @dev Narrows a bytes32 recipient to an EVM address for CCIP EVM delivery. The high 12 bytes must
    ///      be zero — a 32-byte non-EVM recipient (e.g. a Solana address supplied for an EVM CCIP route)
    ///      is rejected rather than silently truncated to its low 20 bytes, so the revert is captured
    ///      into the recovery flow instead of bridging to an unintended address. Only the CCIP_SVM rail
    ///      consumes a full 32-byte recipient.
    /// @param recipient The beneficiary encoded as bytes32 (low 20 bytes = EVM address).
    /// @return The narrowed EVM recipient.
    function _toEvmRecipient(bytes32 recipient) internal pure returns (address) {
        if (uint256(recipient) >> 160 != 0) revert NonEvmCcipRecipient(recipient);
        return address(uint160(uint256(recipient)));
    }
}
