// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title FinishAdapterConfig
 * @notice Step 2b: install CCIP routes on an already-deployed adapter clone (admin must be the broadcaster).
 *         Use when `factory.deploy(...)` succeeded but follow-up txs did not broadcast.
 *
 * @dev export DEPLOYER=$(cast wallet address --account vaultdeployer)
 *      CONFIG=config/multibridge/sepolia.json ADAPTER=0x9371... forge script
 * script/multibridge/sepolia/FinishAdapterConfig.s.sol:FinishAdapterConfig \
 *        --rpc-url $HUB_RPC_URL --account vaultdeployer --broadcast --slow --skip-simulation
 */
contract FinishAdapterConfig is Script {
  using stdJson for string;

  struct RouteSpec {
    uint64 destination;
    address endpoint;
    string rail;
    string token;
  }

  error UnknownRail(string rail);
  error UnknownToken(string token);

  function run() external {
    string memory json = vm.readFile(vm.envOr("CONFIG", string("config/multibridge/sepolia.json")));
    address app = vm.envAddress("ADAPTER");
    string memory vaKey = vm.envOr("VAULT_ADAPTER_KEY", string(".vaultAdapter"));
    string memory routesKey = vm.envOr("ROUTES_KEY", string(".routes"));
    address deployer = vm.envOr("DEPLOYER", msg.sender);
    address realOwner = json.readAddressOr(string.concat(vaKey, ".owner"), address(0));
    if (realOwner == address(0)) realOwner = deployer;

    RouteSpec[] memory routes = _readRoutes(json, routesKey);
    uint32[] memory stargateDstEids =
      _u32(json.readUintArrayOr(string.concat(vaKey, ".stargateDstEids"), new uint256[](0)));
    uint64[] memory ccipDst = _u64(json.readUintArrayOr(string.concat(vaKey, ".ccipDstSelectors"), new uint256[](0)));

    vm.startBroadcast();

    RouteRegistry adapter = RouteRegistry(payable(app));

    for (uint256 i; i < ccipDst.length; ++i) {
      adapter.setCcipDestination(ccipDst[i], true);
    }
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

    console2.log("adapter:  ", app);
    console2.log("admin:    ", realOwner);
    console2.log("routes:   ", routes.length);
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
    if (keccak256(bytes(which)) == keccak256("share")) return json.readAddress(string.concat(vaKey, ".share"));
    if (keccak256(bytes(which)) == keccak256("asset")) return json.readAddress(string.concat(vaKey, ".asset"));
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

  function _u64(
    uint256[] memory xs
  ) internal pure returns (uint64[] memory out) {
    out = new uint64[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint64(xs[i]);
    }
    return out;
  }
}
