// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapterFactory} from "../../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {TenderlyConfig} from "../tenderly/TenderlyConfig.sol";

/**
 * @title DeployAdapterClone
 * @notice Step 2 on Sepolia: call an existing factory's `deploy(...)`, accept ownership, install routes.
 *         Run `DeployImplementationAndFactory` (or `script/multibridge/deploy-factory-sepolia.sh`) first and paste the
 *         addresses into `config/multibridge/sepolia.json` → `hub.factory` / `hub.implementation`.
 *
 * @dev   export DEPLOYER=$(cast wallet address --account vaultdeployer)
 *       CONFIG=config/multibridge/sepolia.json forge script
 * script/multibridge/sepolia/DeployAdapterClone.s.sol:DeployAdapterClone \
 *         --rpc-url $HUB_RPC_URL --account vaultdeployer --broadcast --slow --verify
 */
contract DeployAdapterClone is TenderlyConfig {
  using stdJson for string;

  struct RouteSpec {
    uint64 destination;
    address endpoint;
    string rail;
    string token;
  }

  error FactoryNotConfigured();
  error UnknownRail(string rail);
  error UnknownToken(string token);

  function run() external returns (address app) {
    string memory json = _loadConfig();
    TenderlyConfig.Net memory hub = _readNet(json, ".hub");
    if (hub.factory == address(0)) revert FactoryNotConfigured();

    string memory vaKey = vm.envOr("VAULT_ADAPTER_KEY", string(".vaultAdapter"));
    string memory routesKey = vm.envOr("ROUTES_KEY", string(".routes"));

    // Fork hub state so initialize()'s vault.asset() resolves during script execution.
    // SepoliaFactoryDeploy.t.sol validates the config; use --skip-simulation if preflight diverges.
    vm.createSelectFork(vm.envOr("HUB_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));

    address deployer = vm.envOr("DEPLOYER", msg.sender);
    address realOwner = json.readAddressOr(string.concat(vaKey, ".owner"), address(0));
    if (realOwner == address(0)) realOwner = deployer;

    DeployConfig memory cfg = _readDeployConfig(json, hub, vaKey);
    cfg.owner = deployer;

    uint256 fundWei = json.readUintOr(string.concat(vaKey, ".fundWei"), json.readUint(".vaultAdapter.fundWei"));
    RouteSpec[] memory routes = _readRoutes(json, routesKey);
    uint32[] memory stargateDstEids =
      _u32(json.readUintArrayOr(string.concat(vaKey, ".stargateDstEids"), new uint256[](0)));

    vm.startBroadcast();

    app = CrossChainVaultAdapterFactory(hub.factory).deploy{value: fundWei}(cfg);

    RouteRegistry adapter = RouteRegistry(payable(app));

    for (uint256 i; i < stargateDstEids.length; ++i) {
      adapter.setStargateDestination(stargateDstEids[i], true);
    }
    for (uint256 i; i < routes.length; ++i) {
      adapter.setRoute(_token(json, vaKey, routes[i].token), routes[i].destination, _route(routes[i]));
    }

    if (realOwner != deployer) {
      adapter.transferAdmin(realOwner, realOwner, realOwner);
    }

    vm.stopBroadcast();

    _writeDeployment(hub.chainId, app, hub.factory, hub.implementation, realOwner, routes.length);

    console2.log("factory:           ", hub.factory);
    console2.log("implementation:    ", hub.implementation);
    console2.log("vault adapter:     ", app);
    console2.log("routes installed:  ", routes.length);
    console2.log("admin:             ", realOwner);
    console2.log("vaultAdapter key:  ", vaKey);
    return app;
  }

  function _readRoutes(
    string memory json,
    string memory routesKey
  ) internal pure returns (RouteSpec[] memory specs) {
    bytes memory raw = vm.parseJson(json, routesKey);
    specs = abi.decode(raw, (RouteSpec[]));
    return specs;
  }

  function _token(
    string memory json,
    string memory vaKey,
    string memory which
  ) internal view returns (address) {
    if (keccak256(bytes(which)) == keccak256("share")) {
      return json.readAddress(string.concat(vaKey, ".share"));
    }
    if (keccak256(bytes(which)) == keccak256("asset")) {
      return json.readAddress(string.concat(vaKey, ".asset"));
    }
    revert UnknownToken(which);
  }

  function _route(
    RouteSpec memory s
  ) internal pure returns (RouteRegistry.Route memory route) {
    route = RouteRegistry.Route({enabled: true, rail: _rail(s.rail), endpoint: s.endpoint, dstId: s.destination});
    return route;
  }

  function _rail(
    string memory r
  ) internal pure returns (RouteRegistry.Rail) {
    bytes32 h = keccak256(bytes(r));
    if (h == keccak256("LZ_OFT")) return RouteRegistry.Rail.LZ_OFT;
    if (h == keccak256("CCIP")) return RouteRegistry.Rail.CCIP;
    if (h == keccak256("LOCAL")) return RouteRegistry.Rail.LOCAL;
    if (h == keccak256("STARGATE")) return RouteRegistry.Rail.STARGATE;
    if (h == keccak256("CCIP_SVM")) return RouteRegistry.Rail.CCIP_SVM;
    revert UnknownRail(r);
  }

  function _u32(
    uint256[] memory xs
  ) internal pure returns (uint32[] memory out) {
    out = new uint32[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint32(xs[i]);
    }
    return out;
  }

  function _writeDeployment(
    uint256 chainId,
    address app,
    address factory,
    address implementation,
    address owner,
    uint256 routeCount
  ) internal {
    string memory obj = "deployment";
    obj.serialize("chainId", chainId);
    obj.serialize("app", app);
    obj.serialize("factory", factory);
    obj.serialize("owner", owner);
    obj.serialize("routes", routeCount);
    string memory out = obj.serialize("implementation", implementation);
    string memory path = string.concat("deployments/multibridge/", vm.toString(chainId), ".json");
    out.write(path);
    console2.log("wrote deployment ->", path);
  }
}
