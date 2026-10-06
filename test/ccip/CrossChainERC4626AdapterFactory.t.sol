// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CrossChainERC4626AdapterFactory} from "../../src/ccip/CrossChainERC4626AdapterFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouterClient} from "./mocks/MockRouterClient.sol";

contract CrossChainERC4626AdapterFactoryTest is Test {
  uint64 internal constant SOURCE_CHAIN_SELECTOR = 111;
  uint64 internal constant SVM_CHAIN_SELECTOR = 222;

  address internal constant DEFAULT_ADMIN = address(0xA11CE);
  address internal constant FEE_SETTER = address(0xBEEF);
  address internal constant FEE_COLLECTOR = address(0xCAFE);
  address internal constant VAULT_TARGET = address(0x1234);

  MockRouterClient internal s_router;
  MockERC20 internal s_feeAsset;
  CrossChainERC4626AdapterFactory internal s_factory;

  event AdapterDeployed(
    address indexed adapter,
    address indexed router,
    address indexed defaultAdmin,
    address feeSetter,
    address feeCollector,
    address vaultTarget,
    bool targetEnabled,
    bool depositsEnabled,
    bool redeemsEnabled
  );

  function setUp() public {
    s_router = new MockRouterClient();
    s_feeAsset = new MockERC20("Fee Asset", "FEE", 18);
    s_factory = new CrossChainERC4626AdapterFactory();
  }

  function test_factory_typeAndVersion_returns_expected_string() public view {
    assertEq(s_factory.typeAndVersion(), "CrossChainERC4626AdapterFactory 1.0.0");
  }

  function test_deploy_applies_initial_configuration_and_handoffs_roles() public {
    CrossChainERC4626AdapterFactory.ChainConfig[] memory chainConfigs =
      new CrossChainERC4626AdapterFactory.ChainConfig[](2);
    chainConfigs[0] = CrossChainERC4626AdapterFactory.ChainConfig({
      chainSelector: SOURCE_CHAIN_SELECTOR, chainType: CrossChainERC4626Adapter.ChainType.EVM
    });
    chainConfigs[1] = CrossChainERC4626AdapterFactory.ChainConfig({
      chainSelector: SVM_CHAIN_SELECTOR, chainType: CrossChainERC4626Adapter.ChainType.SVM
    });

    CrossChainERC4626AdapterFactory.FeeConfig[] memory feeConfigs = new CrossChainERC4626AdapterFactory.FeeConfig[](2);
    feeConfigs[0] = CrossChainERC4626AdapterFactory.FeeConfig({
      destinationChainSelector: SOURCE_CHAIN_SELECTOR, bridgedToken: address(s_feeAsset), fee: 10 ether
    });
    feeConfigs[1] = CrossChainERC4626AdapterFactory.FeeConfig({
      destinationChainSelector: SVM_CHAIN_SELECTOR, bridgedToken: address(0x9999), fee: 2 ether
    });

    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = CrossChainERC4626AdapterFactory.DeploymentConfig({
      router: address(s_router),
      defaultAdmin: DEFAULT_ADMIN,
      feeSetter: FEE_SETTER,
      feeCollector: FEE_COLLECTOR,
      vaultTarget: VAULT_TARGET,
      targetEnabled: true,
      depositsEnabled: true,
      redeemsEnabled: false,
      chainConfigs: chainConfigs,
      feeConfigs: feeConfigs
    });

    vm.expectEmit(false, true, true, true, address(s_factory));
    emit AdapterDeployed(
      address(0), // not checked
      address(s_router),
      DEFAULT_ADMIN,
      FEE_SETTER,
      FEE_COLLECTOR,
      VAULT_TARGET,
      true,
      true,
      false
    );
    address adapterAddress = s_factory.deploy(config);
    CrossChainERC4626Adapter adapter = CrossChainERC4626Adapter(payable(adapterAddress));

    assertEq(adapter.ROUTER(), address(s_router));
    assertEq(
      uint256(uint8(adapter.chains(SOURCE_CHAIN_SELECTOR))), uint256(uint8(CrossChainERC4626Adapter.ChainType.EVM))
    );
    assertEq(uint256(uint8(adapter.chains(SVM_CHAIN_SELECTOR))), uint256(uint8(CrossChainERC4626Adapter.ChainType.SVM)));
    assertTrue(adapter.enabledTargets(VAULT_TARGET));
    assertTrue(adapter.depositsEnabled());
    assertFalse(adapter.redeemsEnabled());
    assertEq(adapter.assetFees(SOURCE_CHAIN_SELECTOR, address(s_feeAsset)), 10 ether);
    assertEq(adapter.assetFees(SVM_CHAIN_SELECTOR, address(0x9999)), 2 ether);

    assertTrue(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), DEFAULT_ADMIN));
    assertTrue(adapter.hasRole(adapter.FEE_SETTER_ROLE(), FEE_SETTER));
    assertTrue(adapter.hasRole(adapter.FEE_COLLECTOR_ROLE(), FEE_COLLECTOR));

    assertFalse(adapter.hasRole(adapter.DEFAULT_ADMIN_ROLE(), address(s_factory)));
    assertFalse(adapter.hasRole(adapter.FEE_SETTER_ROLE(), address(s_factory)));
    assertFalse(adapter.hasRole(adapter.FEE_COLLECTOR_ROLE(), address(s_factory)));
  }

  function test_deploy_skips_target_configuration_when_target_is_zero() public {
    CrossChainERC4626AdapterFactory.ChainConfig[] memory chainConfigs =
      new CrossChainERC4626AdapterFactory.ChainConfig[](0);
    CrossChainERC4626AdapterFactory.FeeConfig[] memory feeConfigs = new CrossChainERC4626AdapterFactory.FeeConfig[](0);

    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = CrossChainERC4626AdapterFactory.DeploymentConfig({
      router: address(s_router),
      defaultAdmin: DEFAULT_ADMIN,
      feeSetter: FEE_SETTER,
      feeCollector: FEE_COLLECTOR,
      vaultTarget: address(0),
      targetEnabled: false,
      depositsEnabled: false,
      redeemsEnabled: true,
      chainConfigs: chainConfigs,
      feeConfigs: feeConfigs
    });

    CrossChainERC4626Adapter adapter = CrossChainERC4626Adapter(payable(s_factory.deploy(config)));

    assertFalse(adapter.enabledTargets(address(0x1234)));
    assertFalse(adapter.depositsEnabled());
    assertTrue(adapter.redeemsEnabled());
  }

  function test_deploy_bubbles_adapter_constructor_reverts() public {
    CrossChainERC4626AdapterFactory.ChainConfig[] memory chainConfigs =
      new CrossChainERC4626AdapterFactory.ChainConfig[](0);
    CrossChainERC4626AdapterFactory.FeeConfig[] memory feeConfigs = new CrossChainERC4626AdapterFactory.FeeConfig[](0);

    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = CrossChainERC4626AdapterFactory.DeploymentConfig({
      router: address(0),
      defaultAdmin: DEFAULT_ADMIN,
      feeSetter: FEE_SETTER,
      feeCollector: FEE_COLLECTOR,
      vaultTarget: VAULT_TARGET,
      targetEnabled: true,
      depositsEnabled: true,
      redeemsEnabled: true,
      chainConfigs: chainConfigs,
      feeConfigs: feeConfigs
    });

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidRouter.selector, address(0)));
    s_factory.deploy(config);
  }

  function test_deploy_reverts_when_default_admin_is_zero() public {
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = _minimalConfig();
    config.defaultAdmin = address(0);
    vm.expectRevert(CrossChainERC4626Adapter.InvalidAdmin.selector);
    s_factory.deploy(config);
  }

  function test_deploy_reverts_when_fee_setter_is_zero() public {
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = _minimalConfig();
    config.feeSetter = address(0);
    vm.expectRevert(CrossChainERC4626Adapter.InvalidFeeSetter.selector);
    s_factory.deploy(config);
  }

  function test_deploy_reverts_when_fee_collector_is_zero() public {
    CrossChainERC4626AdapterFactory.DeploymentConfig memory config = _minimalConfig();
    config.feeCollector = address(0);
    vm.expectRevert(CrossChainERC4626Adapter.InvalidFeeCollector.selector);
    s_factory.deploy(config);
  }

  function _minimalConfig() private view returns (CrossChainERC4626AdapterFactory.DeploymentConfig memory config) {
    CrossChainERC4626AdapterFactory.ChainConfig[] memory chainConfigs =
      new CrossChainERC4626AdapterFactory.ChainConfig[](0);
    CrossChainERC4626AdapterFactory.FeeConfig[] memory feeConfigs = new CrossChainERC4626AdapterFactory.FeeConfig[](0);
    config = CrossChainERC4626AdapterFactory.DeploymentConfig({
      router: address(s_router),
      defaultAdmin: DEFAULT_ADMIN,
      feeSetter: FEE_SETTER,
      feeCollector: FEE_COLLECTOR,
      vaultTarget: address(0),
      targetEnabled: false,
      depositsEnabled: true,
      redeemsEnabled: true,
      chainConfigs: chainConfigs,
      feeConfigs: feeConfigs
    });
    return config;
  }
}
