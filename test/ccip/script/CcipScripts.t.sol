// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CcipScriptBase} from "../../../script/ccip/CcipScriptBase.sol";
import {CheckCrossChainERC4626AdapterScript} from "../../../script/ccip/CheckCrossChainERC4626Adapter.s.sol";
import {ConfigureCrossChainERC4626AdapterScript} from "../../../script/ccip/ConfigureCrossChainERC4626Adapter.s.sol";
import {
  DeployAndActivateCrossChainERC4626AdapterScript
} from "../../../script/ccip/DeployAndActivateCrossChainERC4626Adapter.s.sol";
import {CrossChainERC4626Adapter} from "../../../src/ccip/CrossChainERC4626Adapter.sol";
import {CrossChainERC4626AdapterFactory} from "../../../src/ccip/CrossChainERC4626AdapterFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockRouterClient} from "../mocks/MockRouterClient.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Runs the CCIP deploy, configure and check scripts end to end against mocks.
/// @dev Env vars are process-global and test functions run in parallel, so every env-driven assertion lives in
/// `test_EnvDrivenDeployConfigureCheck`. The other tests call the struct-based entry points only.
contract CcipScriptsTest is Test {
  uint64 private constant EVM_SELECTOR = 16015286601757825753;
  uint64 private constant SVM_SELECTOR = 16423721717087811551;

  DeployAndActivateCrossChainERC4626AdapterScript internal s_deployScript;
  ConfigureCrossChainERC4626AdapterScript internal s_configureScript;
  CheckCrossChainERC4626AdapterScript internal s_checkScript;
  MockRouterClient internal s_router;
  MockERC20 internal s_asset;
  MockERC4626Vault internal s_vault;
  address internal s_admin;
  address internal s_feeSetter = makeAddr("feeSetter");
  address internal s_feeCollector = makeAddr("feeCollector");

  function setUp() public {
    s_deployScript = new DeployAndActivateCrossChainERC4626AdapterScript();
    s_configureScript = new ConfigureCrossChainERC4626AdapterScript();
    s_checkScript = new CheckCrossChainERC4626AdapterScript();
    s_router = new MockRouterClient();
    s_asset = new MockERC20("USD Coin", "USDC", 6);
    s_vault = new MockERC4626Vault(address(s_asset), "Vault USDC", "vUSDC");
    // `vm.startBroadcast()` inside the scripts sends from forge's default sender, so it is the admin that can run
    // `configure`.
    s_admin = DEFAULT_SENDER;
    vm.deal(s_admin, 10 ether);
  }

  function test_EnvDrivenDeployConfigureCheck() public {
    // Missing and malformed inputs fail with named errors before anything is broadcast.
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "ROUTER"));
    s_deployScript.loadConfig();

    vm.setEnv("ROUTER", vm.toString(address(s_router)));
    vm.setEnv("DEFAULT_ADMIN", vm.toString(s_admin));
    vm.setEnv("FEE_SETTER", vm.toString(s_feeSetter));
    vm.setEnv("FEE_COLLECTOR", vm.toString(s_feeCollector));
    vm.setEnv("VAULT_TARGET", vm.toString(address(s_vault)));
    vm.setEnv("DEPOSITS_ENABLED", "true");
    vm.setEnv("REDEEMS_ENABLED", "false");
    vm.setEnv("CHAIN_SELECTORS", string.concat(vm.toString(EVM_SELECTOR), ",", vm.toString(SVM_SELECTOR)));
    vm.setEnv("CHAIN_TYPES", "1");
    vm.expectRevert(
      abi.encodeWithSelector(CcipScriptBase.ArrayLengthMismatch.selector, "CHAIN_SELECTORS", 2, "CHAIN_TYPES", 1)
    );
    s_deployScript.loadConfig();

    vm.setEnv("CHAIN_TYPES", "1,3");
    vm.expectRevert(
      abi.encodeWithSelector(
        DeployAndActivateCrossChainERC4626AdapterScript.InvalidChainType.selector, SVM_SELECTOR, uint256(3)
      )
    );
    s_deployScript.loadConfig();

    // Deploy: new factory, one vault, two chains, one return-leg fee row. TARGET_ENABLED defaults to true.
    vm.setEnv("CHAIN_TYPES", "1,2");
    vm.setEnv("FEE_DESTINATION_CHAIN_SELECTORS", vm.toString(EVM_SELECTOR));
    vm.setEnv("FEE_BRIDGED_TOKENS", vm.toString(address(s_vault)));
    vm.setEnv("FEE_VALUES", "1000");
    (CrossChainERC4626AdapterFactory factory, CrossChainERC4626Adapter adapter) = s_deployScript.run();

    assertEq(adapter.typeAndVersion(), "CrossChainERC4626Adapter 1.0.0");
    assertEq(adapter.ROUTER(), address(s_router));
    assertTrue(adapter.enabledTargets(address(s_vault)));
    assertTrue(adapter.depositsEnabled());
    assertFalse(adapter.redeemsEnabled());
    assertEq(uint256(adapter.chains(EVM_SELECTOR)), uint256(CrossChainERC4626Adapter.ChainType.EVM));
    assertEq(uint256(adapter.chains(SVM_SELECTOR)), uint256(CrossChainERC4626Adapter.ChainType.SVM));
    assertEq(adapter.assetFees(EVM_SELECTOR, address(s_vault)), 1000);
    assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), s_admin));
    assertTrue(adapter.hasRole(adapter.FEE_SETTER_ROLE(), s_feeSetter));
    assertTrue(adapter.hasRole(adapter.FEE_COLLECTOR_ROLE(), s_feeCollector));
    assertFalse(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(factory)));

    // An unfunded adapter produces a warning in the check report.
    vm.setEnv("ADAPTER", vm.toString(address(adapter)));
    assertGt(s_checkScript.run(), 0, "unfunded adapter warns");

    // Configure: make the EVM lane a CCIP v2 lane with `safe` finality for share returns, set inbound finality and
    // CCVs, and fund the adapter.
    vm.setEnv("RETURN_LANE_SELECTORS", vm.toString(EVM_SELECTOR));
    vm.setEnv("RETURN_LANE_FORMATS", "0");
    vm.expectRevert(
      abi.encodeWithSelector(
        ConfigureCrossChainERC4626AdapterScript.InvalidReturnLaneFormat.selector, EVM_SELECTOR, uint256(0)
      )
    );
    s_configureScript.loadSettings();

    address ccv = makeAddr("ccv");
    vm.setEnv("RETURN_LANE_FORMATS", "2");
    vm.setEnv("RETURN_FINALITY_SELECTORS", vm.toString(EVM_SELECTOR));
    vm.setEnv("RETURN_FINALITY_TOKENS", vm.toString(address(s_vault)));
    vm.setEnv("RETURN_FINALITIES", "0x00010000");
    vm.setEnv("INBOUND_FINALITY_SELECTORS", vm.toString(EVM_SELECTOR));
    vm.setEnv("INBOUND_FINALITIES", "0x00010000");
    vm.setEnv("CCV_SOURCE_SELECTOR", vm.toString(EVM_SELECTOR));
    vm.setEnv("CCV_REQUIRED", vm.toString(ccv));
    vm.setEnv("FUND_NATIVE_WEI", "500000000000000000");
    s_configureScript.run();

    assertEq(
      uint256(adapter.evmReturnExtraArgsFormat(EVM_SELECTOR)),
      uint256(CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.GENERIC_EXTRA_ARGS_V3_BASIC)
    );
    assertEq(adapter.evmReturnRequestedFinality(EVM_SELECTOR, address(s_vault)), bytes4(0x00010000));
    assertEq(adapter.inboundFinality(EVM_SELECTOR), bytes4(0x00010000));
    (address[] memory required,,,) = adapter.getCCVsAndFinalityConfig(EVM_SELECTOR, "");
    assertEq(required.length, 1);
    assertEq(required[0], ccv);
    assertEq(address(adapter).balance, 0.5 ether);

    // The configured, funded adapter checks clean.
    assertEq(s_checkScript.run(), 0, "configured adapter has no warnings");
  }

  function test_Deploy_ReusesExistingFactory() public {
    CrossChainERC4626AdapterFactory existing = new CrossChainERC4626AdapterFactory();
    (CrossChainERC4626AdapterFactory factory, CrossChainERC4626Adapter adapter) =
      s_deployScript.deploy(_config(address(s_router), address(s_vault)), address(existing));
    assertEq(address(factory), address(existing));
    assertEq(adapter.ROUTER(), address(s_router));
  }

  function test_Deploy_RejectsRouterWithoutCode() public {
    address eoa = makeAddr("eoa");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.NoContractCode.selector, "ROUTER", eoa));
    s_deployScript.deploy(_config(eoa, address(s_vault)), address(0));
  }

  function test_Deploy_RejectsNonVaultTarget() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        DeployAndActivateCrossChainERC4626AdapterScript.NotAnErc4626Vault.selector, address(s_asset)
      )
    );
    s_deployScript.deploy(_config(address(s_router), address(s_asset)), address(0));
  }

  function test_Deploy_RejectsWrongFactory() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        DeployAndActivateCrossChainERC4626AdapterScript.NotACrossChainERC4626AdapterFactory.selector, address(s_vault)
      )
    );
    s_deployScript.deploy(_config(address(s_router), address(s_vault)), address(s_vault));
  }

  function test_Configure_RejectsNonAdapter() public {
    ConfigureCrossChainERC4626AdapterScript.Settings memory settings;
    vm.expectRevert(
      abi.encodeWithSelector(
        ConfigureCrossChainERC4626AdapterScript.NotACrossChainERC4626Adapter.selector, address(s_vault)
      )
    );
    s_configureScript.configure(CrossChainERC4626Adapter(payable(address(s_vault))), settings);
  }

  function _config(
    address router,
    address vault
  ) private view returns (CrossChainERC4626AdapterFactory.DeploymentConfig memory config) {
    config.router = router;
    config.defaultAdmin = s_admin;
    config.feeSetter = s_feeSetter;
    config.feeCollector = s_feeCollector;
    config.vaultTarget = vault;
    config.targetEnabled = true;
    config.depositsEnabled = true;
    config.redeemsEnabled = true;
    return config;
  }
}
