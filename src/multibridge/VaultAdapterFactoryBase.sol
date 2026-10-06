// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { RouteRegistry } from "./routing/RouteRegistry.sol";

/// @notice Full deploy-and-activate configuration for the vault adapter factories. Adapters built on this
///         base expose the same initialize signature and the same shared config surface
///         ({RouteRegistry} + base allowlists), so one config + one flow serves them all.
/// @param ccipRouter Chainlink CCIP router on this chain.
/// @param lzEndpoint LayerZero EndpointV2 on this chain.
/// @param owner Final admin (`DEFAULT_ADMIN_ROLE`); granted at deploy hand-off (no two-step accept).
/// @param feeCollector Receives {FEE_COLLECTOR_ROLE} at deploy (`address(0)` => same as `owner`).
/// @param vault The ERC-4626 vault the app serves.
/// @param lzSrcEids Inbound LayerZero source eids (parallel to `lzSrcOfts`).
/// @param lzSrcOfts Allowlisted inbound OFTs (parallel to `lzSrcEids`).
/// @param ccipSrcSelectors Inbound CCIP source chain selectors (any sender on the chain).
/// @param ccipDstSelectors Allowlisted outbound CCIP destination selectors.
/// @param lzDstEids Allowlisted outbound LayerZero destination eids.
/// @param oftTokens Tokens to register an OFT for (parallel to `ofts`).
/// @param ofts OFTs that bridge `oftTokens` over LayerZero (parallel to `oftTokens`).
/// @param requireLzReturnPrefunded When true, LZ inbound must prefund the native return leg (4626 app only).
/// @param inboundFeeOutboundTokens Parallel to `inboundFeeDestinations` / `inboundFeeAmounts` (4626 app only).
/// @param inboundFeeDestinations User-facing route keys for `setInboundFee`.
/// @param inboundFeeAmounts Flat inbound-token fees (asset units on deposit, share units on redeem).
struct DeployConfig {
    address ccipRouter;
    address lzEndpoint;
    address owner;
    address feeCollector;
    address vault;
    uint32[] lzSrcEids;
    address[] lzSrcOfts;
    uint64[] ccipSrcSelectors;
    uint64[] ccipDstSelectors;
    uint32[] lzDstEids;
    address[] oftTokens;
    address[] ofts;
    bool requireLzReturnPrefunded;
    address[] inboundFeeOutboundTokens;
    uint64[] inboundFeeDestinations;
    uint256[] inboundFeeAmounts;
}

/**
 * @title VaultAdapterFactoryBase
 * @notice Shared base for the cross-chain vault-adapter factories. One call clones a published
 *         implementation (EIP-1167 minimal proxy), initializes it, installs the full inbound/outbound
 *         allowlist + OFT configuration via the shared {RouteRegistry} surface, optionally funds the
 *         native fee float, and grants {DEFAULT_ADMIN_ROLE} to the intended `owner`. The only per-app
 *         difference — the typed `initialize` call — is the {_initialize} hook each concrete factory
 *         implements; everything else (clone, config, funding, hand-off, registry) is shared here.
 *
 * @dev Registry routes (Stargate/SVM/`setRoute`) are NOT installed here — they are applied post-handoff
 *      by the deploy script as the new admin (see {DeployProduction}). Return-leg fees
 *      (`setInboundFee`, `setRequireLzReturnPrefunded`) are installed when the 4626 factory overrides
 *      {_configureAdapterFees} (requires {FEE_SETTER_ROLE}, granted to the factory at init). At hand-off,
 *      {FEE_SETTER_ROLE} and {FEE_COLLECTOR_ROLE} are granted to `owner`; `feeCollector` overrides the
 *      collector only when non-zero.
 */
