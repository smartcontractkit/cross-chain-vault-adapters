// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CrossChainVaultAdapterFactory} from "../../../src/multibridge/CrossChainVaultAdapterFactory.sol";
import {DeployConfig, VaultAdapterFactoryBase} from "../../../src/multibridge/VaultAdapterFactoryBase.sol";
import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockOFT} from "../mocks/MockOFT.sol";

/// @notice Tests the factory: one-call deploy + activate (config + funding + ownership hand-off),
///         and that the deployed app is immediately operational.
contract CrossChainVaultAdapterFactoryTest is Test {
  CrossChainVaultAdapterFactory internal s_factory;
  MockERC20 internal s_asset;
  MockERC4626 internal s_vault;
  MockOFT internal s_oftAsset;
  MockOFT internal s_oftShare;
  MockCcipRouter internal s_ccipRouter;

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");
  address internal s_srcUser = makeAddr("srcUser");
  address internal s_user = makeAddr("user");

  uint32 internal constant SRC_EID = 30_101;
  uint32 internal constant DST_EID = 30_110;
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;
  uint64 internal constant DST_SELECTOR = 4_949_039_107_694_359_620;

  function setUp() public {
    s_asset = new MockERC20("USD Tether", "USDT", 18);
    s_vault = new MockERC4626(IERC20(address(s_asset)), "Vault USDT", "vUSDT");
    s_oftAsset = new MockOFT(address(s_asset), 6);
    s_oftShare = new MockOFT(address(s_vault), 6);
    s_ccipRouter = new MockCcipRouter();
    CrossChainVaultAdapter implementation = new CrossChainVaultAdapter();
    s_factory = new CrossChainVaultAdapterFactory(address(implementation));

    // Seed the vault so it is never empty.
    s_asset.mint(address(this), 1000e18);
    s_asset.approve(address(s_vault), 1000e18);
    s_vault.deposit(1000e18, address(this));
  }

  function _config() internal view returns (DeployConfig memory cfg) {
    cfg = _baseConfig();
    cfg.requireLzReturnPrefunded = false;
    return cfg;
  }

  function _configWithFees() internal view returns (DeployConfig memory cfg) {
    cfg = _baseConfig();
    cfg.requireLzReturnPrefunded = true;
    cfg.inboundFeeOutboundTokens = _feeTokens();
    cfg.inboundFeeDestinations = _feeDests();
    cfg.inboundFeeAmounts = _feeAmounts();
    return cfg;
  }

  function _baseConfig() internal view returns (DeployConfig memory cfg) {
    uint32[] memory lzSrcEids = new uint32[](1);
    lzSrcEids[0] = SRC_EID;
    address[] memory lzSrcOfts = new address[](1);
    lzSrcOfts[0] = address(s_oftAsset);

    uint64[] memory ccipSrcSelectors = new uint64[](1);
    ccipSrcSelectors[0] = SRC_SELECTOR;

    uint64[] memory ccipDstSelectors = new uint64[](1);
    ccipDstSelectors[0] = DST_SELECTOR;
    uint32[] memory lzDstEids = new uint32[](1);
    lzDstEids[0] = DST_EID;

    address[] memory oftTokens = new address[](2);
    oftTokens[0] = address(s_asset);
    oftTokens[1] = address(s_vault);
    address[] memory ofts = new address[](2);
    ofts[0] = address(s_oftAsset);
    ofts[1] = address(s_oftShare);

    cfg = DeployConfig({
      ccipRouter: address(s_ccipRouter),
      lzEndpoint: s_lzEndpoint,
      owner: s_owner,
      feeCollector: address(0),
      vault: address(s_vault),
      lzSrcEids: lzSrcEids,
      lzSrcOfts: lzSrcOfts,
      ccipSrcSelectors: ccipSrcSelectors,
      ccipDstSelectors: ccipDstSelectors,
      lzDstEids: lzDstEids,
      oftTokens: oftTokens,
      ofts: ofts,
      requireLzReturnPrefunded: false,
      inboundFeeOutboundTokens: new address[](0),
      inboundFeeDestinations: new uint64[](0),
      inboundFeeAmounts: new uint256[](0)
    });
    return cfg;
  }

  function _feeTokens() internal view returns (address[] memory t) {
    t = new address[](1);
    t[0] = address(s_vault);
    return t;
  }

  function _feeDests() internal pure returns (uint64[] memory d) {
    d = new uint64[](1);
    d[0] = SRC_SELECTOR;
    return d;
  }

  function _feeAmounts() internal pure returns (uint256[] memory a) {
    a = new uint256[](1);
    a[0] = 1e18;
    return a;
  }

  function test_Deploy_ConfiguresFundsAndHandsOffOwnership() public {
    CrossChainVaultAdapter app = CrossChainVaultAdapter(payable(s_factory.deploy{value: 10 ether}(_configWithFees())));

    // Wiring.
    assertEq(address(app.s_vault()), address(s_vault), "vault");
    assertEq(app.s_asset(), address(s_asset), "asset");
    assertEq(app.getRouter(), address(s_ccipRouter), "ccip router");
    assertEq(app.s_lzEndpoint(), s_lzEndpoint, "lz endpoint");

    // Config installed.
    assertTrue(app.s_lzOftAllowed(SRC_EID, address(s_oftAsset)), "lz src");
    assertTrue(app.s_ccipSourceAllowed(SRC_SELECTOR), "ccip src");
    assertTrue(app.s_ccipDestAllowed(DST_SELECTOR), "ccip dst");
    assertTrue(app.s_lzDestAllowed(DST_EID), "lz dst");
    assertEq(app.s_oftForToken(address(s_asset)), address(s_oftAsset), "oft asset");
    assertEq(app.s_oftForToken(address(s_vault)), address(s_oftShare), "oft share");
    assertTrue(app.s_requireLzReturnPrefunded(), "lz prefund policy");
    assertEq(app.s_inboundFees(address(s_vault), SRC_SELECTOR), 1e18, "inbound fee");

    // Funded.
    assertEq(address(app).balance, 10 ether, "funded");

    // Admin handed to `owner`; factory retains no roles.
    assertTrue(app.hasRole(app.DEFAULT_ADMIN_ROLE(), s_owner), "owner is admin");
    assertTrue(app.hasRole(app.FEE_SETTER_ROLE(), s_owner), "owner is fee setter");
    assertTrue(app.hasRole(app.FEE_COLLECTOR_ROLE(), s_owner), "owner is fee collector");
    assertFalse(app.hasRole(app.DEFAULT_ADMIN_ROLE(), address(s_factory)), "factory not admin");
    assertFalse(app.hasRole(app.FEE_SETTER_ROLE(), address(s_factory)), "factory not fee setter");
  }

  function test_DeployedApp_IsImmediatelyOperational() public {
    s_ccipRouter.setFee(0.01 ether);
    CrossChainVaultAdapter app = CrossChainVaultAdapter(payable(s_factory.deploy{value: 10 ether}(_config())));

    // Drive a deposit (asset in via LayerZero -> shares out via CCIP) through the deployed app.
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);
    bytes memory message = abi.encode(
      CrossChainVaultAdapter.VaultMessage({
        minAmountOut: 0,
        destination: DST_SELECTOR, // CCIP selector (> uint32.max)
        recipient: bytes32(uint256(uint160(s_user))),
        failedMessageHandler: address(0),
        onlyLocalRefund: false
      })
    );

    s_asset.mint(address(app), amount); // OFT credits the underlying before lzCompose
    bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(s_srcUser))), message);
    bytes memory lzMsg = OFTComposeMsgCodec.encode(1, SRC_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    app.lzCompose(address(s_oftAsset), keccak256("g1"), lzMsg, address(0), "");

    assertEq(s_vault.balanceOf(address(s_ccipRouter)), expShares, "shares bridged out");
  }

  function test_Deploy_RevertsOnInboundFeeArrayMismatch() public {
    DeployConfig memory cfg = _configWithFees();
    cfg.inboundFeeAmounts = new uint256[](0);
    vm.expectRevert(VaultAdapterFactoryBase.ArrayLengthMismatch.selector);
    s_factory.deploy(cfg);
  }

  function test_Deploy_RevertsOnArrayMismatch() public {
    DeployConfig memory cfg = _configWithFees();
    cfg.ofts = new address[](1); // mismatch with oftTokens (length 2)
    vm.expectRevert(VaultAdapterFactoryBase.ArrayLengthMismatch.selector);
    s_factory.deploy(cfg);
  }

  function test_Deploy_RevertsOnZeroOwner() public {
    DeployConfig memory cfg = _configWithFees();
    cfg.owner = address(0);
    vm.expectRevert(VaultAdapterFactoryBase.ZeroAddress.selector);
    s_factory.deploy(cfg);
  }

  function test_Deploy_RevertsOnFactoryAsOwner() public {
    // owner == factory would make the hand-off grants no-ops and the revocations strip the clone's
    // only DEFAULT_ADMIN_ROLE holder — permanently orphaning administration on the clone.
    DeployConfig memory cfg = _configWithFees();
    cfg.owner = address(s_factory);
    vm.expectRevert(VaultAdapterFactoryBase.FactoryCannotBeRoleHolder.selector);
    s_factory.deploy(cfg);
  }

  function test_Deploy_RevertsOnFactoryAsFeeCollector() public {
    DeployConfig memory cfg = _configWithFees();
    cfg.feeCollector = address(s_factory);
    vm.expectRevert(VaultAdapterFactoryBase.FactoryCannotBeRoleHolder.selector);
    s_factory.deploy(cfg);
  }

  function test_TypeAndVersion() public view {
    assertEq(s_factory.typeAndVersion(), "CrossChainVaultAdapterFactory 1.0.0");
  }
}
