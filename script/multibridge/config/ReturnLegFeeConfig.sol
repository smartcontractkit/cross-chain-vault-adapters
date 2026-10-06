// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {DeployConfig} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";

/**
 * @title ReturnLegFeeConfig
 * @notice Shared JSON loader for return-leg fee fields in {DeployConfig}. Parses `inboundFees[]`
 *         entries with `outboundToken` = `"asset"` | `"share"` (same convention as production routes).
 */
abstract contract ReturnLegFeeConfig is Script {
  using stdJson for string;

  /// @dev Field order is alphabetical for `vm.parseJson` ABI decoding.
  struct InboundFeeSpec {
    uint64 destination;
    uint256 fee;
    string outboundToken;
  }

  error UnknownOutboundToken(string token);

  /// @notice Fills `requireLzReturnPrefunded` and parallel `inboundFee*` arrays on `cfg`.
  /// @param json Full config JSON.
  /// @param basePath JSON prefix (e.g. `.vaultAdapter` or `.returnLegFees`).
  /// @param asset The vault underlying (`s_asset`).
  /// @param share The vault share token (ERC-4626: same as vault address).
  function _readReturnLegFees(
    DeployConfig memory cfg,
    string memory json,
    string memory basePath,
    address asset,
    address share
  ) internal view returns (DeployConfig memory) {
    string memory reqPath = string.concat(basePath, ".requireLzReturnPrefunded");
    cfg.requireLzReturnPrefunded = json.readBoolOr(reqPath, false);

    string memory feesPath = string.concat(basePath, ".inboundFees");
    if (!json.keyExists(feesPath)) {
      cfg.inboundFeeOutboundTokens = new address[](0);
      cfg.inboundFeeDestinations = new uint64[](0);
      cfg.inboundFeeAmounts = new uint256[](0);
      return cfg;
    }

    bytes memory raw = vm.parseJson(json, feesPath);
    InboundFeeSpec[] memory specs = abi.decode(raw, (InboundFeeSpec[]));
    uint256 n = specs.length;
    cfg.inboundFeeOutboundTokens = new address[](n);
    cfg.inboundFeeDestinations = new uint64[](n);
    cfg.inboundFeeAmounts = new uint256[](n);
    for (uint256 i; i < n; ++i) {
      cfg.inboundFeeOutboundTokens[i] = _outboundToken(specs[i].outboundToken, asset, share);
      cfg.inboundFeeDestinations[i] = specs[i].destination;
      cfg.inboundFeeAmounts[i] = specs[i].fee;
    }
    return cfg;
  }

  function _outboundToken(
    string memory which,
    address asset,
    address share
  ) internal pure returns (address) {
    bytes32 h = keccak256(bytes(which));
    if (h == keccak256("share")) return share;
    if (h == keccak256("asset")) return asset;
    revert UnknownOutboundToken(which);
  }
}
