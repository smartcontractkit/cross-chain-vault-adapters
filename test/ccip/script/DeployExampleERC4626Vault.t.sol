// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CcipScriptBase} from "../../../script/ccip/CcipScriptBase.sol";
import {DeployExampleERC4626VaultScript} from "../../../script/ccip/DeployExampleERC4626Vault.s.sol";
import {ExampleERC4626Vault} from "../../../src/ccip/dev/ExampleERC4626Vault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Runs the example vault deploy script against a mock asset.
/// @dev Env vars are process-global and test functions run in parallel, so every env-driven assertion lives in one
/// test.
contract DeployExampleERC4626VaultScriptTest is Test {
  function test_EnvDrivenDeploy() public {
    DeployExampleERC4626VaultScript script = new DeployExampleERC4626VaultScript();
    MockERC20 asset = new MockERC20("CCIP-BnM", "CCIP-BnM", 18);

    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "VAULT_ASSET"));
    script.run();

    address eoa = makeAddr("eoa");
    vm.setEnv("VAULT_ASSET", vm.toString(eoa));
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.NoContractCode.selector, "VAULT_ASSET", eoa));
    script.run();

    vm.setEnv("VAULT_ASSET", vm.toString(address(asset)));
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "VAULT_NAME"));
    script.run();

    vm.setEnv("VAULT_NAME", "Vault CCIP-BnM");
    vm.setEnv("VAULT_SYMBOL", "vCCIP-BnM");
    ExampleERC4626Vault vault = script.run();
    assertEq(vault.asset(), address(asset));
    assertEq(vault.name(), "Vault CCIP-BnM");
    assertEq(vault.symbol(), "vCCIP-BnM");
    assertEq(vault.decimals(), 18);
    // Without VAULT_OWNER, the broadcaster (forge's default sender in tests) owns the vault.
    assertEq(vault.owner(), DEFAULT_SENDER);

    address owner = makeAddr("owner");
    vm.setEnv("VAULT_OWNER", vm.toString(owner));
    assertEq(script.run().owner(), owner);
  }
}
