// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {ReturnLegFeeConfig} from "../config/ReturnLegFeeConfig.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title SyncHubConfig
 * @notice Idempotently sync hub adapter allowlists + route registry from `config/multibridge/sepolia.json`.
 *         Covers inbound LZ, inbound CCIP, outbound CCIP/Stargate dests, routes[], and return-leg fees
 *         (`requireLzReturnPrefunded`, `inboundFees[]`).
 *
 * @dev export ADAPTER=0x9371...
 *      CONFIG=config/multibridge/sepolia.json bash script/multibridge/sync-hub-config-sepolia.sh
 */
contract SyncHubConfig is Script, ReturnLegFeeConfig {
  using stdJson for string;

  struct RouteSpec {
    uint64 destination;
    address endpoint;
    string rail;
    string token;
  }

  error UnknownRail(string rail);
  error UnknownToken(string token);
  error LzSrcLengthMismatch(uint256 eids, uint256 ofts);
  error RevokeLzLengthMismatch(uint256 eids, uint256 ofts);

  function run() external {
    string memory json = vm.readFile(vm.envOr("CONFIG", string("config/multibridge/sepolia.json")));
    address app = vm.envAddress("ADAPTER");
    string memory vaKey = vm.envOr("VAULT_ADAPTER_KEY", string(".vaultAdapter"));
    string memory routesKey = vm.envOr("ROUTES_KEY", string(".routes"));

    uint32[] memory lzEids = _u32(json.readUintArray(string.concat(vaKey, ".lzSrcEids")));
    address[] memory lzOfts = json.readAddressArray(string.concat(vaKey, ".lzSrcOfts"));
    if (lzEids.length != lzOfts.length) revert LzSrcLengthMismatch(lzEids.length, lzOfts.length);

    uint64[] memory ccipSrc = _u64(json.readUintArray(string.concat(vaKey, ".ccipSrcSelectors")));

    uint64[] memory ccipDst = _u64(json.readUintArray(string.concat(vaKey, ".ccipDstSelectors")));
    uint32[] memory stargateDst = _u32(json.readUintArrayOr(string.concat(vaKey, ".stargateDstEids"), new uint256[](0)));
    RouteSpec[] memory routes = _readRoutes(json, routesKey);
    bool ccipOnly = vm.envOr("CCIP_ONLY", false);

    RouteRegistry adapter = RouteRegistry(payable(app));

    vm.startBroadcast();

    if (ccipOnly) {
      _revokeLz(json, vaKey, adapter);
      _revokeStargate(json, vaKey, adapter);
      _revokeCcip(json, vaKey, adapter);
    }

    if (!ccipOnly) {
      for (uint256 i; i < lzEids.length; ++i) {
        if (!adapter.s_lzOftAllowed(lzEids[i], lzOfts[i])) {
          adapter.setLzOft(lzEids[i], lzOfts[i], true);
          console2.log("setLzOft", lzEids[i], lzOfts[i]);
        }
      }
    }

    for (uint256 i; i < ccipSrc.length; ++i) {
      if (!adapter.s_ccipSourceAllowed(ccipSrc[i])) {
        adapter.setCcipSource(ccipSrc[i], true);
        console2.log("setCcipSource selector", ccipSrc[i]);
      }
    }

    for (uint256 i; i < ccipDst.length; ++i) {
      if (!adapter.s_ccipDestAllowed(ccipDst[i])) {
        adapter.setCcipDestination(ccipDst[i], true);
        console2.log("setCcipDestination", ccipDst[i]);
      }
    }

    if (!ccipOnly) {
      for (uint256 i; i < stargateDst.length; ++i) {
        if (!adapter.s_stargateDestAllowed(stargateDst[i])) {
          adapter.setStargateDestination(stargateDst[i], true);
          console2.log("setStargateDestination", stargateDst[i]);
        }
      }
    }

    for (uint256 i; i < routes.length; ++i) {
      adapter.setRoute(_token(json, vaKey, routes[i].token), routes[i].destination, _route(routes[i]));
      console2.log("setRoute", routes[i].token, routes[i].destination, routes[i].rail);
    }

    _syncReturnLegFees(json, vaKey, app);

    vm.stopBroadcast();

    console2.log("adapter:", app);
    console2.log("routes installed:", routes.length);
  }

  function _syncReturnLegFees(
    string memory json,
    string memory vaKey,
    address app
  ) internal {
    CrossChainVaultAdapter vault = CrossChainVaultAdapter(payable(app));
    address asset = json.readAddress(string.concat(vaKey, ".asset"));
    address share = json.readAddress(string.concat(vaKey, ".share"));

    bool required = json.readBoolOr(string.concat(vaKey, ".requireLzReturnPrefunded"), false);
    if (vault.s_requireLzReturnPrefunded() != required) {
      vault.setRequireLzReturnPrefunded(required);
      console2.log("setRequireLzReturnPrefunded", required);
    }

    string memory feesPath = string.concat(vaKey, ".inboundFees");
    if (!json.keyExists(feesPath)) return;

    bytes memory raw = vm.parseJson(json, feesPath);
    InboundFeeSpec[] memory specs = abi.decode(raw, (InboundFeeSpec[]));
    for (uint256 i; i < specs.length; ++i) {
      address outbound = _outboundToken(specs[i].outboundToken, asset, share);
      uint64 destination = specs[i].destination;
      uint256 fee = specs[i].fee;
      if (vault.s_inboundFees(outbound, destination) != fee) {
        vault.setInboundFee(outbound, destination, fee);
        console2.log("setInboundFee", outbound, destination, fee);
      }
    }
  }

  function _revokeLz(
    string memory json,
    string memory vaKey,
    RouteRegistry adapter
  ) internal {
    uint32[] memory eids = _u32(json.readUintArrayOr(string.concat(vaKey, ".revokeLzEids"), new uint256[](0)));
    address[] memory ofts = json.readAddressArrayOr(string.concat(vaKey, ".revokeLzOfts"), new address[](0));
    if (eids.length != ofts.length) revert RevokeLzLengthMismatch(eids.length, ofts.length);
    for (uint256 i; i < eids.length; ++i) {
      if (adapter.s_lzOftAllowed(eids[i], ofts[i])) {
        adapter.setLzOft(eids[i], ofts[i], false);
        console2.log("revokeLzOft", eids[i], ofts[i]);
      }
    }
  }

  function _revokeCcip(
    string memory json,
    string memory vaKey,
    RouteRegistry adapter
  ) internal {
    uint64[] memory revokeSrc =
      _u64(json.readUintArrayOr(string.concat(vaKey, ".revokeCcipSrcSelectors"), new uint256[](0)));
    uint64[] memory revokeDst =
      _u64(json.readUintArrayOr(string.concat(vaKey, ".revokeCcipDstSelectors"), new uint256[](0)));
    for (uint256 i; i < revokeSrc.length; ++i) {
      if (adapter.s_ccipSourceAllowed(revokeSrc[i])) {
        adapter.setCcipSource(revokeSrc[i], false);
        console2.log("revokeCcipSource", revokeSrc[i]);
      }
    }
    for (uint256 i; i < revokeDst.length; ++i) {
      if (adapter.s_ccipDestAllowed(revokeDst[i])) {
        adapter.setCcipDestination(revokeDst[i], false);
        console2.log("revokeCcipDestination", revokeDst[i]);
      }
    }
  }

  function _revokeStargate(
    string memory json,
    string memory vaKey,
    RouteRegistry adapter
  ) internal {
    uint32[] memory eids = _u32(json.readUintArrayOr(string.concat(vaKey, ".revokeStargateDstEids"), new uint256[](0)));
    for (uint256 i; i < eids.length; ++i) {
      if (adapter.s_stargateDestAllowed(eids[i])) {
        adapter.setStargateDestination(eids[i], false);
        console2.log("revokeStargateDestination", eids[i]);
      }
    }
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
