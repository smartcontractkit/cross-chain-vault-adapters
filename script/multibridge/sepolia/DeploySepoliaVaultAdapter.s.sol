// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapterFactory} from "../../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {TenderlyConfig} from "../tenderly/TenderlyConfig.sol";

/**
 * @title DeploySepoliaVaultAdapter
 * @notice Deploy + fully configure a {CrossChainVaultAdapter} on Ethereum Sepolia for the production
 *         vault at `config/multibridge/sepolia.json`. Installs inbound Stargate + USDT0 allowlists, CCIP outbound
 *         destinations (Arbitrum Sepolia + Base Sepolia), and share-token CCIP routes.
 *
 * @dev Run on Ethereum Sepolia (deploy + Etherscan verify in one call):
 *   export HUB_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com
 *   export ETHERSCAN_API_KEY=...
 *   bash script/multibridge/deploy-sepolia.sh
 *
 *   Or manually:
 *   CONFIG=config/multibridge/sepolia.json forge script
 * script/multibridge/sepolia/DeploySepoliaVaultAdapter.s.sol:DeploySepoliaVaultAdapter \
 *     --rpc-url $HUB_RPC_URL --account vaultdeployer --broadcast --slow --verify
 *
 *   Verify an existing broadcast without resending txs:
 *   VERIFY_ONLY=1 bash script/multibridge/deploy-sepolia.sh
 */
contract DeploySepoliaVaultAdapter is TenderlyConfig {
  using stdJson for string;

  /// @dev Field order is alphabetical for `vm.parseJson` ABI decoding.
  struct RouteSpec {
    uint64 destination;
    address endpoint;
    string rail;
    string token;
  }

  error UnknownRail(string rail);
  error UnknownToken(string token);

  function run() external returns (address app, address factory, address implementation) {
    string memory json = _loadConfig();
    TenderlyConfig.Net memory hub = _readNet(json, ".hub");
    vm.createSelectFork(vm.envOr("HUB_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));

    // With `--account` / `--private-key`, the broadcaster is NOT `msg.sender` during simulation
    // (Foundry uses DefaultSender). Set DEPLOYER to the broadcasting address — see
    // script/multibridge/deploy-sepolia.sh (same pattern as DeployProduction).
    address deployer = vm.envOr("DEPLOYER", msg.sender);
    address realOwner = json.readAddressOr(".vaultAdapter.owner", address(0));
    if (realOwner == address(0)) realOwner = deployer;

    DeployConfig memory cfg = _readDeployConfig(json, hub);
    cfg.owner = deployer;

    uint256 fundWei = json.readUint(".vaultAdapter.fundWei");
    RouteSpec[] memory routes = _readRoutes(json);
    uint32[] memory stargateDstEids = _u32(json.readUintArrayOr(".vaultAdapter.stargateDstEids", new uint256[](0)));

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

    RouteRegistry adapter = RouteRegistry(payable(app));

    for (uint256 i; i < stargateDstEids.length; ++i) {
      adapter.setStargateDestination(stargateDstEids[i], true);
    }
    for (uint256 i; i < routes.length; ++i) {
      adapter.setRoute(_token(json, routes[i].token), routes[i].destination, _route(routes[i]));
    }

    if (realOwner != deployer) {
      adapter.transferAdmin(realOwner, realOwner, realOwner);
    }

    vm.stopBroadcast();

    _writeDeployment(hub.chainId, app, factory, implementation, realOwner, routes.length);

    console2.log("network chainId:   ", hub.chainId);
    console2.log("implementation:    ", implementation);
    console2.log("factory:           ", factory);
    console2.log("vault adapter:     ", app);
    console2.log("routes installed:  ", routes.length);
    console2.log("admin:             ", realOwner);
    return (app, factory, implementation);
  }

  function _readRoutes(
    string memory json
  ) internal pure returns (RouteSpec[] memory specs) {
    bytes memory raw = vm.parseJson(json, ".routes");
    specs = abi.decode(raw, (RouteSpec[]));
    return specs;
  }

  function _token(
    string memory json,
    string memory which
  ) internal view returns (address) {
    if (keccak256(bytes(which)) == keccak256("share")) return json.readAddress(".vaultAdapter.share");
    if (keccak256(bytes(which)) == keccak256("asset")) return json.readAddress(".vaultAdapter.asset");
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
