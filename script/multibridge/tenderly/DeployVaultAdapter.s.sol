// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapterFactory} from "../../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {TenderlyConfig} from "./TenderlyConfig.sol";

/**
 * @title DeployVaultAdapter
 * @notice Tenderly e2e step 1: on the HUB chain, publish the implementation + factory (unless the
 *         config already points at existing ones), then `factory.deploy(...)` a configured, funded,
 *         operational vault-adapter clone — all from `config/multibridge/tenderly.json`. Writes the resulting
 *         addresses to `deployments/multibridge/<hubChainId>.json` for the originate step to read.
 *
 * @dev Run against the hub Tenderly Virtual TestNet RPC:
 *   forge script script/multibridge/tenderly/DeployVaultAdapter.s.sol:DeployVaultAdapter \
 *     --rpc-url $HUB_RPC_URL --private-key $DEPLOYER_KEY --broadcast --slow
 *
 *   The clone receives `DEFAULT_ADMIN_ROLE` at deploy (no accept step). See
 * docs/multibridge/development/TENDERLY_E2E.md.
 */
contract DeployVaultAdapter is TenderlyConfig {
  using stdJson for string;

  function run() external returns (address app, address factory, address implementation) {
    string memory json = _loadConfig();
    Net memory hub = _readNet(json, ".hub");
    uint256 fundWei = json.readUint(".vaultAdapter.fundWei");
    DeployConfig memory cfg = _readDeployConfig(json, hub);

    vm.startBroadcast();

    implementation = hub.implementation;
    if (hub.factory != address(0)) {
      factory = hub.factory;
    } else {
      if (implementation == address(0)) {
        implementation = address(new CrossChainVaultAdapter());
      }
      factory = address(new CrossChainVaultAdapterFactory(implementation));
    }

    app = CrossChainVaultAdapterFactory(factory).deploy{value: fundWei}(cfg);

    vm.stopBroadcast();

    _writeDeployment(hub.chainId, app, factory, implementation);

    console2.log("network chainId:   ", hub.chainId);
    console2.log("implementation:    ", implementation);
    console2.log("factory:           ", factory);
    console2.log("vault adapter (clone):  ", app);
    console2.log("owner:             ", cfg.owner);
    return (app, factory, implementation);
  }

  /// @dev Persists the deployment so the originate step can resolve the hub adapter address.
  function _writeDeployment(
    uint256 chainId,
    address app,
    address factory,
    address implementation
  ) internal {
    string memory obj = "deployment";
    obj.serialize("chainId", chainId);
    obj.serialize("app", app);
    obj.serialize("factory", factory);
    string memory out = obj.serialize("implementation", implementation);
    string memory path = string.concat("deployments/multibridge/", vm.toString(chainId), ".json");
    out.write(path);
    console2.log("wrote deployment ->", path);
  }
}
