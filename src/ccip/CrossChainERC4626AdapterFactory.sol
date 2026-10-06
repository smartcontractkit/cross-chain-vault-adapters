// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CrossChainERC4626Adapter} from "./CrossChainERC4626Adapter.sol";
import {ITypeAndVersion} from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

/// @title CrossChainERC4626AdapterFactory
/// @notice Deploys `CrossChainERC4626Adapter` instances with bundled chain typing, fee setup, processing toggles, and role handoff in one transaction.
/// @dev Temporarily holds every privileged role on the new adapter so it can grant them to the configured accounts, then renounces each role from `_handoffRoles`.
/// @custom:security-contact https://chain.link/security
contract CrossChainERC4626AdapterFactory is ITypeAndVersion {
    /// @inheritdoc ITypeAndVersion
    string public constant override typeAndVersion = "CrossChainERC4626AdapterFactory 1.0.0";

    /// @notice Remote chain metadata applied via `setChainType` (`chainSelector`, `chainType`).
    struct ChainConfig {
        uint64 chainSelector;
        CrossChainERC4626Adapter.ChainType chainType;
    }

    /// @notice Return-leg flat fee row copied into the adapter through `setAssetFee`.
    /// @dev `bridgedToken` keys `assetFees` (vault share on deposit-return, underlying on redeem-return); `fee` is in vault underlying smallest units.
    struct FeeConfig {
        uint64 destinationChainSelector;
        address bridgedToken;
        uint256 fee;
    }

    /// @notice Inputs for `deploy`: router + admin accounts + optional vault wiring + batch configs.
    struct DeploymentConfig {
        address router;
        address defaultAdmin;
        address feeSetter;
        address feeCollector;
        address vaultTarget;
        bool targetEnabled;
        bool depositsEnabled;
        bool redeemsEnabled;
        ChainConfig[] chainConfigs;
        FeeConfig[] feeConfigs;
    }

    /// @notice Signals that `deploy` created `adapter` and finished the initial configuration / role handoff.
    event AdapterDeployed(
        address indexed adapter,
        address indexed router,
        address indexed defaultAdmin,
        address feeSetter,
        address feeCollector,
        address vaultTarget,
        bool targetEnabled,
        bool depositsEnabled,
        bool redeemsEnabled
    );

    /// @notice Instantiates an adapter, applies `DeploymentConfig`, transfers privileged roles, and returns the deployed address.
    /// @dev The factory passes itself as admin/fee recipients initially so `_handoffRoles` can grant roles to the configured EOAs/contracts.
    function deploy(DeploymentConfig calldata config) external returns (address adapterAddress) {
        if (config.defaultAdmin == address(0)) revert CrossChainERC4626Adapter.InvalidAdmin();
        if (config.feeSetter == address(0)) revert CrossChainERC4626Adapter.InvalidFeeSetter();
        if (config.feeCollector == address(0)) revert CrossChainERC4626Adapter.InvalidFeeCollector();

        CrossChainERC4626Adapter adapter =
            new CrossChainERC4626Adapter(config.router, address(this), address(this), address(this));

        for (uint256 i = 0; i < config.chainConfigs.length; ++i) {
            adapter.setChainType(config.chainConfigs[i].chainSelector, config.chainConfigs[i].chainType);
        }

        if (config.vaultTarget != address(0)) {
            adapter.setTargetEnabled(config.vaultTarget, config.targetEnabled);
        }

        adapter.setProcessingEnabled(config.depositsEnabled, config.redeemsEnabled);

        for (uint256 i = 0; i < config.feeConfigs.length; ++i) {
            adapter.setAssetFee(
                config.feeConfigs[i].destinationChainSelector,
                config.feeConfigs[i].bridgedToken,
                config.feeConfigs[i].fee
            );
        }

        _handoffRoles(adapter, config.defaultAdmin, config.feeSetter, config.feeCollector);

        adapterAddress = address(adapter);
        emit AdapterDeployed(
            adapterAddress,
            config.router,
            config.defaultAdmin,
            config.feeSetter,
            config.feeCollector,
            config.vaultTarget,
            config.targetEnabled,
            config.depositsEnabled,
            config.redeemsEnabled
        );
    }

    /// @notice Grants `DEFAULT_ADMIN_ROLE`, `FEE_SETTER_ROLE`, and `FEE_COLLECTOR_ROLE` to the configured operators on `adapter`.
    /// @dev Renounces each role for `address(this)` immediately afterward so the factory cannot retain admin capabilities.
    function _handoffRoles(
        CrossChainERC4626Adapter adapter,
        address defaultAdmin,
        address feeSetter,
        address feeCollector
    ) private {
        bytes32 adminRole = adapter.DEFAULT_ADMIN_ROLE();
        bytes32 feeSetterRole = adapter.FEE_SETTER_ROLE();
        bytes32 feeCollectorRole = adapter.FEE_COLLECTOR_ROLE();

        adapter.grantRole(adminRole, defaultAdmin);
        adapter.grantRole(feeSetterRole, feeSetter);
        adapter.grantRole(feeCollectorRole, feeCollector);

        adapter.renounceRole(feeCollectorRole, address(this));
        adapter.renounceRole(feeSetterRole, address(this));
        adapter.renounceRole(adminRole, address(this));
    }
}
