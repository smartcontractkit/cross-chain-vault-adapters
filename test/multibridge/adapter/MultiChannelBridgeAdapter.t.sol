// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Test} from "forge-std/Test.sol";

import {MultiChannelBridgeAdapter} from "../../../src/multibridge/MultiChannelBridgeAdapter.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOFT} from "../mocks/MockOFT.sol";

/// @dev Minimal example application built on the base. Records the last delivery and, if the inbound
///      `data` carries a forwarding {Action}, re-emits the received token over the chosen channel —
///      standing in for "take the tokens and interact with other contracts" (e.g. a vault).
contract ExampleApp is MultiChannelBridgeAdapter {
  error ForcedFail();

  struct Action {
    bytes32 recipient;
    address oft;
    uint64 dstSelector;
    uint32 dstEid;
    address handler; // failed-message handler embedded in the payload
    uint8 outChannel; // 0 = CCIP, 1 = LayerZero, other = no forward (hold tokens)
    uint128 gas;
  }

  Channel public lastChannel;
  uint64 public lastSrcId;
  bytes32 public lastSender;
  bytes32 public lastGuid;
  address public lastToken;
  uint256 public lastAmount;
  bytes public lastData;
  bool public forwarded;
  bool public forceFail;
  address public refundOft;

  constructor() {}

  function initialize(
    address r,
    address e,
    address o
  ) external initializer {
    __MultiChannelBridgeAdapter_init(r, e, o);
  }

  function setForceFail(
    bool v
  ) external {
    forceFail = v;
  }

  function setRefundOft(
    address o
  ) external {
    refundOft = o;
  }

  /// @dev The handler is the Action's `handler` field; malformed data reverts the decode (base -> 0).
  function failedMessageHandler(
    bytes calldata data
  ) external pure override returns (address) {
    return abi.decode(data, (Action)).handler;
  }

  /// @dev Single OFT used to bounce a LayerZero inbound back to source in tests.
  function _oftFor(
    address
  ) internal view override returns (address) {
    return refundOft;
  }

  /// @dev Test hook: exposes {_sendViaCcip} with an arbitrary `feeToken` (the app paths pass address(0)).
  function sendViaCcip(
    uint64 dstSelector,
    address receiver,
    address tkn,
    uint256 amount,
    address feeToken
  ) external returns (bytes32 messageId, uint256 fee) {
    return _sendViaCcip(dstSelector, receiver, tkn, amount, "", 0, feeToken);
  }

  function _handleReceive(
    Inbound calldata inbound
  ) internal override {
    if (forceFail) revert ForcedFail();
    lastChannel = inbound.channel;
    lastSrcId = inbound.srcId;
    lastSender = inbound.sender;
    lastGuid = inbound.guid;
    lastToken = inbound.tokens[0].token;
    lastAmount = inbound.tokens[0].amount;
    lastData = inbound.data;

    // Only treat data as a forwarding Action when it is the full ABI size (7 words); otherwise it
    // is opaque application data and the tokens are simply held.
    if (inbound.data.length < 224) return;
    Action memory a = abi.decode(inbound.data, (Action));
    if (a.outChannel == uint8(Channel.CCIP)) {
      _sendViaCcip(a.dstSelector, address(uint160(uint256(a.recipient))), lastToken, lastAmount, "", a.gas, address(0));
      forwarded = true;
    } else if (a.outChannel == uint8(Channel.LayerZero)) {
      _sendViaOft(a.dstEid, a.recipient, a.oft, lastAmount, 0, "", lzReceiveOption(a.gas));
      forwarded = true;
    }
  }
}

