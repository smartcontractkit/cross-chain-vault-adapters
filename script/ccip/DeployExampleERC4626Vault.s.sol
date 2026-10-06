// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {ExampleERC4626Vault} from "../../src/ccip/dev/ExampleERC4626Vault.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {IERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Deploys `ExampleERC4626Vault`, an unaudited OpenZeppelin ERC-4626 vault for testnet tutorials.
/// @dev Fill in `.env` at the repo root (see `.env.example`), then:
/// pnpm ccip:deploy-example-vault --rpc-url ccip --account deployer --broadcast --verify
///
/// Required env vars: `VAULT_ASSET` (the underlying token), `VAULT_NAME`, `VAULT_SYMBOL`.
/// Optional env vars: `VAULT_OWNER` (default: the broadcaster).
contract DeployExampleERC4626VaultScript is CcipScriptBase {
  /// @notice Reads the env vars, deploys the vault and logs its address.
  function run() external returns (ExampleERC4626Vault vault) {
    address asset = _requireAddress("VAULT_ASSET");
    _requireCode("VAULT_ASSET", asset);
    string memory name = _requireString("VAULT_NAME");
    string memory symbol = _requireString("VAULT_SYMBOL");
    address owner = _optionalAddress("VAULT_OWNER");

    vm.startBroadcast();
    if (owner == address(0)) (, owner,) = vm.readCallers();
    vault = new ExampleERC4626Vault(IERC20(asset), name, symbol, owner);
    vm.stopBroadcast();

    console2.log("ExampleERC4626Vault:", address(vault));
    console2.log("Asset:              ", asset);
    console2.log("Name / symbol:      ", vault.name(), vault.symbol());
    console2.log("Decimals:           ", vault.decimals());
    console2.log("Owner:              ", vault.owner());
    return vault;
  }

  function _requireString(
    string memory name
  ) private view returns (string memory value) {
    if (!_isSet(name)) revert MissingEnv(name);
    return vm.envString(name);
  }
}
