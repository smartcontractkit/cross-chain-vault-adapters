// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ITypeAndVersion } from "@chainlink/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";

import { VaultAdapterFactoryBase, DeployConfig } from "./VaultAdapterFactoryBase.sol";
import { CrossChainVaultAdapter } from "./examples/CrossChainVaultAdapter.sol";

/**
 * @title CrossChainVaultAdapterFactory
 * @notice Deploys and activates a {CrossChainVaultAdapter} (synchronous ERC-4626 vault adapter) as a
 *         non-upgradeable EIP-1167 minimal proxy of a single published implementation. All of
 *         the clone/config/funding/hand-off flow lives in {VaultAdapterFactoryBase}; this subclass only
 *         binds the typed {CrossChainVaultAdapter.initialize}. See {VaultAdapterFactoryBase}.
 *
 * @dev Why clones of a fixed implementation: the logic is deployed and verified once (the implementation
 *      at {i_implementation}); every deployment is a tiny standard EIP-1167 proxy that delegatecalls it.
 *      `clone` + `initialize` happen in the same transaction, so there is no initialize front-run.
 */
contract CrossChainVaultAdapterFactory is VaultAdapterFactoryBase {
    /// @param implementation The official {CrossChainVaultAdapter} implementation to clone.
    constructor(address implementation) VaultAdapterFactoryBase(implementation) { }

    /// @inheritdoc ITypeAndVersion
    function typeAndVersion() external pure override returns (string memory) {
        return "CrossChainVaultAdapterFactory 1.0.0";
    }

    /// @inheritdoc VaultAdapterFactoryBase
    /// @param clone The EIP-1167 clone to initialize.
    /// @param ccipRouter Chainlink CCIP router on this chain.
    /// @param lzEndpoint LayerZero EndpointV2 on this chain.
    /// @param initialOwner Temporary admin during deploy (typically the factory).
    /// @param vault The ERC-4626 vault the app serves.
    function _initialize(address clone, address ccipRouter, address lzEndpoint, address initialOwner, address vault) internal override {
        CrossChainVaultAdapter(payable(clone)).initialize(ccipRouter, lzEndpoint, initialOwner, vault);
    }

    /// @inheritdoc VaultAdapterFactoryBase
    /// @param clone The adapter clone to configure.
    /// @param config The deploy configuration (`requireLzReturnPrefunded` and inbound fee arrays).
    function _configureAdapterFees(address clone, DeployConfig calldata config) internal override {
        CrossChainVaultAdapter app = CrossChainVaultAdapter(payable(clone));
        if (config.requireLzReturnPrefunded) {
            app.setRequireLzReturnPrefunded(true);
        }
        for (uint256 i; i < config.inboundFeeOutboundTokens.length; ++i) {
            app.setInboundFee(
                config.inboundFeeOutboundTokens[i], config.inboundFeeDestinations[i], config.inboundFeeAmounts[i]
            );
        }
    }
}
