// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";

/// @dev Minimal concrete RouteRegistry exposing {_routeOut} so the LOCAL delivered-amount measurement
///      can be exercised directly with arbitrary tokens.
contract RouteOutHarness is RouteRegistry {
  function initialize(
    address ccipRouter,
    address lzEndpoint,
    address owner
  ) external initializer {
    __MultiChannelBridgeAdapter_init(ccipRouter, lzEndpoint, owner);
  }

  function routeOut(
    address token,
    uint256 amount,
    uint256 minAmountOut,
    uint64 destination,
    bytes32 recipient
  ) external returns (uint256 fee, bool bridged) {
    return _routeOut(token, amount, minAmountOut, destination, recipient);
  }

  function _handleReceive(
    Inbound calldata
  ) internal override {}
}

/// @notice LOCAL delivery enforces `minAmountOut` on the recipient's MEASURED balance delta, so the
///         documented delivered-amount floor holds even for a token that is not 1:1 on transfer.
contract LocalDeliveryMeasuredTest is Test {
  RouteOutHarness internal s_app;
  MockFeeOnTransferERC20 internal s_fotToken; // 1% fee on every transfer
  MockERC20 internal s_token; // standard 1:1 token

  address internal s_owner = makeAddr("owner");
  address internal s_user = makeAddr("user");

  uint16 internal constant FEE_BPS = 100; // 1%

  function setUp() public {
    s_app = new RouteOutHarness();
    s_app.initialize(address(new MockCcipRouter()), makeAddr("lzEndpoint"), s_owner);
    s_fotToken = new MockFeeOnTransferERC20("Fee Token", "FEE", FEE_BPS);
    s_token = new MockERC20("USD Tether", "USDT", 18);

    vm.startPrank(s_owner);
    s_app.setRoute(address(s_fotToken), s_app.LOCAL_DESTINATION(), _local());
    s_app.setRoute(address(s_token), s_app.LOCAL_DESTINATION(), _local());
    vm.stopPrank();
  }

  function _local() internal pure returns (RouteRegistry.Route memory) {
    return RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.LOCAL, endpoint: address(0), dstId: 0});
  }

  function _bz(
    address a
  ) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
  }

  function test_Local_FeeOnTransfer_DeliveredBelowFloor_Reverts() public {
    uint256 amount = 100e18;
    uint256 delivered = amount - (amount * FEE_BPS) / 10_000; // 99e18 actually reaches the recipient
    s_fotToken.mint(address(s_app), amount);

    // The floor equals the SENT amount: the source-side amount passes, but the recipient would
    // receive less — the measured check must catch it.
    vm.expectRevert(abi.encodeWithSelector(RouteRegistry.MinAmountOutNotMet.selector, delivered, amount));
    s_app.routeOut(address(s_fotToken), amount, amount, 0, _bz(s_user));
    assertEq(s_fotToken.balanceOf(s_user), 0, "nothing delivered on a floor breach");
  }

  function test_Local_FeeOnTransfer_FloorOnDeliveredAmount_Passes() public {
    uint256 amount = 100e18;
    uint256 delivered = amount - (amount * FEE_BPS) / 10_000;
    s_fotToken.mint(address(s_app), amount);

    (uint256 fee, bool bridged) = s_app.routeOut(address(s_fotToken), amount, delivered, 0, _bz(s_user));

    assertEq(fee, 0, "LOCAL pays no bridge fee");
    assertFalse(bridged, "LOCAL is same-chain");
    assertEq(s_fotToken.balanceOf(s_user), delivered, "measured delivery meets the floor");
  }

  function test_Local_StandardToken_ExactFloor_Passes() public {
    uint256 amount = 100e18;
    s_token.mint(address(s_app), amount);

    s_app.routeOut(address(s_token), amount, amount, 0, _bz(s_user));

    assertEq(s_token.balanceOf(s_user), amount, "1:1 token delivers the full amount at an exact floor");
  }
}