abstract contract VaultAdapterFactoryBase is ITypeAndVersion {
    /// @notice The published implementation that all clones delegate to.
    address public immutable i_implementation;

    /// @notice A vault adapter clone (`app`) for `vault` was deployed, configured, `funded` (native), and
    ///         handed off to `owner` ({DEFAULT_ADMIN_ROLE}). This event is the canonical enumeration source
    ///         for deployed adapters (there is no on-chain registry to keep gas/DoS-bounded).
    event VaultAdapterDeployed(address indexed app, address indexed vault, address indexed owner, uint256 funded);

    error ZeroAddress();
    error ArrayLengthMismatch();
    error NativeFundingFailed(address app, uint256 amount);
    error FactoryCannotBeRoleHolder();

    /// @param implementation The official app implementation to clone.
    constructor(address implementation) {
        if (implementation == address(0)) revert ZeroAddress();
        i_implementation = implementation;
    }

    /// @notice Clones, initializes, configures, optionally funds, and hands off a vault adapter.
    /// @param config The deploy-and-activate configuration.
    /// @return app The address of the newly deployed clone.
    function deploy(DeployConfig calldata config) external payable returns (address app) {
        if (config.owner == address(0)) revert ZeroAddress();
        // The hand-off grants the final roles and then revokes EVERY factory role. With the factory as
        // `owner`, the grants are no-ops and the revocations strip the clone's only DEFAULT_ADMIN_ROLE
        // holder — administration would be permanently orphaned on the non-upgradeable clone (and any
        // native funding stranded). A factory `feeCollector` would likewise be silently revoked.
        // {transferAdmin} guards against exactly this self-transfer; guard the raw-role path too.
        if (config.owner == address(this) || config.feeCollector == address(this)) revert FactoryCannotBeRoleHolder();
        if (config.lzSrcEids.length != config.lzSrcOfts.length) revert ArrayLengthMismatch();
        if (config.oftTokens.length != config.ofts.length) revert ArrayLengthMismatch();
        uint256 nFees = config.inboundFeeOutboundTokens.length;
        if (nFees != config.inboundFeeDestinations.length || nFees != config.inboundFeeAmounts.length) {
            revert ArrayLengthMismatch();
        }

        // Clone + initialize atomically (factory as temporary owner), then configure via the shared surface.
        app = Clones.clone(i_implementation);
        _initialize(app, config.ccipRouter, config.lzEndpoint, address(this), config.vault);
        _configure(app, config);
        _configureAdapterFees(app, config);

        // Optionally fund the app's native balance (used to pay outbound CCIP/LayerZero fees).
        if (msg.value > 0) {
            (bool ok,) = app.call{ value: msg.value }("");
            if (!ok) revert NativeFundingFailed(app, msg.value);
        }

        // Hand off admin + fee collector; the configured clone is already operational.
        _handOffAdmin(RouteRegistry(payable(app)), config.owner, config.feeCollector);

        // Emit-only: enumerate deployed adapters off-chain via {VaultAdapterDeployed}. `deploy` is
        // permissionless, so an on-chain array would be a spam/DoS surface (unbounded growth).
        emit VaultAdapterDeployed(app, config.vault, config.owner, msg.value);
    }

    /// @dev Adapter-specific clone initialization (the typed `initialize` call). The factory is `initialOwner`.
    /// @param clone The EIP-1167 clone to initialize.
    /// @param ccipRouter Chainlink CCIP router on this chain.
    /// @param lzEndpoint LayerZero EndpointV2 on this chain.
    /// @param initialOwner Temporary admin during deploy (typically the factory).
    /// @param vault The vault the app serves.
    function _initialize(address clone, address ccipRouter, address lzEndpoint, address initialOwner, address vault) internal virtual;

    /// @dev Installs the inbound/outbound allowlists + OFT map via the shared {RouteRegistry} surface
    ///      (identical for every app kind). Routes are applied later by the owner.
    /// @param clone The adapter clone to configure.
    /// @param config The deploy-and-activate configuration.
    function _configure(address clone, DeployConfig calldata config) internal {
        RouteRegistry app = RouteRegistry(payable(clone));
        for (uint256 i; i < config.lzSrcEids.length; ++i) {
            app.setLzOft(config.lzSrcEids[i], config.lzSrcOfts[i], true);
        }
        for (uint256 i; i < config.ccipSrcSelectors.length; ++i) {
            app.setCcipSource(config.ccipSrcSelectors[i], true);
        }
        for (uint256 i; i < config.ccipDstSelectors.length; ++i) {
            app.setCcipDestination(config.ccipDstSelectors[i], true);
        }
        for (uint256 i; i < config.lzDstEids.length; ++i) {
            app.setLzDestination(config.lzDstEids[i], true);
        }
        for (uint256 i; i < config.oftTokens.length; ++i) {
            app.setOftForToken(config.oftTokens[i], config.ofts[i]);
        }
    }

    /// @dev App-specific fee policy (4626: inbound skim + LZ prefund requirement). No-op in base.
    /// @param clone The adapter clone to configure.
    /// @param config The deploy configuration (fee fields ignored in base).
    function _configureAdapterFees(address clone, DeployConfig calldata config) internal virtual { }

    /// @dev Grants `newAdmin` {DEFAULT_ADMIN_ROLE}, {FEE_SETTER_ROLE}, and {FEE_COLLECTOR_ROLE}
    ///      (collector overridable via `feeCollector`), then revokes all factory roles including
    ///      {FEE_COLLECTOR_ROLE} when the factory held it from init.
    /// @param app The adapter whose roles are handed off.
    /// @param newAdmin The final admin address.
    /// @param feeCollector Optional collector override (`address(0)` => same as `newAdmin`).
    function _handOffAdmin(RouteRegistry app, address newAdmin, address feeCollector) internal {
        bytes32 adminRole = app.DEFAULT_ADMIN_ROLE();
        app.grantRole(adminRole, newAdmin);
        app.grantRole(app.FEE_SETTER_ROLE(), newAdmin);
        address collector = feeCollector == address(0) ? newAdmin : feeCollector;
        app.grantRole(app.FEE_COLLECTOR_ROLE(), collector);
        app.revokeRole(app.FEE_COLLECTOR_ROLE(), address(this));
        app.revokeRole(app.FEE_SETTER_ROLE(), address(this));
        app.revokeRole(adminRole, address(this));
    }
}
