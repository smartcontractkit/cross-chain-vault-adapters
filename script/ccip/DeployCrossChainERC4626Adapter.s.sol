// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {console2} from "forge-std/Script.sol";

/// @notice Deploys only `CrossChainERC4626Adapter` via its constructor (no factory). After deployment, call
/// `setChainType`, `setTargetEnabled`, `setProcessingEnabled`, fees, and return-leg config yourself—see the operator
/// guide. @dev Example:
/// forge script script/ccip/DeployCrossChainERC4626Adapter.s.sol:DeployCrossChainERC4626AdapterScript --rpc-url
/// $RPC_URL --account deployer --broadcast
/// Required env vars:
/// - ROUTER
/// - DEFAULT_ADMIN
/// - FEE_SETTER
/// - FEE_COLLECTOR
contract DeployCrossChainERC4626AdapterScript is CcipScriptBase {
  function run() external returns (CrossChainERC4626Adapter adapter) {
    address router = _requireAddress("ROUTER");
    address defaultAdmin = _requireAddress("DEFAULT_ADMIN");
    address feeSetter = _requireAddress("FEE_SETTER");
    address feeCollector = _requireAddress("FEE_COLLECTOR");
    _requireCode("ROUTER", router);

    vm.startBroadcast();
    adapter = new CrossChainERC4626Adapter(router, defaultAdmin, feeSetter, feeCollector);
    vm.stopBroadcast();

    console2.log("CrossChainERC4626Adapter:", address(adapter));
    console2.log("Router:", router);
    console2.log("Default admin:", defaultAdmin);
    console2.log("Fee setter:", feeSetter);
    console2.log("Fee collector:", feeCollector);
    console2.log(
      "Next: configure chains, vault target, processing and fees as DEFAULT_ADMIN (see the deployment guide)."
    );

    return adapter;
  }
}
