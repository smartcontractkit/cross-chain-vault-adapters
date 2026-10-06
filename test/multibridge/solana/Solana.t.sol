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

/// @notice Solana (non-EVM, 32-byte addresses) over all three rails. SENDING: CCIP uses the SVM
///         encoding (`SVMExtraArgsV1` + 32-byte `tokenReceiver`, empty `receiver`); LayerZero & Stargate
///         already carry a 32-byte `to`. RECEIVING: a 32-byte Solana sender survives normalisation on
///         every rail, and a CCIP refund bounces back to it over SVM (no truncation anywhere).
contract SolanaTest is Test {
  error ShareTransferFailed();

  CrossChainVaultAdapter internal s_app;
  MockERC20 internal s_usdt; // 6-dec native USDT (vault asset)
  MockERC4626 internal s_vault;
  MockOFT internal s_usdtOft; // USDT0 / Legacy-Mesh OFT (reaches Solana)
  MockStargate internal s_sgUsdt; // Stargate USDT pool (has a Solana pool)
  MockCcipRouter internal s_ccipRouter;

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");

  // Solana addresses are 32 bytes with high bytes set — truncation to an EVM address would lose data.
  bytes32 internal constant SOL_RECIPIENT = keccak256("solana-recipient-wallet");
  bytes32 internal constant SOL_SENDER = keccak256("solana-source-sender");

  uint32 internal constant SOL_EID = 30_168; // Solana LayerZero EID (illustrative)
  uint64 internal constant SOL_SELECTOR = 124_615_329_519_749_607; // Solana CCIP selector (illustrative)
  uint16 internal constant LP_FEE_BPS = 10;

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
    // Inbound from Solana: a CCIP source (32-byte sender) and an OFT compose (USDT0 mesh).
    s_app.setCcipSource(SOL_SELECTOR, true);
    s_app.setLzOft(SOL_EID, address(s_usdtOft), true);
    // Outbound to Solana, all three rails.
    s_app.setCcipDestination(SOL_SELECTOR, true);
    s_app.setCcipSvmConfig(SOL_SELECTOR, true, 0); // mark the selector a Solana (SVM) lane
    s_app.setLzDestination(SOL_EID, true);
    s_app.setStargateDestination(SOL_EID, true);
    s_app.setOftForToken(address(s_usdt), address(s_usdtOft)); // legacy default + inbound bounce
    vm.stopPrank();

    // Seed the vault 1:1.
    s_usdt.mint(address(this), 1000e6);
    s_usdt.approve(address(s_vault), 1000e6);
    s_vault.deposit(1000e6, address(this));

    vm.deal(address(s_app), 100 ether);
    s_ccipRouter.setFee(0.01 ether);
    s_usdtOft.setNativeFee(0.02 ether);
    s_sgUsdt.setNativeFee(0.02 ether);
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

  function _route(
    RouteRegistry.Rail rail,
    address endpoint,
    uint64 dstId
  ) internal pure returns (RouteRegistry.Route memory) {
    return RouteRegistry.Route({enabled: true, rail: rail, endpoint: endpoint, dstId: dstId});
  }

  /// @dev Delivers `shares` over CCIP (a redeem inbound, EVM source) producing USDT to route out.
  function _redeemInCcipEvm(
    uint256 shares,
    bytes32 id,
    bytes memory data
  ) internal {
    _mintSharesTo(address(s_ccipRouter), shares);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_vault), amount: shares});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: id,
      sourceChainSelector: SOL_SELECTOR,
      sender: abi.encode(address(this)),
      data: data,
      destTokenAmounts: ta
    });
    // EVM source allowlist for this redeem helper.
    vm.prank(s_owner);
    s_app.setCcipSource(SOL_SELECTOR, true);
    s_ccipRouter.deliverToReceiver(address(s_app), m);
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

  /// @dev Decodes a CCIP `extraArgs` blob (4-byte tag + SVMExtraArgsV1) back to the struct.
  function _decodeSvm(
    bytes memory ea
  ) internal pure returns (Client.SVMExtraArgsV1 memory) {
    bytes memory body = new bytes(ea.length - 4);
    for (uint256 i; i < body.length; ++i) {
      body[i] = ea[i + 4];
    }
    return abi.decode(body, (Client.SVMExtraArgsV1));
  }

  /*//////////////////////////////////////////////////////////////
                          SENDING TO SOLANA
  //////////////////////////////////////////////////////////////*/

  function test_Send_CcipToSolana_SvmEncoding_FullRecipient() public {
    vm.prank(s_owner);
    s_app.setRoute(address(s_usdt), SOL_SELECTOR, _route(RouteRegistry.Rail.CCIP_SVM, address(0), SOL_SELECTOR));

    uint256 shares = 100e6;
    uint256 expAssets = s_vault.previewRedeem(shares);
    _redeemInCcipEvm(shares, keccak256("ccip-sol"), _msg(0, SOL_SELECTOR, SOL_RECIPIENT));

    assertEq(s_usdt.balanceOf(address(s_ccipRouter)), expAssets, "USDT bridged out via CCIP");
    // The CCIP message used the SVM encoding with the FULL 32-byte recipient (no truncation).
    bytes memory ea = s_ccipRouter.s_lastExtraArgs();
    assertEq(bytes4(ea), Client.SVM_EXTRA_ARGS_V1_TAG, "SVM extra-args tag");
    Client.SVMExtraArgsV1 memory a = _decodeSvm(ea);
    assertEq(a.tokenReceiver, SOL_RECIPIENT, "32-byte Solana token receiver preserved");
    assertTrue(a.allowOutOfOrderExecution, "OOO set for SVM lane");
    // Token-only transfer: the message `receiver` is the 32-byte ZERO word (the FeeQuoter requires
    // exactly 32 bytes and rejects empty bytes).
    assertEq(s_ccipRouter.s_lastReceiver(), abi.encode(bytes32(0)), "SVM receiver encoded as the 32-byte zero word");
  }

  function test_Send_LayerZeroToSolana_Bytes32Preserved() public {
    vm.prank(s_owner);
    s_app.setRoute(address(s_usdt), SOL_EID, _route(RouteRegistry.Rail.LZ_OFT, address(s_usdtOft), SOL_EID));

    uint256 shares = 100e6;
    _redeemInCcipEvm(shares, keccak256("lz-sol"), _msg(0, SOL_EID, SOL_RECIPIENT));

    assertEq(s_usdtOft.s_lastTo(), SOL_RECIPIENT, "32-byte Solana recipient reached the OFT untouched");
  }

  function test_Send_StargateToSolana_Bytes32Preserved() public {
    vm.prank(s_owner);
    s_app.setRoute(address(s_usdt), SOL_EID, _route(RouteRegistry.Rail.STARGATE, address(s_sgUsdt), SOL_EID));

    uint256 shares = 100e6;
    _redeemInCcipEvm(shares, keccak256("sg-sol"), _msg(0, SOL_EID, SOL_RECIPIENT));

    assertEq(s_sgUsdt.s_lastTo(), SOL_RECIPIENT, "32-byte Solana recipient reached the Stargate pool untouched");
  }

  /*//////////////////////////////////////////////////////////////
                        RECEIVING FROM SOLANA
  //////////////////////////////////////////////////////////////*/

  /// @dev USDT arriving from Solana over LayerZero (USDT0 mesh) then redeployed out: proves a 32-byte
  ///      Solana sender is accepted (allowlisted as bytes32) and processed.
  function test_Receive_LayerZeroFromSolana_SenderAccepted() public {
    // route the produced shares back out to Solana over the same OFT (share OFT == reuse usdtOft? no:
    // shares != USDT). Keep it simple: deliver shares out over CCIP to an EVM dest.
    vm.startPrank(s_owner);
    s_app.setCcipDestination(SOL_SELECTOR, true);
    MockOFT shareOft = new MockOFT(address(s_vault), 6);
    s_app.setLzDestination(SOL_EID, true);
    s_app.setRoute(address(s_vault), SOL_EID, _route(RouteRegistry.Rail.LZ_OFT, address(shareOft), SOL_EID));
    vm.stopPrank();
    shareOft.setNativeFee(0.02 ether);

    uint256 amount = 100e6;
    s_usdt.mint(address(s_app), amount);
    // OFT compose whose `composeFrom` is the 32-byte Solana sender.
    bytes memory composeMsg = abi.encodePacked(SOL_SENDER, _msg(0, SOL_EID, SOL_RECIPIENT));
    bytes memory message = OFTComposeMsgCodec.encode(1, SOL_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    s_app.lzCompose(address(s_usdtOft), keccak256("lz-from-sol"), message, address(0), "");

    assertFalse(s_app.isFailed(keccak256("lz-from-sol")), "deposit from Solana processed");
    assertEq(shareOft.s_lastTo(), SOL_RECIPIENT, "shares routed back to the Solana recipient");
  }

  /// @dev USDT from Solana over CCIP with a slippage breach: the base captures it, then a permissionless
  ///      refund bounces it back to the FULL 32-byte Solana sender over the SVM encoding.
  function test_Receive_CcipFromSolana_FailedRefundBouncesSvm() public {
    uint256 amount = 100e6;
    // Deposit (asset in) with an unreachable minOut -> slippage breach -> capture.
    uint256 tooMuch = s_vault.previewDeposit(amount) + 1;
    bytes memory data = _msg(tooMuch, SOL_EID, SOL_RECIPIENT);

    s_usdt.mint(address(s_ccipRouter), amount);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(s_usdt), amount: amount});
    bytes32 id = keccak256("ccip-from-sol");
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: id, sourceChainSelector: SOL_SELECTOR, sender: abi.encode(SOL_SENDER), data: data, destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(s_app), m);

    assertTrue(s_app.isFailed(id), "captured: slippage breach on Solana-sourced deposit");
    assertEq(s_usdt.balanceOf(address(s_app)), amount, "inbound USDT retained");

    // Reconstruct the captured Inbound (from the MessageFailed event); hash-verified by the base.
    MultiChannelBridgeAdapter.Inbound memory inb = MultiChannelBridgeAdapter.Inbound({
      channel: MultiChannelBridgeAdapter.Channel.CCIP,
      srcId: SOL_SELECTOR,
      sender: SOL_SENDER,
      guid: id,
      tokens: ta,
      data: data,
      lzOft: address(0)
    });
    address bot = makeAddr("bot");
    vm.deal(bot, 1 ether);
    vm.prank(bot);
    s_app.refundToSource{value: 0.05 ether}(inb);

    assertTrue(s_app.isRefunded(id), "refunded to Solana source");
    assertEq(s_usdt.balanceOf(address(s_ccipRouter)), amount, "USDT bounced back over CCIP");
    bytes memory ea = s_ccipRouter.s_lastExtraArgs();
    assertEq(bytes4(ea), Client.SVM_EXTRA_ARGS_V1_TAG, "bounce used SVM encoding");
    assertEq(_decodeSvm(ea).tokenReceiver, SOL_SENDER, "bounced to the full 32-byte Solana sender");
    assertEq(s_ccipRouter.s_lastReceiver(), abi.encode(bytes32(0)), "refund receiver encoded as the 32-byte zero word");
  }

  /*//////////////////////////////////////////////////////////////
                                CONFIG
  //////////////////////////////////////////////////////////////*/

  function test_CcipSvmConfig_SetAndCleared() public {
    vm.startPrank(s_owner);
    s_app.setCcipSvmConfig(SOL_SELECTOR, true, 0);
    vm.stopPrank();
    (bool enabled, uint32 cu, bool ooo) = s_app.s_ccipSvm(SOL_SELECTOR);
    assertTrue(enabled);
    assertEq(cu, 0);
    assertTrue(ooo);
  }

  function test_CcipSvmConfig_RejectsNonZeroComputeUnits() public {
    // Token-only lanes require computeUnits == 0 (the FeeQuoter rejects a non-zero budget when the
    // receiver is the zero word); a bad value must fail at set time, not at every send.
    vm.prank(s_owner);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.SvmComputeUnitsNotZero.selector, uint32(1234)));
    s_app.setCcipSvmConfig(SOL_SELECTOR, true, 1234);
  }

  function test_CcipSvmConfig_OnlyOwner() public {
    vm.expectRevert();
    s_app.setCcipSvmConfig(SOL_SELECTOR, true, 0);
  }

  /*//////////////////////////////////////////////////////////////
      CCIP_SVM REQUIRES THE SELECTOR'S SVM CONFIG ENABLED
  //////////////////////////////////////////////////////////////*/

  function test_SetRoute_CcipSvm_RejectsNonSvmSelector() public {
    // A CCIP_SVM route to a selector never marked SVM must fail at configuration time.
    uint64 evmSelector = 4_949_039_107_694_359_620; // plain EVM CCIP selector, no SVM config
    vm.startPrank(s_owner);
    s_app.setCcipDestination(evmSelector, true);
    vm.expectRevert(abi.encodeWithSelector(MultiChannelBridgeAdapter.SvmLaneNotEnabled.selector, evmSelector));
    s_app.setRoute(address(s_usdt), evmSelector, _route(RouteRegistry.Rail.CCIP_SVM, address(0), evmSelector));
    vm.stopPrank();
  }

  function test_Send_CcipSvm_LaneDisabledAfterRouteSet_Captured() public {
    vm.startPrank(s_owner);
    s_app.setRoute(address(s_usdt), SOL_SELECTOR, _route(RouteRegistry.Rail.CCIP_SVM, address(0), SOL_SELECTOR));
    // Operator later clears the SVM config: the still-enabled route must fail loudly, not misencode.
    s_app.setCcipSvmConfig(SOL_SELECTOR, false, 0);
    vm.stopPrank();

    bytes32 id = keccak256("svm-disabled");
    _redeemInCcipEvm(100e6, id, _msg(0, SOL_SELECTOR, SOL_RECIPIENT));

    // The send reverts (SvmLaneNotEnabled) -> base captures the inbound shares for recovery.
    assertTrue(s_app.isFailed(id), "captured: SVM lane not enabled for the route's selector");
  }
}
