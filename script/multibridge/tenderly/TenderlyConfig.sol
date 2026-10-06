// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {ReturnLegFeeConfig} from "../config/ReturnLegFeeConfig.sol";

/**
 * @title TenderlyConfig
 * @notice Shared loader for the Tenderly e2e config (`config/multibridge/tenderly.json`, schema in
 *         `config/multibridge/tenderly.example.json`). Reads the hub/spoke network blocks and turns the `vaultAdapter`
 *         block into a {DeployConfig}. Numbers may be JSON numbers or
 *         0x-hex strings (Foundry preserves full integer precision either way).
 *
 * @dev Read-only helper meant to be inherited by deploy scripts. The config path defaults to
 *      `config/multibridge/tenderly.json` and can be overridden with the `CONFIG` env var.
 */
abstract contract TenderlyConfig is Script, ReturnLegFeeConfig {
  using stdJson for string;

  /// @notice A network (hub or spoke) entry from the config.
  // Already slot-minimal: every address needs its own slot, so the rule's byte-sum bound is unreachable.
  // solhint-disable-next-line gas-struct-packing
  struct Net {
    uint256 chainId;
    address ccipRouter;
    address lzEndpoint;
    uint64 ccipChainSelector;
    uint32 lzEid;
    address factory; // optional: reuse an existing factory (zero => deploy a fresh one)
    address implementation; // optional: reuse a published implementation (zero => deploy one)
  }

  /// @notice Loads the raw config JSON (path from `CONFIG`, default `config/multibridge/tenderly.json`).
  function _loadConfig() internal view returns (string memory json) {
    string memory path = vm.envOr("CONFIG", string("config/multibridge/tenderly.json"));
    return vm.readFile(path);
  }

  /// @notice Reads a network block (`.hub` or `.spoke`) from the config.
  /// @param json The config JSON.
  /// @param key The JSON path to the network object (e.g. `.hub`).
  function _readNet(
    string memory json,
    string memory key
  ) internal view returns (Net memory net) {
    net.chainId = json.readUint(string.concat(key, ".chainId"));
    net.ccipRouter = json.readAddress(string.concat(key, ".ccipRouter"));
    net.lzEndpoint = json.readAddress(string.concat(key, ".lzEndpoint"));
    net.ccipChainSelector = uint64(json.readUint(string.concat(key, ".ccipChainSelector")));
    net.lzEid = uint32(json.readUint(string.concat(key, ".lzEid")));
    net.factory = json.readAddressOr(string.concat(key, ".factory"), address(0));
    net.implementation = json.readAddressOr(string.concat(key, ".implementation"), address(0));
    return net;
  }

  /// @notice Builds the factory {DeployConfig} from the `.vaultAdapter` block plus the hub network.
  function _readDeployConfig(
    string memory json,
    Net memory hub
  ) internal view returns (DeployConfig memory cfg) {
    return _readDeployConfig(json, hub, ".vaultAdapter");
  }

  /// @notice Builds {DeployConfig} from a vault-adapter JSON block (e.g. `.vaultAdapter` or `.vaultAdapterUsdc`).
  function _readDeployConfig(
    string memory json,
    Net memory hub,
    string memory basePath
  ) internal view returns (DeployConfig memory cfg) {
    cfg.ccipRouter = hub.ccipRouter;
    cfg.lzEndpoint = hub.lzEndpoint;
    cfg.owner = json.readAddressOr(string.concat(basePath, ".owner"), address(0));
    cfg.feeCollector = json.readAddressOr(string.concat(basePath, ".feeCollector"), address(0));
    cfg.vault = json.readAddress(string.concat(basePath, ".vault"));
    cfg.lzSrcEids = _toUint32Array(json.readUintArrayOr(string.concat(basePath, ".lzSrcEids"), new uint256[](0)));
    cfg.lzSrcOfts = json.readAddressArrayOr(string.concat(basePath, ".lzSrcOfts"), new address[](0));
    cfg.ccipSrcSelectors =
      _toUint64Array(json.readUintArrayOr(string.concat(basePath, ".ccipSrcSelectors"), new uint256[](0)));
    cfg.ccipDstSelectors =
      _toUint64Array(json.readUintArrayOr(string.concat(basePath, ".ccipDstSelectors"), new uint256[](0)));
    cfg.lzDstEids = _toUint32Array(json.readUintArrayOr(string.concat(basePath, ".lzDstEids"), new uint256[](0)));
    cfg.oftTokens = json.readAddressArrayOr(string.concat(basePath, ".oftTokens"), new address[](0));
    cfg.ofts = json.readAddressArrayOr(string.concat(basePath, ".ofts"), new address[](0));
    address asset = json.readAddress(string.concat(basePath, ".asset"));
    address share = json.readAddress(string.concat(basePath, ".share"));
    cfg = _readReturnLegFees(cfg, json, basePath, asset, share);
    return cfg;
  }

  function _toUint32Array(
    uint256[] memory xs
  ) private pure returns (uint32[] memory out) {
    out = new uint32[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint32(xs[i]);
    }
    return out;
  }

  function _toUint64Array(
    uint256[] memory xs
  ) private pure returns (uint64[] memory out) {
    out = new uint64[](xs.length);
    for (uint256 i; i < xs.length; ++i) {
      out[i] = uint64(xs[i]);
    }
    return out;
  }
}
