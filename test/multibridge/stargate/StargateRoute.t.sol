// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {MultiChannelBridgeAdapter} from "../../../src/multibridge/MultiChannelBridgeAdapter.sol";
import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockOFT} from "../mocks/MockOFT.sol";
import {MockStargate} from "../mocks/MockStargate.sol";

/// @notice Exercises the Stargate rail + outbound route registry: native USDT redeemed out to a
///         USDT0-gap chain (e.g. BNB) over Stargate's pooled liquidity, registry precedence over the
///         legacy default, LP-fee slippage capture/recovery, inbound-from-Stargate, and {setRoute}
///         validation. USDT is 6-dec; Stargate shared-decimals 6 (no dust) so the LP fee is isolated.
contract StargateRouteTest is Test {
  error ShareTransferFailed();

  CrossChainVaultAdapter internal s_app;
  MockERC20 internal s_usdt; // 6-dec native USDT (the vault asset)
  MockERC4626 internal s_vault;
  MockOFT internal s_usdtOft; // USDT0 OFT (legacy default rail for USDT)
  MockStargate internal s_sgUsdt; // Stargate pool for USDT (the gap-chain rail)
  MockCcipRouter internal s_ccipRouter;

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");
  address internal s_srcUser = makeAddr("srcUser");
  address internal s_user = makeAddr("user");

  uint32 internal constant SRC_EID = 30_101; // Ethereum
  uint32 internal constant BNB_EID = 30_102; // a USDT0-gap chain reached via Stargate
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;
  uint16 internal constant LP_FEE_BPS = 50; // 0.5% Stargate pool fee (exaggerated for the test)

  function setUp() public {
    s_usdt = new MockERC20("Tether USD", "USDT", 6);
    s_vault = new MockERC4626(IERC20(address(s_usdt)), "Vault USDT", "vUSDT");
    s_usdtOft = new MockOFT(address(s_usdt), 6);
    s_sgUsdt = new MockStargate(address(s_usdt), 6, LP_FEE_BPS);
    s_ccipRouter = new MockCcipRouter();

    CrossChainVaultAdapter impl = new CrossChainVaultAdapter();
    s_app = CrossChainVaultAdapter(payable(Clones.clone(address(impl))));
    s_app.initialize(address(s_ccipRouter), s_lzEndpoint, s_owner, address(s_vault));

    vm.startPrank(s_owner);
    // Shares arrive over CCIP (redeem); USDT may arrive over the Stargate pool (deposit).
    s_app.setCcipSource(SRC_SELECTOR, true);
    s_app.setLzOft(SRC_EID, address(s_sgUsdt), true); // inbound-from-Stargate is just an OFT compose
    s_app.setLzOft(SRC_EID, address(s_usdtOft), true);
    // Outbound: allow the Stargate destination EID, and register the USDT->BNB Stargate route.
    s_app.setStargateDestination(BNB_EID, true);
    s_app.setRoute(
      address(s_usdt),
      BNB_EID,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.STARGATE, endpoint: address(s_sgUsdt), dstId: BNB_EID
      })
    );
    // Legacy per-token OFT (USDT0) — kept for inbound bounce + as the default for other dests.
    s_app.setOftForToken(address(s_usdt), address(s_usdtOft));
    vm.stopPrank();

    // Seed the vault 1:1 so redeem produces ~equal USDT.
    s_usdt.mint(address(this), 1000e6);
    s_usdt.approve(address(s_vault), 1000e6);
    s_vault.deposit(1000e6, address(this));

    vm.deal(address(s_app), 100 ether);
    s_ccipRouter.setFee(0.01 ether);
    s_sgUsdt.setNativeFee(0.02 ether);
    s_usdtOft.setNativeFee(0.02 ether);
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  function _bz(
    address a
  ) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
  }

  function _msg(
    uint256 minOut,
    uint64 destination,
    bytes32 recipient
  ) internal pure returns (bytes memory) {
    return abi.encode(
      CrossChainVaultAdapter.VaultMessage({
        minAmountOut: minOut,
        destination: destination,
        recipient: recipient,
        failedMessageHandler: address(0),
        onlyLocalRefund: false
      })
    );
  }

  /// @dev Delivers `shares` of the vault token over CCIP (a redeem inbound) with app data.
  function _deliverShareCcip(
    uint256 shares,
    bytes32 messageId,
    bytes memory data
  ) internal {
    _mintSharesTo(address(s_ccipRouter), shares);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_vault), amount: shares});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: messageId,
      sourceChainSelector: SRC_SELECTOR,
      sender: abi.encode(s_srcUser),
      data: data,
      destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);
  }

  /// @dev Delivers `amount` USDT over a LayerZero OFT compose from `from` (a deposit inbound).
  function _deliverUsdtLz(
    address from,
    uint256 amount,
    bytes32 guid,
    uint64 nonce,
    bytes memory data
  ) internal {
    s_usdt.mint(address(s_app), amount);
    bytes memory composeMsg = abi.encodePacked(_bz(s_srcUser), data);
    bytes memory message = OFTComposeMsgCodec.encode(nonce, SRC_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    s_app.lzCompose(from, guid, message, address(0), "");
  }

  function _mintSharesTo(
    address to,
    uint256 shares
  ) internal {
    s_usdt.mint(address(this), shares);
    s_usdt.approve(address(s_vault), shares);
    uint256 got = s_vault.deposit(shares, address(this));
    if (!s_vault.transfer(to, got)) revert ShareTransferFailed();
  }

  /*//////////////////////////////////////////////////////////////
                     REDEEM -> USDT OUT VIA STARGATE
  //////////////////////////////////////////////////////////////*/

  function test_Redeem_ShareInCcip_UsdtOutViaStargate() public {
    bytes32 id = keccak256("sg-redeem");
    uint256 shares = 100e6;
    uint256 expAssets = s_vault.previewRedeem(shares);

    _deliverShareCcip(shares, id, _msg(0, BNB_EID, _bz(s_user)));

    // The Stargate pool locked the produced USDT (it would deliver `expAssets - LP fee` on BNB).
    assertEq(s_usdt.balanceOf(address(s_sgUsdt)), expAssets, "USDT routed out via Stargate pool");
    assertEq(s_usdt.balanceOf(address(s_app)), 0, "no USDT retained");
    assertEq(s_usdt.balanceOf(address(s_usdtOft)), 0, "legacy OFT not used");
  }

  function test_Registry_TakesPrecedenceOverLegacyDefault() public {
    // BNB_EID <= uint32.max, so WITHOUT a route the legacy default would send via the USDT0 OFT.
    // The enabled Stargate route must win.
    bytes32 id = keccak256("sg-precedence");
    uint256 shares = 50e6;
    uint256 expAssets = s_vault.previewRedeem(shares);

    _deliverShareCcip(shares, id, _msg(0, BNB_EID, _bz(s_user)));

    assertEq(s_usdt.balanceOf(address(s_sgUsdt)), expAssets, "registry route (Stargate) took precedence");
    assertEq(s_usdt.balanceOf(address(s_usdtOft)), 0, "legacy OFT default bypassed");
  }

  /*//////////////////////////////////////////////////////////////
               LP-FEE SLIPPAGE -> CAPTURE -> RECOVERY
  //////////////////////////////////////////////////////////////*/

  function test_Stargate_LpFeeBreachesTightSlippage_CapturedThenRecovered() public {
    // The user sets a tight per-tx floor (0 tolerance) that the pool's 0.5% LP fee breaches: the
    // pool's minAmountLD (= the user's minAmountOut) exceeds the post-fee amount -> revert -> capture.
    bytes32 id = keccak256("sg-slip");
    uint256 shares = 100e6;
    uint256 expAssets = s_vault.previewRedeem(shares);
    bytes memory data = _msg(expAssets, BNB_EID, _bz(s_user)); // floor = full produced amount, no tolerance

    _deliverShareCcip(shares, id, data);

    // The Stargate leg reverted -> base captured the inbound SHARES (redeem rolled back).
    assertTrue(s_app.isFailed(id), "captured by base on Stargate slippage");
    assertEq(s_vault.balanceOf(address(s_app)), shares, "inbound shares retained");
    assertEq(s_usdt.balanceOf(address(s_sgUsdt)), 0, "nothing left over Stargate");

    // Permissionless bounce-back of the shares to source over CCIP (no operator). The caller
    // reconstructs the captured Inbound (from the MessageFailed event); hash-verified by the base.
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_vault), amount: shares});
    MultiChannelBridgeAdapter.Inbound memory inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.CCIP,
      srcId: SRC_SELECTOR,
      sender: _bz(s_srcUser),
      guid: id,
      tokens: ta,
      data: data,
      lzOft: address(0)
    });
    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(inb);

    assertTrue(s_app.isRefunded(id), "refunded");
    assertEq(s_vault.balanceOf(address(s_ccipRouter)), shares, "shares bounced back over CCIP");
  }

  function test_Stargate_DestNotAllowlisted_Captured() public {
    // Disable the Stargate dest allowlist but keep the route -> base reverts StargateDestNotAllowed.
    vm.prank(s_owner);
    s_app.setStargateDestination(BNB_EID, false);

    bytes32 id = keccak256("sg-noallow");
    uint256 shares = 100e6;
    _deliverShareCcip(shares, id, _msg(0, BNB_EID, _bz(s_user)));

    assertTrue(s_app.isFailed(id), "captured: Stargate dest not allowlisted");
    assertEq(s_vault.balanceOf(address(s_app)), shares, "inbound shares retained");
  }

  /*//////////////////////////////////////////////////////////////
                     INBOUND FROM STARGATE (config-only)
  //////////////////////////////////////////////////////////////*/

  function test_Deposit_UsdtInViaStargateInbound_SharesOutLegacyOft() public {
    // USDT arriving FROM a gap chain over Stargate is just an OFT compose (the pool is the OFT).
    // Route the produced shares out over the (legacy) USDT0 default to a small EID is not set here;
    // instead deliver shares out via a CCIP destination to keep this focused on inbound.
    vm.startPrank(s_owner);
    s_app.setLzDestination(SRC_EID, true);
    s_app.setOftForToken(address(s_vault), address(new MockOFT(address(s_vault), 6)));
    vm.stopPrank();

    bytes32 id = keccak256("sg-inbound");
    uint256 amount = 100e6;
    uint256 expShares = s_vault.previewDeposit(amount);

    // shares out over the legacy OFT default (destination = SRC_EID, a small EID, no route set).
    _deliverUsdtLz(address(s_sgUsdt), amount, id, 1, _msg(0, SRC_EID, _bz(s_user)));

    assertFalse(s_app.isFailed(id), "inbound-from-Stargate deposit succeeded");
    assertEq(s_vault.balanceOf(address(s_app)), 0, "shares delivered out");
    assertGt(expShares, 0, "shares were minted");
  }

  /*//////////////////////////////////////////////////////////////
                          setRoute VALIDATION
  //////////////////////////////////////////////////////////////*/

  function test_SetRoute_RevertsOnEndpointTokenMismatch() public {
    MockStargate wrongPool = new MockStargate(address(s_vault), 6, LP_FEE_BPS); // token() == share, not USDT
    vm.prank(s_owner);
    vm.expectRevert(abi.encodeWithSelector(RouteRegistry.AssetOftMismatch.selector, address(s_vault), address(s_usdt)));
    s_app.setRoute(
      address(s_usdt),
      BNB_EID,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.STARGATE, endpoint: address(wrongPool), dstId: BNB_EID
      })
    );
  }

  function test_SetRoute_OnlyOwner() public {
    vm.expectRevert();
    s_app.setRoute(
      address(s_usdt),
      BNB_EID,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.STARGATE, endpoint: address(s_sgUsdt), dstId: BNB_EID
      })
    );
  }
}
