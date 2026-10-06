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

/// @notice Exercises the ERC-4626 cross-chain app (sync, slim message): deposits and redeems over both
///         rails with the produced token delivered to the user-picked `destination` (CCIP selector or
///         LayerZero EID); slippage / bad token -> base capture -> no-operator recovery.
contract CrossChainVaultAdapterTest is Test {
  error ShareTransferFailed();

  CrossChainVaultAdapter internal s_app;
  MockERC20 internal s_asset;
  MockERC4626 internal s_vault;
  MockOFT internal s_oftAsset; // LayerZero OFT for the asset (e.g. USDT0)
  MockOFT internal s_oftShare; // LayerZero OFT for the share token (if it is an OFT)
  MockCcipRouter internal s_ccipRouter;

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");
  address internal s_srcUser = makeAddr("srcUser");
  address internal s_user = makeAddr("user");

  uint32 internal constant SRC_EID = 30_101;
  uint32 internal constant DST_EID = 30_110; // <= uint32.max => LayerZero destination
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;
  uint64 internal constant DST_SELECTOR = 4_949_039_107_694_359_620; // > uint32.max => CCIP destination

  function setUp() public {
    s_asset = new MockERC20("USD Tether", "USDT", 18);
    s_vault = new MockERC4626(IERC20(address(s_asset)), "Vault USDT", "vUSDT");
    s_oftAsset = new MockOFT(address(s_asset), 6);
    s_oftShare = new MockOFT(address(s_vault), 6);
    s_ccipRouter = new MockCcipRouter();
    CrossChainVaultAdapter impl = new CrossChainVaultAdapter();
    s_app = CrossChainVaultAdapter(payable(Clones.clone(address(impl))));
    s_app.initialize(address(s_ccipRouter), s_lzEndpoint, s_owner, address(s_vault));

    vm.startPrank(s_owner);
    // Inbound sources (any number): asset/share may arrive over LayerZero (their OFTs) or CCIP.
    s_app.setLzOft(SRC_EID, address(s_oftAsset), true);
    s_app.setLzOft(SRC_EID, address(s_oftShare), true);
    s_app.setCcipSource(SRC_SELECTOR, true);
    // Outbound destinations the user may route to (any number), on both rails.
    s_app.setCcipDestination(DST_SELECTOR, true);
    s_app.setLzDestination(DST_EID, true);
    // Per-token OFTs (needed for the LayerZero outbound leg + LZ refund bounce).
    s_app.setOftForToken(address(s_asset), address(s_oftAsset));
    s_app.setOftForToken(address(s_vault), address(s_oftShare));
    vm.stopPrank();

    // Seed the vault so it is never empty.
    s_asset.mint(address(this), 1000e18);
    s_asset.approve(address(s_vault), 1000e18);
    s_vault.deposit(1000e18, address(this));

    vm.deal(address(s_app), 100 ether);
    s_ccipRouter.setFee(0.01 ether);
    s_oftAsset.setNativeFee(0.02 ether);
    s_oftShare.setNativeFee(0.02 ether);
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @dev Builds the slim VaultMessage. `destination` is a CCIP selector (> uint32.max) or LZ eid.
  function _msg(
    uint256 minOut,
    uint64 destination,
    bytes32 recipient
  ) internal pure returns (bytes memory) {
    return _msgWithHandler(minOut, destination, recipient, address(0));
  }

  function _msgWithHandler(
    uint256 minOut,
    uint64 destination,
    bytes32 recipient,
    address handler
  ) internal pure returns (bytes memory) {
    return _msgFull(minOut, destination, recipient, handler, false);
  }

  /// @dev Message that opts into handler-only (local) recovery (blocks permissionless refundToSource).
  function _msgLocalOnly(
    uint256 minOut,
    uint64 destination,
    bytes32 recipient,
    address handler
  ) internal pure returns (bytes memory) {
    return _msgFull(minOut, destination, recipient, handler, true);
  }

  function _msgFull(
    uint256 minOut,
    uint64 destination,
    bytes32 recipient,
    address handler,
    bool localOnly
  ) internal pure returns (bytes memory) {
    return abi.encode(
      CrossChainVaultAdapter.VaultMessage({
        minAmountOut: minOut,
        destination: destination,
        recipient: recipient,
        failedMessageHandler: handler,
        onlyLocalRefund: localOnly
      })
    );
  }

  function _bz(
    address a
  ) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
  }

  /// @dev Delivers `token` (amount) over LayerZero via its OFT `from`, with app data.
  function _deliverLz(
    address from,
    uint256 amount,
    bytes32 guid,
    uint64 nonce,
    bytes memory data
  ) internal {
    if (from == address(s_oftAsset)) s_asset.mint(address(s_app), amount);
    else _mintSharesTo(address(s_app), amount);
    bytes memory composeMsg = abi.encodePacked(_bz(s_srcUser), data);
    bytes memory message = OFTComposeMsgCodec.encode(nonce, SRC_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    s_app.lzCompose(from, guid, message, address(0), "");
  }

  /// @dev Delivers over LayerZero with a compose `value` (pre-paying the return leg), like a sender
  ///      that attached native to the OFT send.
  function _deliverLzVal(
    address from,
    uint256 amount,
    bytes32 guid,
    uint64 nonce,
    bytes memory data,
    uint256 value
  ) internal {
    if (from == address(s_oftAsset)) s_asset.mint(address(s_app), amount);
    else _mintSharesTo(address(s_app), amount);
    bytes memory composeMsg = abi.encodePacked(_bz(s_srcUser), data);
    bytes memory message = OFTComposeMsgCodec.encode(nonce, SRC_EID, amount, composeMsg);
    vm.deal(s_lzEndpoint, s_lzEndpoint.balance + value);
    vm.prank(s_lzEndpoint);
    s_app.lzCompose{value: value}(from, guid, message, address(0), "");
  }

  /// @dev Delivers `token` (amount) over CCIP with app data.
  function _deliverCcip(
    address token,
    uint256 amount,
    bytes32 messageId,
    bytes memory data
  ) internal {
    if (token == address(s_asset)) s_asset.mint(address(s_ccipRouter), amount);
    else _mintSharesTo(address(s_ccipRouter), amount);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: token, amount: amount});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: messageId,
      sourceChainSelector: SRC_SELECTOR,
      sender: abi.encode(s_srcUser),
      data: data,
      destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);
  }

  function _mintSharesTo(
    address to,
    uint256 shares
  ) internal {
    s_asset.mint(address(this), shares);
    s_asset.approve(address(s_vault), shares);
    uint256 got = s_vault.deposit(shares, address(this));
    if (!s_vault.transfer(to, got)) revert ShareTransferFailed();
  }

  /*//////////////////////////////////////////////////////////////
          DEPOSIT: ASSET IN (EITHER RAIL) -> SHARES OUT (EITHER RAIL)
  //////////////////////////////////////////////////////////////*/

  function test_Deposit_LzAssetIn_CcipSharesOut() public {
    bytes32 id = keccak256("d1");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);

    _deliverLz(address(s_oftAsset), amount, id, 1, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(s_vault.balanceOf(address(s_ccipRouter)), expShares, "shares bridged out via CCIP");
    assertEq(s_asset.balanceOf(address(s_app)), 0, "no asset retained");
  }

  function test_Deposit_CcipAssetIn_LzSharesOut() public {
    bytes32 id = keccak256("d2");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);
    uint256 rate = 10 ** (18 - 6);
    uint256 expSent = expShares - (expShares % rate);

    _deliverCcip(address(s_asset), amount, id, _msg(0, DST_EID, _bz(s_user)));

    assertEq(s_vault.balanceOf(address(s_oftShare)), expSent, "shares bridged out via LayerZero OFT");
  }

  /*//////////////////////////////////////////////////////////////
         REDEEM: SHARE IN (EITHER RAIL) -> ASSETS OUT (EITHER RAIL)
  //////////////////////////////////////////////////////////////*/

  function test_Redeem_CcipShareIn_LzAssetsOut() public {
    bytes32 id = keccak256("r1");
    uint256 shares = 100e18;
    uint256 expAssets = s_vault.previewRedeem(shares);
    uint256 rate = 10 ** (18 - 6);
    uint256 expSent = expAssets - (expAssets % rate);

    _deliverCcip(address(s_vault), shares, id, _msg(0, DST_EID, _bz(s_user)));

    assertEq(s_asset.balanceOf(address(s_oftAsset)), expSent, "assets bridged out via LayerZero OFT");
  }

  function test_Redeem_LzShareIn_CcipAssetsOut() public {
    bytes32 id = keccak256("r2");
    uint256 shares = 100e18;
    uint256 expAssets = s_vault.previewRedeem(shares);

    _deliverLz(address(s_oftShare), shares, id, 2, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(s_asset.balanceOf(address(s_ccipRouter)), expAssets, "assets bridged out via CCIP");
  }

  /*//////////////////////////////////////////////////////////////
      DESTINATION GAS KEYED BY THE ROUTE'S CONCRETE dstId
  //////////////////////////////////////////////////////////////*/

  function test_RouteGas_KeyedByRouteDstId() public {
    uint64 routeKey = 77; // user-facing route key, decoupled from the concrete LayerZero EID
    vm.startPrank(s_owner);
    s_app.setRoute(
      address(s_vault),
      routeKey,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.LZ_OFT, endpoint: address(s_oftShare), dstId: DST_EID
      })
    );
    s_app.setDestinationGas(DST_EID, 555_555); // keyed by the concrete destination id
    vm.stopPrank();

    _deliverCcip(address(s_asset), 100e18, keccak256("gas1"), _msg(0, routeKey, _bz(s_user)));

    assertEq(
      s_oftShare.s_lastExtraOptions(),
      s_app.lzReceiveOption(555_555),
      "enabled route reads the gas configured for route.dstId"
    );
  }

  function test_RouteGas_RouteKeyEntryNotUsedForEnabledRoute() public {
    uint64 routeKey = 77;
    vm.startPrank(s_owner);
    s_app.setRoute(
      address(s_vault),
      routeKey,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.LZ_OFT, endpoint: address(s_oftShare), dstId: DST_EID
      })
    );
    s_app.setDestinationGas(routeKey, 555_555); // configured on the alias key, not the real chain id
    vm.stopPrank();

    _deliverCcip(address(s_asset), 100e18, keccak256("gas2"), _msg(0, routeKey, _bz(s_user)));

    // The alias-key entry is not consulted; with no dstId entry the default applies.
    assertEq(
      s_oftShare.s_lastExtraOptions(), s_app.lzReceiveOption(200_000), "route send falls back to DEFAULT_DST_GAS"
    );
  }

  function test_RouteGas_LegacyPathStillKeyedByDestination() public {
    vm.prank(s_owner);
    s_app.setDestinationGas(DST_EID, 777_777);

    // No route: legacy LayerZero default, where the destination key IS the packed EID.
    _deliverCcip(address(s_asset), 100e18, keccak256("gas3"), _msg(0, DST_EID, _bz(s_user)));

    assertEq(
      s_oftShare.s_lastExtraOptions(), s_app.lzReceiveOption(777_777), "legacy default reads the destination-keyed gas"
    );
  }

  /*//////////////////////////////////////////////////////////////
      EMPTY-DATA CCIP DELIVERIES ARE TOKEN-ONLY (gasLimit 0)
  //////////////////////////////////////////////////////////////*/

  /// @dev Decodes the gasLimit from a GenericExtraArgsV2 `extraArgs` blob (4-byte tag + struct body).
  function _ccipGasLimit(
    bytes memory ea
  ) internal pure returns (uint256) {
    assertEq(bytes4(ea), Client.GENERIC_EXTRA_ARGS_V2_TAG, "v2 extra-args tag");
    bytes memory body = new bytes(ea.length - 4);
    for (uint256 i; i < body.length; ++i) {
      body[i] = ea[i + 4];
    }
    Client.GenericExtraArgsV2 memory a = abi.decode(body, (Client.GenericExtraArgsV2));
    return a.gasLimit;
  }

  function test_CcipLegacyDelivery_TokenOnly_ZeroGasLimit() public {
    // Even with a configured destination gas, the empty-data CCIP delivery must be token-only.
    vm.prank(s_owner);
    s_app.setDestinationGas(DST_SELECTOR, 400_000);

    _deliverLz(address(s_oftAsset), 100e18, keccak256("m4-legacy"), 1, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(_ccipGasLimit(s_ccipRouter.s_lastExtraArgs()), 0, "legacy CCIP delivery sent with gasLimit 0");
  }

  function test_CcipRouteDelivery_TokenOnly_ZeroGasLimit() public {
    uint64 routeKey = 77;
    vm.startPrank(s_owner);
    s_app.setRoute(
      address(s_vault),
      routeKey,
      RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.CCIP, endpoint: address(0), dstId: DST_SELECTOR})
    );
    s_app.setDestinationGas(DST_SELECTOR, 400_000);
    vm.stopPrank();

    _deliverLz(address(s_oftAsset), 100e18, keccak256("m4-route"), 2, _msg(0, routeKey, _bz(s_user)));

    assertEq(_ccipGasLimit(s_ccipRouter.s_lastExtraArgs()), 0, "CCIP route delivery sent with gasLimit 0");
  }

  /*//////////////////////////////////////////////////////////////
      DESTINATION GAS BOUNDED TO uint32 AT SET TIME
  //////////////////////////////////////////////////////////////*/

  function test_SetDestinationGas_RejectsAboveUint32() public {
    // A value above uint32.max would revert GasLimitTooLarge inside the CCIP v2 extraArgs encoder at
    // SEND time, stalling the lane; it must fail at configuration time instead.
    uint128 tooBig = uint128(type(uint32).max) + 1;
    vm.prank(s_owner);
    vm.expectRevert(abi.encodeWithSelector(RouteRegistry.DestinationGasTooLarge.selector, tooBig));
    s_app.setDestinationGas(DST_SELECTOR, tooBig);

    // The uint32 boundary itself is accepted.
    vm.prank(s_owner);
    s_app.setDestinationGas(DST_SELECTOR, type(uint32).max);
    assertEq(s_app.s_dstGas(DST_SELECTOR), type(uint32).max, "boundary value stored");
  }

  /*//////////////////////////////////////////////////////////////
      THE `0` SENTINEL NEVER RESOLVES TO A BRIDGED SEND
  //////////////////////////////////////////////////////////////*/

  function test_ZeroDestination_WithoutLocalRoute_NeverBridges() public {
    // Adversarial config: eid 0 allowlisted and a per-token OFT set — the legacy LZ fallback would
    // previously bridge a destination-0 delivery (with no fee skim, since the skim treated an unset
    // destination 0 as local). The sentinel now requires an enabled LOCAL route: captured instead.
    vm.startPrank(s_owner);
    s_app.setLzDestination(0, true);
    s_app.setInboundFee(address(s_vault), 0, 1e18);
    vm.stopPrank();

    bytes32 id = keccak256("n10");
    _deliverCcip(address(s_asset), 100e18, id, _msg(0, 0, _bz(s_user)));

    assertTrue(s_app.isFailed(id), "captured: sentinel destination without an enabled LOCAL route");
    assertEq(s_vault.balanceOf(address(s_oftShare)), 0, "nothing bridged over the OFT");
    assertEq(s_app.s_collectedFees(address(s_asset)), 0, "no fee skimmed on the rolled-back delivery");
  }

  /*//////////////////////////////////////////////////////////////
              SLIPPAGE -> BASE CAPTURE -> NO-OPERATOR RECOVERY
  //////////////////////////////////////////////////////////////*/

  /// @dev Rebuilds the {Inbound} the base commits to for an LZ delivery (to call refund/retry).
  function _inboundLz(
    address tkn,
    uint256 amount,
    bytes32 guid,
    bytes memory data
  ) internal view returns (MultiChannelBridgeAdapter.Inbound memory inb) {
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: tkn, amount: amount});
    inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.LayerZero,
      srcId: SRC_EID,
      sender: _bz(s_srcUser),
      guid: guid,
      tokens: ta,
      data: data,
      lzOft: address(s_oftAsset)
    });
    return inb;
  }

  /// @dev Rebuilds the {Inbound} the base commits to for a CCIP delivery (to call refund/retry).
  function _inboundCcip(
    address tkn,
    uint256 amount,
    bytes32 guid,
    bytes memory data
  ) internal view returns (MultiChannelBridgeAdapter.Inbound memory inb) {
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: tkn, amount: amount});
    inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.CCIP,
      srcId: SRC_SELECTOR,
      sender: _bz(s_srcUser),
      guid: guid,
      tokens: ta,
      data: data,
      lzOft: address(0)
    });
    return inb;
  }

  function test_Fail_SlippageBreach_CapturedThenRefundToSource() public {
    bytes32 id = keccak256("s1");
    uint256 amount = 100e18;
    uint256 tooMuch = s_vault.previewDeposit(amount) + 1;
    bytes memory data = _msg(tooMuch, DST_SELECTOR, _bz(s_user));

    _deliverLz(address(s_oftAsset), amount, id, 1, data);

    // Slippage breach reverts -> the base captures the inbound asset.
    assertTrue(s_app.isFailed(id), "captured by base");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained");

    // Permissionless bounce-back to the source sender over the OFT (no operator).
    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(_inboundLz(address(s_asset), amount, id, data));

    assertTrue(s_app.isRefunded(id), "refunded");
    assertEq(s_asset.balanceOf(address(s_oftAsset)), amount, "bounced back over the OFT");
  }

  /*//////////////////////////////////////////////////////////////
      32-BYTE (NON-EVM) RECIPIENTS REJECTED ON CCIP EVM DELIVERY
  //////////////////////////////////////////////////////////////*/

  function test_LegacyCcipDelivery_NonEvmRecipient_Captured() public {
    bytes32 id = keccak256("l01-legacy");
    uint256 amount = 100e18;
    // A recipient with nonzero high 12 bytes (e.g. a Solana address sent to an EVM CCIP route).
    bytes32 nonEvmRecipient = keccak256("solana-recipient");

    // Legacy default CCIP branch (large `destination`, no route configured).
    _deliverLz(address(s_oftAsset), amount, id, 1, _msg(0, DST_SELECTOR, nonEvmRecipient));

    // Rejected (NonEvmCcipRecipient) instead of truncated -> base captures for recovery.
    assertTrue(s_app.isFailed(id), "captured by base");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained");
    assertEq(s_vault.balanceOf(address(s_ccipRouter)), 0, "nothing bridged to a truncated address");
  }

  function test_CcipRouteDelivery_NonEvmRecipient_Captured() public {
    bytes32 id = keccak256("l01-route");
    uint256 amount = 100e18;
    bytes32 nonEvmRecipient = keccak256("solana-recipient");
    uint64 routeKey = 77;

    // Enabled Rail.CCIP route for the produced shares.
    vm.prank(s_owner);
    s_app.setRoute(
      address(s_vault),
      routeKey,
      RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.CCIP, endpoint: address(0), dstId: DST_SELECTOR})
    );

    _deliverLz(address(s_oftAsset), amount, id, 2, _msg(0, routeKey, nonEvmRecipient));

    assertTrue(s_app.isFailed(id), "captured by base");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained");
    assertEq(s_vault.balanceOf(address(s_ccipRouter)), 0, "nothing bridged to a truncated address");
  }

  function test_CcipRouteDelivery_EvmRecipient_StillDelivers() public {
    bytes32 id = keccak256("l01-ok");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);
    uint64 routeKey = 77;

    vm.prank(s_owner);
    s_app.setRoute(
      address(s_vault),
      routeKey,
      RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.CCIP, endpoint: address(0), dstId: DST_SELECTOR})
    );

    _deliverLz(address(s_oftAsset), amount, id, 3, _msg(0, routeKey, _bz(s_user)));

    assertFalse(s_app.isFailed(id), "plain EVM recipient processes normally");
    assertEq(s_vault.balanceOf(address(s_ccipRouter)), expShares, "shares bridged out via CCIP route");
  }

  /*//////////////////////////////////////////////////////////////
            OPT-IN LOCAL-ONLY RECOVERY (onlyLocalRefund)
  //////////////////////////////////////////////////////////////*/

  function test_LocalOnly_BlocksPermissionlessRefundToSource() public {
    address handler = makeAddr("handler");
    bytes32 id = keccak256("lo1");
    uint256 amount = 100e18;
    uint256 tooMuch = s_vault.previewDeposit(amount) + 1; // breach slippage -> captured
    // Opt into handler-only recovery, with a handler designated.
    bytes memory data = _msgLocalOnly(tooMuch, DST_SELECTOR, _bz(s_user), handler);
    _deliverCcip(address(s_asset), amount, id, data);
    assertTrue(s_app.isFailed(id), "captured");

    // A third party cannot force the cross-chain bounce.
    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.LocalRefundOnly.selector, id));
    s_app.refundToSource{value: 0.05 ether}(_inboundCcip(address(s_asset), amount, id, data));
    assertTrue(s_app.isFailed(id), "still failed (permissionless bounce blocked)");

    // The designated handler can still recover locally.
    address to = makeAddr("recoverTo");
    vm.prank(handler);
    s_app.refundLocal(_inboundCcip(address(s_asset), amount, id, data), to);
    assertTrue(s_app.isRefunded(id), "recovered by handler");
    assertEq(s_asset.balanceOf(to), amount, "funds delivered locally by the handler");
  }

  function test_LocalOnly_NoHandler_StillPermissionless() public {
    s_ccipRouter.setFee(0.01 ether);
    bytes32 id = keccak256("lo2");
    uint256 amount = 100e18;
    uint256 tooMuch = s_vault.previewDeposit(amount) + 1;
    // Flag set but NO handler -> no-freeze invariant: refundToSource stays permissionless.
    bytes memory data = _msgLocalOnly(tooMuch, DST_SELECTOR, _bz(s_user), address(0));
    _deliverCcip(address(s_asset), amount, id, data);
    assertTrue(s_app.isFailed(id), "captured");

    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(_inboundCcip(address(s_asset), amount, id, data));
    assertTrue(s_app.isRefunded(id), "permissionless bounce still works with no handler");
    assertEq(s_asset.balanceOf(address(s_ccipRouter)), amount, "bounced back over CCIP");
  }

  function test_UnsupportedToken_CapturedByBase() public {
    // Deliver a random token over CCIP; the app reverts (UnsupportedToken) -> base captures.
    MockERC20 other = new MockERC20("Other", "OTH", 18);
    bytes32 id = keccak256("u1");
    other.mint(address(s_ccipRouter), 1e18);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(other), amount: 1e18});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: id,
      sourceChainSelector: SRC_SELECTOR,
      sender: abi.encode(s_srcUser),
      data: _msg(0, DST_SELECTOR, _bz(s_user)),
      destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);

    assertTrue(s_app.isFailed(id), "base captured");
    assertEq(other.balanceOf(address(s_app)), 1e18, "tokens retained");
  }

  /*//////////////////////////////////////////////////////////////
            LAYERZERO-PREFUNDED RETURN LEG (reserve untouched)
  //////////////////////////////////////////////////////////////*/

  function test_LzReturn_PrefundedCoversFee_NoHandler_SurplusStaysInReserve() public {
    bytes32 id = keccak256("pf1");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);
    uint256 reserve0 = address(s_app).balance; // 100 ether

    // LZ deposit, shares out over CCIP (fee 0.01). Prefund 0.02 via the compose value; NO handler set.
    _deliverLzVal(address(s_oftAsset), amount, id, 1, _msg(0, DST_SELECTOR, _bz(s_user)), 0.02 ether);

    assertEq(s_vault.balanceOf(address(s_ccipRouter)), expShares, "shares out via CCIP");
    assertEq(s_srcUser.balance, 0, "no native returned to the source sender");
    // No handler => the 0.01 surplus over the fee is left in the reserve (becomes operator float).
    assertEq(address(s_app).balance, reserve0 + (0.02 ether - 0.01 ether), "surplus retained in reserve");
  }

  function test_LzReturn_SurplusRefundedAsNativeToHandler() public {
    address handler = makeAddr("handler");
    bytes32 id = keccak256("pf-handler");
    uint256 amount = 100e18;
    uint256 reserve0 = address(s_app).balance;

    _deliverLzVal(
      address(s_oftAsset), amount, id, 1, _msgWithHandler(0, DST_SELECTOR, _bz(s_user), handler), 0.02 ether
    );

    assertEq(s_vault.balanceOf(address(s_ccipRouter)), s_vault.previewDeposit(amount), "shares out via CCIP");
    assertEq(address(s_app).balance, reserve0, "reserve untouched (surplus went to handler)");
    assertEq(handler.balance, 0.01 ether, "surplus refunded as native ETH to the handler");
    assertEq(s_srcUser.balance, 0, "sender gets nothing");
  }

  function test_LzReturn_HandlerRejectsEth_SurplusStaysInReserve() public {
    RejectEth handler = new RejectEth();
    bytes32 id = keccak256("pf-reject");
    uint256 amount = 100e18;
    uint256 reserve0 = address(s_app).balance;

    _deliverLzVal(
      address(s_oftAsset), amount, id, 1, _msgWithHandler(0, DST_SELECTOR, _bz(s_user), address(handler)), 0.02 ether
    );

    assertEq(s_vault.balanceOf(address(s_ccipRouter)), s_vault.previewDeposit(amount), "shares out via CCIP");
    // Best-effort native refund fails (handler rejects ETH) -> surplus left in the reserve; never bricks.
    assertEq(address(handler).balance, 0, "handler received nothing (rejected)");
    assertEq(
      address(s_app).balance, reserve0 + (0.02 ether - 0.01 ether), "surplus retained in reserve on refund failure"
    );
  }

  function test_LzReturn_RequiredButNoValue_CapturedByBase() public {
    vm.prank(s_owner);
    s_app.setRequireLzReturnPrefunded(true);

    bytes32 id = keccak256("pf2");
    uint256 amount = 100e18;
    _deliverLz(address(s_oftAsset), amount, id, 1, _msg(0, DST_SELECTOR, _bz(s_user))); // no value

    assertTrue(s_app.isFailed(id), "captured: LZ return must be prefunded");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained (deposit rolled back)");
  }

  function test_LzReturn_Underfunded_CapturedAndSurplusRetained() public {
    bytes32 id = keccak256("pf3");
    uint256 amount = 100e18;
    uint256 reserve0 = address(s_app).balance;

    // Prefund only 0.005 but the CCIP return fee is 0.01 -> ReturnFeeNotPrefunded -> captured. The
    // message has no handler, so the delivered 0.005 (the reverted hook spent nothing) stays in reserve.
    _deliverLzVal(address(s_oftAsset), amount, id, 1, _msg(0, DST_SELECTOR, _bz(s_user)), 0.005 ether);

    assertTrue(s_app.isFailed(id), "captured: underfunded return");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained");
    assertEq(s_srcUser.balance, 0, "no native returned to the source sender");
    assertEq(address(s_app).balance, reserve0 + 0.005 ether, "delivered prefund retained in reserve");
  }

  function test_TypeAndVersion() public view {
    assertEq(s_app.typeAndVersion(), "CrossChainVaultAdapter 1.0.0");
  }

  /*//////////////////////////////////////////////////////////////
                  CCIP INBOUND TOKEN FEE (RETURN-LEG FUNDING)
  //////////////////////////////////////////////////////////////*/

  function test_CcipInboundFee_SkimmedOnBridgedDeposit() public {
    uint256 fee = 1e18;
    vm.prank(s_owner);
    s_app.setInboundFee(address(s_vault), DST_EID, fee);

    bytes32 id = keccak256("fee-d1");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount - fee);

    _deliverCcip(address(s_asset), amount, id, _msg(0, DST_EID, _bz(s_user)));

    assertEq(s_app.s_collectedFees(address(s_asset)), fee, "fee accrued");
    assertEq(s_asset.balanceOf(address(s_app)), fee, "fee retained on adapter");
    assertEq(s_vault.balanceOf(address(s_oftShare)), expShares - (expShares % (10 ** (18 - 6))), "net shares bridged");
  }

  function test_CcipInboundFee_NotChargedOnLzInbound() public {
    uint256 fee = 1e18;
    vm.prank(s_owner);
    s_app.setInboundFee(address(s_asset), DST_SELECTOR, fee);

    bytes32 id = keccak256("fee-d2");
    uint256 shares = 100e18;
    uint256 expAssets = s_vault.previewRedeem(shares);

    _deliverLz(address(s_oftShare), shares, id, 3, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(s_app.s_collectedFees(address(s_vault)), 0, "LZ inbound: no token fee");
    assertEq(s_asset.balanceOf(address(s_ccipRouter)), expAssets, "full redeem output bridged");
  }

  function test_CcipInboundFee_NotChargedOnLocalDelivery() public {
    uint256 fee = 1e18;
    vm.startPrank(s_owner);
    s_app.setInboundFee(address(s_vault), s_app.LOCAL_DESTINATION(), fee);
    s_app.setRoute(
      address(s_vault),
      s_app.LOCAL_DESTINATION(),
      RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.LOCAL, endpoint: address(0), dstId: 0})
    );
    vm.stopPrank();

    bytes32 id = keccak256("fee-local");
    uint256 amount = 50e18;
    uint256 expShares = s_vault.previewDeposit(amount);

    _deliverCcip(address(s_asset), amount, id, _msg(0, s_app.LOCAL_DESTINATION(), _bz(s_user)));

    assertEq(s_app.s_collectedFees(address(s_asset)), 0, "LOCAL: no fee");
    assertEq(s_vault.balanceOf(s_user), expShares, "full shares delivered locally");
  }

  function test_CcipInboundFee_ExceedsAmount_Captured() public {
    vm.prank(s_owner);
    s_app.setInboundFee(address(s_vault), DST_EID, 100e18);

    bytes32 id = keccak256("fee-fail");
    _deliverCcip(address(s_asset), 50e18, id, _msg(0, DST_EID, _bz(s_user)));

    assertTrue(s_app.isFailed(id), "captured when fee >= amount");
    assertEq(s_asset.balanceOf(address(s_app)), 50e18, "inbound retained");
  }

  function test_CcipInboundFee_WithdrawCollected() public {
    vm.prank(s_owner);
    s_app.setInboundFee(address(s_vault), DST_EID, 2e18);

    _deliverCcip(address(s_asset), 100e18, keccak256("fee-w1"), _msg(0, DST_EID, _bz(s_user)));

    address treasury = makeAddr("treasury");
    vm.prank(s_owner);
    s_app.withdrawCollectedFee(address(s_asset), treasury, 2e18);
    assertEq(s_asset.balanceOf(treasury), 2e18, "withdrawn");
    assertEq(s_app.s_collectedFees(address(s_asset)), 0, "ledger cleared");
  }

  function test_SetRoute_RejectsBadDstId() public {
    vm.startPrank(s_owner);
    uint64 tooBig = uint64(type(uint32).max) + 1;
    // LZ_OFT / STARGATE: dstId must fit uint32 (the LayerZero EID) — reject a truncating value.
    vm.expectRevert(abi.encodeWithSelector(RouteRegistry.InvalidDstId.selector, tooBig));
    s_app.setRoute(
      address(s_vault),
      1,
      RouteRegistry.Route({
        enabled: true, rail: RouteRegistry.Rail.LZ_OFT, endpoint: address(s_oftShare), dstId: tooBig
      })
    );
    // CCIP / CCIP_SVM: dstId (a chain selector) must exceed uint32.max to stay unambiguous.
    vm.expectRevert(abi.encodeWithSelector(RouteRegistry.InvalidDstId.selector, uint64(1234)));
    s_app.setRoute(
      address(s_vault),
      1,
      RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.CCIP, endpoint: address(0), dstId: 1234})
    );
    vm.stopPrank();
  }
}

/// @dev A contract that rejects plain ETH transfers (no receive/payable fallback), used to exercise the
///      best-effort native refund path: when the handler rejects ETH, the surplus stays in the reserve.
contract RejectEth {}
