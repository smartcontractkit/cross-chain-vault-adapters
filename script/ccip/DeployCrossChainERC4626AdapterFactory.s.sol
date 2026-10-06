// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {Script, console2} from "forge-std/Script.sol";

import {CrossChainERC4626AdapterFactory} from "../../src/ccip/CrossChainERC4626AdapterFactory.sol";

/// @notice Deploys only `CrossChainERC4626AdapterFactory`. Configure adapters later via `factory.deploy(config)` (see
/// deployment guide) or the full repo script. @dev No environment variables are required.
///
/// Example:
/// forge script
/// script/ccip/DeployCrossChainERC4626AdapterFactory.s.sol:DeployCrossChainERC4626AdapterFactoryScript --rpc-url
/// $RPC_URL --account deployer --broadcast
contract DeployCrossChainERC4626AdapterFactoryScript is Script {
  function run() external returns (CrossChainERC4626AdapterFactory factory) {
    vm.startBroadcast();
    factory = new CrossChainERC4626AdapterFactory();
    vm.stopBroadcast();

    console2.log("CrossChainERC4626AdapterFactory:", address(factory));
    console2.log("typeAndVersion:", factory.typeAndVersion());

    return factory;
  }
}
