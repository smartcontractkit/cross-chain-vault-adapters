// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Read-only report of a deployed `CrossChainERC4626Adapter`, using the same `.env` as the deploy script, with
/// warnings for common misconfigurations. Sends no transactions.
/// @dev pnpm ccip:check --rpc-url $RPC_URL
///
/// Uses `ADAPTER`, or the `adapter` field of `deployments/ccip/<chainId>.json` when `ADAPTER` is unset. Reports
/// roles for `DEFAULT_ADMIN` / `FEE_SETTER` / `FEE_COLLECTOR`, the vault in `VAULT_TARGET`, and per-chain settings for
/// `CHAIN_SELECTORS`, when those are set.
contract CheckCrossChainERC4626AdapterScript is CcipScriptBase {
  using stdJson for string;

  error AdapterNotFound(string hint);

  /// @notice Prints the report and returns the number of warnings.
  function run() external view returns (uint256 warnings) {
    return check(CrossChainERC4626Adapter(payable(_resolveAdapter())));
  }

  /// @notice Prints the report for `adapter` and returns the number of warnings.
  function check(
    CrossChainERC4626Adapter adapter
  ) public view returns (uint256 warnings) {
    _requireCode("ADAPTER", address(adapter));
    console2.log("Adapter:           ", address(adapter));
    console2.log("typeAndVersion:    ", adapter.typeAndVersion());
    console2.log("Router:            ", adapter.ROUTER());
    console2.log("Deposits enabled:  ", adapter.depositsEnabled());
    console2.log("Redeems enabled:   ", adapter.redeemsEnabled());
    console2.log("Native balance:    ", address(adapter).balance);
    if (!adapter.depositsEnabled() && !adapter.redeemsEnabled()) {
      warnings += _warn("deposits and redeems are disabled");
    }
    if (address(adapter).balance == 0) warnings += _warn("no native balance: return legs will revert until funded");

    warnings += _checkRoles(adapter);
    address vault = _optionalAddress("VAULT_TARGET");
    if (vault != address(0)) warnings += _checkVault(adapter, vault);
    warnings += _checkChains(adapter, vault);

    console2.log("");
    console2.log("Warnings:          ", warnings);
    return warnings;
  }

  function _checkRoles(
    CrossChainERC4626Adapter adapter
  ) private view returns (uint256 warnings) {
    warnings += _checkRole(adapter, "DEFAULT_ADMIN", adapter.DEFAULT_ADMIN_ROLE());
    warnings += _checkRole(adapter, "FEE_SETTER", adapter.FEE_SETTER_ROLE());
    warnings += _checkRole(adapter, "FEE_COLLECTOR", adapter.FEE_COLLECTOR_ROLE());
    return warnings;
  }

  function _checkRole(
    CrossChainERC4626Adapter adapter,
    string memory envName,
    bytes32 role
  ) private view returns (uint256 warnings) {
    address account = _optionalAddress(envName);
    if (account == address(0)) return 0;
    bool held = adapter.hasRole(role, account);
    console2.log(string.concat(envName, " holds role:"), account, held);
    return held ? 0 : _warn(string.concat(envName, " does not hold its role"));
  }

  function _checkVault(
    CrossChainERC4626Adapter adapter,
    address vault
  ) private view returns (uint256 warnings) {
    bool enabled = adapter.enabledTargets(vault);
    console2.log("Vault target:      ", vault, enabled);
    (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("asset()"));
    if (ok && data.length == 32) console2.log("Vault asset:       ", abi.decode(data, (address)));
    else warnings += _warn("VAULT_TARGET does not answer asset()");
    if (!enabled) warnings += _warn("VAULT_TARGET is not enabled on the adapter");
    return warnings;
  }

  function _checkChains(
    CrossChainERC4626Adapter adapter,
    address vault
  ) private view returns (uint256 warnings) {
    uint256[] memory selectors = _uintArray("CHAIN_SELECTORS");
    address asset;
    if (vault != address(0)) {
      (bool ok, bytes memory data) = vault.staticcall(abi.encodeWithSignature("asset()"));
      if (ok && data.length == 32) asset = abi.decode(data, (address));
    }
    for (uint256 i = 0; i < selectors.length; ++i) {
      uint64 selector = _toUint64("CHAIN_SELECTORS", selectors[i]);
      CrossChainERC4626Adapter.ChainType chainType = adapter.chains(selector);
      console2.log("");
      console2.log("Chain selector:    ", selector);
      console2.log("  chain type:      ", _chainTypeName(chainType));
      if (chainType == CrossChainERC4626Adapter.ChainType.NONE) {
        warnings += _warn("chain selector is not enabled (chain type NONE)");
        continue;
      }
      if (chainType == CrossChainERC4626Adapter.ChainType.EVM) {
        console2.log("  return format:   ", _formatName(adapter.evmReturnExtraArgsFormat(selector)));
      }
      console2.log("  inbound finality:", vm.toString(abi.encodePacked(adapter.inboundFinality(selector))));
      if (vault != address(0)) {
        console2.log("  fee (share out): ", adapter.assetFees(selector, vault));
        if (asset != address(0)) console2.log("  fee (asset out): ", adapter.assetFees(selector, asset));
      }
    }
    return warnings;
  }

  function _resolveAdapter() private view returns (address adapter) {
    adapter = _optionalAddress("ADAPTER");
    if (adapter != address(0)) return adapter;
    string memory path = string.concat("deployments/ccip/", vm.toString(block.chainid), ".json");
    if (!vm.exists(path)) revert AdapterNotFound(string.concat("set ADAPTER or deploy first (", path, ")"));
    return vm.readFile(path).readAddress(".adapter");
  }

  function _warn(
    string memory message
  ) private pure returns (uint256) {
    console2.log(string.concat("WARNING: ", message));
    return 1;
  }

  function _chainTypeName(
    CrossChainERC4626Adapter.ChainType chainType
  ) private pure returns (string memory) {
    if (chainType == CrossChainERC4626Adapter.ChainType.EVM) return "EVM";
    if (chainType == CrossChainERC4626Adapter.ChainType.SVM) return "SVM";
    return "NONE";
  }

  function _formatName(
    CrossChainERC4626Adapter.EvmReturnExtraArgsFormat format
  ) private pure returns (string memory) {
    if (format == CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.GENERIC_EXTRA_ARGS_V3_BASIC) {
      return "GenericExtraArgsV3 basic (CCIP v2 lane)";
    }
    if (format == CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.LEGACY_EXTRA_ARGS_V2) {
      return "GenericExtraArgsV2 (CCIP v1 lane)";
    }
    return "unset (encodes as GenericExtraArgsV2, CCIP v1 lane)";
  }
}
