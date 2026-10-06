// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {Script} from "forge-std/Script.sol";

/**
 * @title SyncInboundLz
 * @notice Idempotently apply `vaultAdapter.lzSrcEids` / `lzSrcOfts` from config onto a live adapter.
 *         Run after adding a new spoke (e.g. BSC testnet EID 40102) without redeploying the clone.
 *
 * @dev export ADAPTER=0x9371...
 *      CONFIG=config/multibridge/sepolia.json bash script/multibridge/sync-inbound-lz-sepolia.sh
 */
contract SyncInboundLz is Script {
  using stdJson for string;

  error LzSrcLengthMismatch(uint256 eids, uint256 ofts);

  function run() external {
    string memory json = vm.readFile(vm.envOr("CONFIG", string("config/multibridge/sepolia.json")));
    address app = vm.envAddress("ADAPTER");

    uint32[] memory eids = _u32(json.readUintArray(".vaultAdapter.lzSrcEids"));
    address[] memory ofts = json.readAddressArray(".vaultAdapter.lzSrcOfts");
    if (eids.length != ofts.length) revert LzSrcLengthMismatch(eids.length, ofts.length);

    RouteRegistry adapter = RouteRegistry(payable(app));

    vm.startBroadcast();

    uint256 enabled;
    for (uint256 i; i < eids.length; ++i) {
      if (!adapter.s_lzOftAllowed(eids[i], ofts[i])) {
        adapter.setLzOft(eids[i], ofts[i], true);
        console2.log("setLzOft", eids[i], ofts[i]);
        ++enabled;
      } else {
        console2.log("skip (already allowed)", eids[i], ofts[i]);
      }
    }

    vm.stopBroadcast();

    console2.log("adapter:", app);
    console2.log("new allowlists:", enabled);
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
}