contract MultiChannelBridgeAdapterTest is Test {
  ExampleApp internal s_app;
  MockERC20 internal s_token;
  MockOFT internal s_oft;
  MockOFT internal s_badOft;
  MockCcipRouter internal s_ccipRouter;

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");
  address internal s_srcUser = makeAddr("srcUser");
  address internal s_recipient = makeAddr("recipient");

  uint32 internal constant SRC_EID = 30_101;
  uint32 internal constant DST_EID = 30_110;
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;
  uint64 internal constant DST_SELECTOR = 4_949_039_107_694_359_620;
  uint256 internal constant AMOUNT = 100e18;

  function setUp() public {
    s_token = new MockERC20("USD Tether", "USDT", 18);
    s_oft = new MockOFT(address(s_token), 6);
    s_badOft = new MockOFT(address(s_token), 6);
    s_ccipRouter = new MockCcipRouter();
    s_app = new ExampleApp();
    s_app.initialize(address(s_ccipRouter), s_lzEndpoint, s_owner);

    vm.startPrank(s_owner);
    s_app.setCcipSource(SRC_SELECTOR, true);
    s_app.setLzOft(SRC_EID, address(s_oft), true);
    s_app.setCcipDestination(DST_SELECTOR, true);
    s_app.setLzDestination(DST_EID, true);
    vm.stopPrank();

    vm.deal(address(s_app), 100 ether);
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  function _deliverCcip(
    uint256 amount,
    bytes32 messageId,
    bytes memory data
  ) internal {
    s_token.mint(address(s_ccipRouter), amount);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_token), amount: amount});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: messageId,
      sourceChainSelector: SRC_SELECTOR,
      sender: abi.encode(s_srcUser),
      data: data,
      destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);
  }

  function _deliverLz(
    uint256 amount,
    bytes32 guid,
    uint64 nonce,
    bytes memory data
  ) internal {
    s_token.mint(address(s_app), amount);
    bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(s_srcUser))), data);
    bytes memory message = OFTComposeMsgCodec.encode(nonce, SRC_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    s_app.lzCompose(address(s_oft), guid, message, address(0), "");
  }

  /*//////////////////////////////////////////////////////////////
                              RECEIVE
  //////////////////////////////////////////////////////////////*/

  function test_ReceiveCcip_RecordsTokensAndData() public {
    bytes memory data = hex"c0ffee";
    _deliverCcip(AMOUNT, keccak256("m1"), data);

    assertEq(uint8(s_app.lastChannel()), uint8(MultiChannelBridgeAdapter.Channel.CCIP));
    assertEq(s_app.lastSrcId(), SRC_SELECTOR);
    assertEq(s_app.lastSender(), bytes32(uint256(uint160(s_srcUser))));
    assertEq(s_app.lastToken(), address(s_token));
    assertEq(s_app.lastAmount(), AMOUNT);
    assertEq(s_app.lastData(), data);
    // Token held by the app (no forward instruction in this opaque data).
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT);
  }

  function test_ReceiveLz_RecordsTokensAndData() public {
    bytes memory data = hex"1234";
    _deliverLz(AMOUNT, keccak256("g1"), 1, data);

    assertEq(uint8(s_app.lastChannel()), uint8(MultiChannelBridgeAdapter.Channel.LayerZero));
    assertEq(s_app.lastSrcId(), SRC_EID);
    assertEq(s_app.lastSender(), bytes32(uint256(uint160(s_srcUser))));
    assertEq(s_app.lastToken(), address(s_token));
    assertEq(s_app.lastAmount(), AMOUNT);
    assertEq(s_app.lastData(), data);
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT);
  }

  /*//////////////////////////////////////////////////////////////
                RECEIVE -> ARBITRARY DATA -> FORWARD (BOTH RAILS)
  //////////////////////////////////////////////////////////////*/

  function test_ReceiveLz_ForwardViaCcip() public {
    s_ccipRouter.setFee(0.01 ether);
    _deliverLz(AMOUNT, keccak256("g2"), 2, _action(0, address(0)));

    assertTrue(s_app.forwarded(), "forwarded");
    // Token left the app to the CCIP router (bridged out).
    assertEq(s_token.balanceOf(address(s_app)), 0, "app emptied");
    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT, "ccip received token");
  }

  function test_ReceiveCcip_ForwardViaOft() public {
    s_oft.setNativeFee(0.02 ether);
    uint256 rate = 10 ** (18 - 6);
    uint256 expSent = AMOUNT - (AMOUNT % rate); // 6-shared-decimal flooring (no dust for round AMOUNT)
    _deliverCcip(AMOUNT, keccak256("m2"), _action(1, address(0)));

    assertTrue(s_app.forwarded(), "forwarded");
    assertEq(s_token.balanceOf(address(s_oft)), expSent, "oft locked token");
  }

  /*//////////////////////////////////////////////////////////////
                                AUTH
  //////////////////////////////////////////////////////////////*/

  function test_Ccip_RevertsOnNonRouter() public {
    Client.Any2EVMMessage memory m;
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NotCcipRouter.selector, address(this)));
    s_app.ccipReceive(m);
  }

  function test_Ccip_UnauthorizedSource_CapturedAndRefundable() public {
    vm.prank(s_owner);
    s_app.setCcipSource(SRC_SELECTOR, false);

    s_ccipRouter.setFee(0.01 ether);
    s_token.mint(address(s_ccipRouter), AMOUNT);
    bytes32 mid = keccak256("m3");
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_token), amount: AMOUNT});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: mid, sourceChainSelector: SRC_SELECTOR, sender: abi.encode(s_srcUser), data: "", destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);

    assertTrue(s_app.isFailed(mid), "captured as failed");
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT, "tokens retained");

    // The stored capture is the hash commitment over the exact Inbound (full data is in the event).
    MultiChannelBridgeAdapter.Inbound memory inb = _inboundCcip(AMOUNT, mid, "");
    assertEq(s_app.failedMessageHash(mid), keccak256(abi.encode(inb)), "hash commitment matches the reconstruction");

    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(inb);

    assertFalse(s_app.isFailed(mid), "resolved");
    assertTrue(s_app.isRefunded(mid), "refunded");
    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT, "bounced back over CCIP");
    assertEq(s_token.balanceOf(address(s_app)), 0, "app drained");
  }

  function test_Lz_RevertsOnNonEndpoint() public {
    bytes memory message = OFTComposeMsgCodec.encode(1, SRC_EID, AMOUNT, abi.encodePacked(bytes32(0)));
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NotLzEndpoint.selector, address(this)));
    s_app.lzCompose(address(s_oft), keccak256("x"), message, address(0), "");
  }

  function test_Lz_UnauthorizedOft_RevertsAtBoundary() public {
    // A disallowed (srcEid, oft) compose credits no real tokens, so it REVERTS at the lzCompose
    // boundary rather than being captured (capturing would create an unrecoverable phantom entry).
    bytes32 guid = keccak256("m-lz-unauth");
    bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(s_srcUser))), "");
    bytes memory message = OFTComposeMsgCodec.encode(1, SRC_EID, AMOUNT, composeMsg);

    vm.prank(s_lzEndpoint);
    vm.expectRevert(
      abi.encodeWithSelector(MultiChannelBridgeAdapter.UnauthorizedOft.selector, SRC_EID, address(s_badOft))
    );
    s_app.lzCompose(address(s_badOft), guid, message, address(0), "");

    assertFalse(s_app.isFailed(guid), "not captured (reverted at the boundary)");
  }

  /*//////////////////////////////////////////////////////////////
                    GRACEFUL FAILURE CAPTURE + RECOVERY
  //////////////////////////////////////////////////////////////*/

  /// @dev Rebuilds the exact {Inbound} the base commits to, so retry/recover hash-match.
  function _inboundCcip(
    uint256 amount,
    bytes32 messageId,
    bytes memory data
  ) internal view returns (MultiChannelBridgeAdapter.Inbound memory inb) {
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_token), amount: amount});
    inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.CCIP,
      srcId: SRC_SELECTOR,
      sender: bytes32(uint256(uint160(s_srcUser))),
      guid: messageId,
      tokens: ta,
      data: data,
      lzOft: address(0)
    });
    return inb;
  }

  function _inboundLz(
    uint256 amount,
    bytes32 guid,
    bytes memory data
  ) internal view returns (MultiChannelBridgeAdapter.Inbound memory inb) {
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_token), amount: amount});
    inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.LayerZero,
      srcId: SRC_EID,
      sender: bytes32(uint256(uint160(s_srcUser))),
      guid: guid,
      tokens: ta,
      data: data,
      lzOft: address(s_oft)
    });
    return inb;
  }

  function test_FailedHook_CapturedNotReverted_Ccip() public {
    s_app.setForceFail(true);
    bytes32 mid = keccak256("f-ccip");
    // No revert despite the hook reverting: the delivery is captured.
    _deliverCcip(AMOUNT, mid, "");
    assertTrue(s_app.isFailed(mid), "captured as failed");
    // Tokens retained by the app, fully matching the commitment.
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT, "tokens retained");
  }

  function test_FailedHook_CapturedNotReverted_Lz() public {
    s_app.setForceFail(true);
    bytes32 guid = keccak256("f-lz");
    _deliverLz(AMOUNT, guid, 9, "");
    assertTrue(s_app.isFailed(guid), "captured as failed");
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT, "tokens retained");
  }

  function test_ForwardToDisallowedDest_CapturedAsFailed() public {
    // Disallow the CCIP destination, then deliver an LZ message instructing a CCIP forward.
    vm.prank(s_owner);
    s_app.setCcipDestination(DST_SELECTOR, false);
    bytes32 guid = keccak256("f-fwd");
    _deliverLz(AMOUNT, guid, 10, _action(0, address(0)));
    assertTrue(s_app.isFailed(guid), "captured");
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT, "tokens retained after rolled-back forward");
  }

  /// @dev Builds a full (7-word) Action payload: `outChannel` 0=CCIP-forward, 1=LZ-forward,
  ///      other=hold; `handler` is the embedded failed-message handler.
  function _action(
    uint8 outChannel,
    address handler
  ) internal view returns (bytes memory) {
    return abi.encode(
      ExampleApp.Action({
        outChannel: outChannel,
        dstSelector: DST_SELECTOR,
        dstEid: DST_EID,
        recipient: bytes32(uint256(uint160(s_recipient))),
        oft: address(s_oft),
        gas: 200_000,
        handler: handler
      })
    );
  }

  /*//////////////////////////////////////////////////////////////
                REFUND TO SOURCE (PERMISSIONLESS BOUNCE-BACK)
  //////////////////////////////////////////////////////////////*/

  function test_RefundToSource_Ccip_Permissionless() public {
    // A malformed/dataless CCIP token transfer (no handler): anyone can bounce it back to source.
    s_app.setForceFail(true);
    s_ccipRouter.setFee(0.01 ether);
    bytes32 mid = keccak256("rts-ccip");
    _deliverCcip(AMOUNT, mid, "");

    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    uint256 reserveBefore = address(s_app).balance;

    vm.prank(bot); // permissionless
    s_app.refundToSource{value: 0.05 ether}(_inboundCcip(AMOUNT, mid, ""));

    assertFalse(s_app.isFailed(mid), "resolved");
    assertTrue(s_app.isRefunded(mid), "refunded");
    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT, "bounced back over CCIP");
    assertEq(s_token.balanceOf(address(s_app)), 0, "app drained");
    assertEq(address(s_app).balance, reserveBefore, "reserve untouched (bot funded the bounce)");
    assertEq(bot.balance, 1 ether - 0.01 ether, "bot paid only the bounce fee");
  }

  function test_RefundToSource_Lz_BouncesViaOft() public {
    s_app.setForceFail(true);
    s_oft.setNativeFee(0.02 ether);
    s_app.setRefundOft(address(s_oft)); // base resolves the OFT for the token via _oftFor
    bytes32 guid = keccak256("rts-lz");
    _deliverLz(AMOUNT, guid, 20, "");

    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    uint256 reserveBefore = address(s_app).balance;

    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(_inboundLz(AMOUNT, guid, ""));

    assertTrue(s_app.isRefunded(guid), "refunded");
    assertEq(s_token.balanceOf(address(s_oft)), AMOUNT, "bounced back over the OFT");
    assertEq(address(s_app).balance, reserveBefore, "reserve untouched");
  }

  function test_RefundToSource_Unfunded_Reverts() public {
    s_app.setForceFail(true);
    s_ccipRouter.setFee(0.01 ether);
    bytes32 mid = keccak256("rts-unfunded");
    _deliverCcip(AMOUNT, mid, "");
    // No msg.value: the bounce fee would draw the reserve -> revert, message stays FAILED.
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.RetryReserveDrawn.selector, uint256(0.01 ether)));
    s_app.refundToSource(_inboundCcip(AMOUNT, mid, ""));
    assertTrue(s_app.isFailed(mid), "still failed");
  }

  /*//////////////////////////////////////////////////////////////
                     HANDLER-ONLY RETRY / REFUND-LOCAL
  //////////////////////////////////////////////////////////////*/

  function test_Retry_HandlerOnly_NoOutbound() public {
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");
    bytes memory data = _action(2, keeper); // outChannel 2 = hold (no outbound)
    s_app.setForceFail(true);
    bytes32 mid = keccak256("retry-ho");
    _deliverCcip(AMOUNT, mid, data);

    s_app.setForceFail(false);
    // Non-handler cannot retry.
    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NotHandler.selector, stranger, keeper));
    s_app.retryFailedMessage(_inboundCcip(AMOUNT, mid, data));

    // The designated handler can (no outbound -> no fee needed).
    vm.prank(keeper);
    s_app.retryFailedMessage(_inboundCcip(AMOUNT, mid, data));
    assertFalse(s_app.isFailed(mid), "resolved");
    assertEq(s_app.lastAmount(), AMOUNT, "reprocessed");
  }

  function test_Retry_NoHandler_Reverts() public {
    // Malformed payload -> handler resolves to address(0) -> handler-only paths unavailable.
    s_app.setForceFail(true);
    bytes32 mid = keccak256("retry-noh");
    _deliverCcip(AMOUNT, mid, "");
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NoHandler.selector, mid));
    s_app.retryFailedMessage(_inboundCcip(AMOUNT, mid, ""));
    assertTrue(s_app.isFailed(mid), "still failed");
  }

  function test_Retry_FundedOutbound_ReserveProtected() public {
    address keeper = makeAddr("keeper");
    vm.prank(s_owner);
    s_app.setCcipDestination(DST_SELECTOR, false);
    s_ccipRouter.setFee(0.01 ether);
    bytes memory data = _action(0, keeper); // CCIP forward
    bytes32 guid = keccak256("retry-fund");
    _deliverLz(AMOUNT, guid, 21, data);
    vm.prank(s_owner);
    s_app.setCcipDestination(DST_SELECTOR, true);

    vm.deal(keeper, 1 ether);
    uint256 reserveBefore = address(s_app).balance;

    // Unfunded: the forward fee would draw the reserve -> revert.
    vm.prank(keeper);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.RetryReserveDrawn.selector, uint256(0.01 ether)));
    s_app.retryFailedMessage(_inboundLz(AMOUNT, guid, data));

    // Funded by the handler: succeeds, reserve untouched, surplus returned.
    vm.prank(keeper);
    s_app.retryFailedMessage{value: 0.05 ether}(_inboundLz(AMOUNT, guid, data));
    assertFalse(s_app.isFailed(guid), "resolved");
    assertTrue(s_app.forwarded(), "forwarded");
    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT, "bridged out");
    assertEq(address(s_app).balance, reserveBefore, "reserve untouched");
    assertEq(keeper.balance, 1 ether - 0.01 ether, "handler paid only the fee");
  }

  function test_Retry_StillFailing_Reverts() public {
    address keeper = makeAddr("keeper");
    bytes memory data = _action(2, keeper);
    s_app.setForceFail(true);
    bytes32 mid = keccak256("retry-stillfail");
    _deliverCcip(AMOUNT, mid, data);

    // forceFail still set -> reprocess reverts -> retry reverts, message stays FAILED.
    vm.prank(keeper);
    vm.expectRevert(ExampleApp.ForcedFail.selector);
    s_app.retryFailedMessage(_inboundCcip(AMOUNT, mid, data));
    assertTrue(s_app.isFailed(mid), "still failed");
  }

  function test_RefundLocal_HandlerOnly() public {
    address keeper = makeAddr("keeper");
    address stranger = makeAddr("stranger");
    bytes memory data = _action(2, keeper);
    s_app.setForceFail(true);
    bytes32 mid = keccak256("refund-local");
    _deliverCcip(AMOUNT, mid, data);

    vm.prank(stranger);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NotHandler.selector, stranger, keeper));
    s_app.refundLocal(_inboundCcip(AMOUNT, mid, data), s_recipient);

    vm.prank(keeper);
    s_app.refundLocal(_inboundCcip(AMOUNT, mid, data), s_recipient);
    assertTrue(s_app.isRefunded(mid), "refunded");
    assertEq(s_token.balanceOf(s_recipient), AMOUNT, "refunded to the chosen local address");
    assertEq(s_token.balanceOf(address(s_app)), 0, "drained");
  }

  function test_Recovery_RevertsOnUnknownGuid() public {
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.MessageNotFailed.selector, keccak256("nope")));
    s_app.refundToSource(_inboundCcip(AMOUNT, keccak256("nope"), ""));
  }

  function test_Recovery_RevertsOnTamperedInbound() public {
    // The recovery caller supplies the Inbound; anything that does not hash to the stored
    // commitment is rejected, so the event-emitted capture is the only valid reconstruction.
    s_app.setForceFail(true);
    s_ccipRouter.setFee(0.01 ether);
    bytes32 mid = keccak256("tampered");
    _deliverCcip(AMOUNT, mid, "");

    MultiChannelBridgeAdapter.Inbound memory bad = _inboundCcip(AMOUNT, mid, "");
    bad.tokens[0].amount = AMOUNT + 1; // inflate the committed amount
    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.InboundMismatch.selector, mid));
    s_app.refundToSource{value: 0.05 ether}(bad);
    assertTrue(s_app.isFailed(mid), "still failed after a tampered attempt");

    // The faithful reconstruction succeeds.
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(_inboundCcip(AMOUNT, mid, ""));
    assertTrue(s_app.isRefunded(mid), "refunded with the faithful reconstruction");
  }

  function test_ProcessInbound_OnlySelf() public {
    MultiChannelBridgeAdapter.Inbound memory inb = _inboundCcip(AMOUNT, keccak256("x"), "");
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.NotSelf.selector, address(this)));
    s_app.processInbound(inb);
  }

  /*//////////////////////////////////////////////////////////////
                        QUOTES / ADMIN / INTROSPECTION
  //////////////////////////////////////////////////////////////*/

  function test_Quotes() public {
    s_ccipRouter.setFee(0.05 ether);
    s_oft.setNativeFee(0.07 ether);
    assertEq(s_app.quoteCcip(DST_SELECTOR, s_recipient, address(s_token), AMOUNT, "", 0, address(0)), 0.05 ether);
    assertEq(
      s_app.quoteOft(
        DST_EID, bytes32(uint256(uint160(s_recipient))), address(s_oft), AMOUNT, 0, "", s_app.lzReceiveOption(200_000)
      ),
      0.07 ether
    );
  }

  function test_Config_OnlyAdmin() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), s_app.DEFAULT_ADMIN_ROLE()
      )
    );
    s_app.setCcipDestination(1, true);
  }

  function test_RecoverNative_OwnerFeeFloatOnly() public {
    // Only the operator's own native fee float is recoverable; there is no owner token-recovery
    // path (rescueToken was removed — failed user tokens are recovered permissionlessly).
    vm.prank(s_owner);
    s_app.recoverNative(s_recipient, 1 ether);
    assertEq(s_recipient.balance, 1 ether);
  }

  function test_SupportsInterface_AndGetRouter() public view {
    // IERC165
    assertTrue(s_app.supportsInterface(0x01ffc9a7));
    assertEq(s_app.getRouter(), address(s_ccipRouter));
  }

  /*//////////////////////////////////////////////////////////////
                  CCIP ERC-20 FEE-TOKEN PAYMENT
  //////////////////////////////////////////////////////////////*/

  function test_CcipSend_FeeInBridgedToken() public {
    // Pay the CCIP fee in the bridged token itself (e.g. bridge LINK, fee in LINK): the router
    // pulls fee + amount from ONE combined allowance instead of two overwriting approvals.
    uint256 fee = 5e18;
    s_ccipRouter.setFee(fee);
    s_token.mint(address(s_app), AMOUNT + fee);

    (, uint256 paidFee) = s_app.sendViaCcip(DST_SELECTOR, s_recipient, address(s_token), AMOUNT, address(s_token));

    assertEq(paidFee, fee, "fee quoted in the bridged token");
    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT + fee, "router pulled amount + fee");
    assertEq(s_token.balanceOf(address(s_app)), 0, "nothing retained");
    assertEq(s_token.allowance(address(s_app), address(s_ccipRouter)), 0, "allowance reset after send");
  }

  function test_CcipSend_FeeInSeparateErc20() public {
    // A distinct ERC-20 fee token still works, and both allowances are reset afterwards.
    MockERC20 feeToken = new MockERC20("ChainLink", "LINK", 18);
    uint256 fee = 3e18;
    s_ccipRouter.setFee(fee);
    s_token.mint(address(s_app), AMOUNT);
    feeToken.mint(address(s_app), fee);

    s_app.sendViaCcip(DST_SELECTOR, s_recipient, address(s_token), AMOUNT, address(feeToken));

    assertEq(s_token.balanceOf(address(s_ccipRouter)), AMOUNT, "router pulled the bridged amount");
    assertEq(feeToken.balanceOf(address(s_ccipRouter)), fee, "router pulled the fee");
    assertEq(s_token.allowance(address(s_app), address(s_ccipRouter)), 0, "token allowance reset");
    assertEq(feeToken.allowance(address(s_app), address(s_ccipRouter)), 0, "fee-token allowance reset");
  }

  /*//////////////////////////////////////////////////////////////
                                PAUSE
  //////////////////////////////////////////////////////////////*/

  function test_Pause_CapturesInbound_FailSafe() public {
    vm.prank(s_owner);
    s_app.pause();

    bytes32 mid = keccak256("paused");
    _deliverCcip(AMOUNT, mid, ""); // would normally be held; paused -> captured, not bricked
    assertTrue(s_app.isFailed(mid), "paused inbound captured (fail-safe)");
    assertEq(s_token.balanceOf(address(s_app)), AMOUNT, "tokens retained");

    vm.prank(s_owner);
    s_app.unpause();
    bytes32 mid2 = keccak256("after-unpause");
    _deliverCcip(AMOUNT, mid2, "");
    assertFalse(s_app.isFailed(mid2), "processed normally after unpause");
    assertEq(s_app.lastAmount(), AMOUNT, "recorded after unpause");
  }

  function test_Pause_OnlyAdmin() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), s_app.DEFAULT_ADMIN_ROLE()
      )
    );
    s_app.pause();
  }

  /*//////////////////////////////////////////////////////////////
                            ADMIN HANDOFF
  //////////////////////////////////////////////////////////////*/

  function test_TransferAdmin_RevertsOnSelf() public {
    // A self-transfer would grant (no-op) then revoke the sole admin -> zero admins forever. Guarded.
    vm.prank(s_owner);
    vm.expectRevert(MultiChannelBridgeAdapter.CannotTransferAdminToSelf.selector);
    s_app.transferAdmin(s_owner, address(0), address(0));
    assertTrue(s_app.hasRole(s_app.DEFAULT_ADMIN_ROLE(), s_owner), "still admin");
  }

  function test_TransferAdmin_MigratesAdminAndFeeRoles() public {
    address newAdmin = makeAddr("newAdmin");
    address feeSetter = makeAddr("feeSetter");
    address feeCollector = makeAddr("feeCollector");

    vm.prank(s_owner);
    s_app.transferAdmin(newAdmin, feeSetter, feeCollector);

    assertTrue(s_app.hasRole(s_app.DEFAULT_ADMIN_ROLE(), newAdmin), "new admin");
    assertFalse(s_app.hasRole(s_app.DEFAULT_ADMIN_ROLE(), s_owner), "old admin revoked");
    assertTrue(s_app.hasRole(s_app.FEE_SETTER_ROLE(), feeSetter), "new fee setter");
    assertFalse(s_app.hasRole(s_app.FEE_SETTER_ROLE(), s_owner), "old fee setter revoked");
    assertTrue(s_app.hasRole(s_app.FEE_COLLECTOR_ROLE(), feeCollector), "new fee collector");
    assertFalse(s_app.hasRole(s_app.FEE_COLLECTOR_ROLE(), s_owner), "old fee collector revoked");
  }

  function test_TransferAdmin_ZeroFeeRolesLeavesThemUnchanged() public {
    address newAdmin = makeAddr("newAdmin");
    vm.prank(s_owner);
    s_app.transferAdmin(newAdmin, address(0), address(0));

    assertTrue(s_app.hasRole(s_app.DEFAULT_ADMIN_ROLE(), newAdmin), "admin moved");
    assertFalse(s_app.hasRole(s_app.DEFAULT_ADMIN_ROLE(), s_owner), "old admin revoked");
    // Fee roles left untouched -> still held by the original owner (explicit opt-out).
    assertTrue(s_app.hasRole(s_app.FEE_SETTER_ROLE(), s_owner), "fee setter unchanged");
    assertTrue(s_app.hasRole(s_app.FEE_COLLECTOR_ROLE(), s_owner), "fee collector unchanged");
  }
}
