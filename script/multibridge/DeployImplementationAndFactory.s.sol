// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapterFactory} from "../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {CrossChainVaultAdapter} from "../../src/multibridge/examples/CrossChainVaultAdapter.sol";

/**
 * @title DeployImplementationAndFactory
 * @notice Deploys the published {CrossChainVaultAdapter} implementation (CCIP v1 lanes; inert, usable only
 *         via clones) and a {CrossChainVaultAdapterFactory} bound to it. Run this once per chain (the protocol
 *         deployer). Vault issuers then deploy + activate their own adapter by calling `factory.deploy(...)` —
 *         see docs/multibridge/operator/DEPLOYMENT.md.
 *
 *         For a fully configured multi-network deploy, use `DeployProduction`.
 *
 * @dev Usage:
 *   forge script script/multibridge/DeployImplementationAndFactory.s.sol:DeployImplementationAndFactory \
 *     --rpc-url <RPC> --private-key <KEY> --broadcast --verify
 *
 *   Neither contract takes per-chain config at construction: the implementation has no constructor
 *   args, and the factory only needs the implementation address. All per-adapter/per-chain configuration
 *   (routers, endpoint, allowlists, OFTs) is supplied later in `factory.deploy(...)`; routes (the
 *   Stargate/SVM/LOCAL registry) are set by the owner post-handoff or by `DeployProduction`.
 */
contract DeployImplementationAndFactory is Script {
  /// @notice Deploys the {CrossChainVaultAdapter} implementation and a factory bound to it.
  /// @return implementation The deployed adapter implementation.
  /// @return factory The factory bound to it.
  function run() external returns (address implementation, address factory) {
    vm.startBroadcast();
    implementation = address(new CrossChainVaultAdapter());
    factory = address(new CrossChainVaultAdapterFactory(implementation));
    vm.stopBroadcast();

    console2.log("CrossChainVaultAdapter implementation:", implementation);
    console2.log("CrossChainVaultAdapterFactory:        ", factory);
    return (implementation, factory);
  }
}
