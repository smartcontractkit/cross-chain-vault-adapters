// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {RouteRegistry} from "../../../src/multibridge/routing/RouteRegistry.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockOFT} from "../mocks/MockOFT.sol";

/// @notice Same-chain (LOCAL) delivery: when the user routes the produced token to `destination = 0`
///         (the LOCAL_DESTINATION sentinel, mapped to a `Rail.LOCAL` route), the app transfers the ERC-20
///         straight to the recipient on this chain — no bridge, no fee. Covers deposit + redeem, the
///         return-leg/prefund interaction, and the non-EVM-recipient guard.
contract LocalDeliveryTest is Test {
  error ShareTransferFailed();

  CrossChainVaultAdapter internal s_app;
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
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;

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
    s_app.setLzOft(SRC_EID, address(s_oftAsset), true);
    s_app.setLzOft(SRC_EID, address(s_oftShare), true);
    s_app.setCcipSource(SRC_SELECTOR, true);
    // LOCAL routes for both produced tokens at the same-chain sentinel (destination 0).
    s_app.setRoute(address(s_asset), s_app.LOCAL_DESTINATION(), _local());
    s_app.setRoute(address(s_vault), s_app.LOCAL_DESTINATION(), _local());
    vm.stopPrank();

    s_asset.mint(address(this), 1000e18);
    s_asset.approve(address(s_vault), 1000e18);
    s_vault.deposit(1000e18, address(this));

    vm.deal(address(s_app), 100 ether);
    s_ccipRouter.setFee(0.01 ether);
    s_oftAsset.setNativeFee(0.02 ether);
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  function _local() internal pure returns (RouteRegistry.Route memory) {
    return RouteRegistry.Route({enabled: true, rail: RouteRegistry.Rail.LOCAL, endpoint: address(0), dstId: 0});
  }

  function _bz(
    address a
  ) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
  }

  function _msgLocal(
    bytes32 recipient
  ) internal pure returns (bytes memory) {
    return abi.encode(
      CrossChainVaultAdapter.VaultMessage({
        minAmountOut: 0, destination: 0, recipient: recipient, failedMessageHandler: address(0), onlyLocalRefund: false
      })
    );
  }

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
                            LOCAL DELIVERY
  //////////////////////////////////////////////////////////////*/

  function test_Deposit_AssetInCcip_SharesDeliveredLocally() public {
    bytes32 id = keccak256("ld1");
    uint256 amount = 100e18;
    uint256 expShares = s_vault.previewDeposit(amount);

    _deliverCcip(address(s_asset), amount, id, _msgLocal(_bz(s_user)));

    assertEq(s_vault.balanceOf(s_user), expShares, "shares transferred locally to recipient");
    assertEq(s_vault.balanceOf(address(s_app)), 0, "no shares retained");
    assertEq(s_vault.balanceOf(address(s_ccipRouter)), 0, "nothing bridged out");
    assertFalse(s_app.isFailed(id), "succeeded");
  }

  function test_Redeem_ShareInLz_AssetsDeliveredLocally() public {
    bytes32 id = keccak256("ld2");
    uint256 shares = 100e18;
    uint256 expAssets = s_vault.previewRedeem(shares);
    uint256 reserve0 = address(s_app).balance;

    _deliverLz(address(s_oftShare), shares, id, 1, _msgLocal(_bz(s_user)));

    assertEq(s_asset.balanceOf(s_user), expAssets, "assets transferred locally to recipient");
    assertEq(s_asset.balanceOf(address(s_app)), 0, "no assets retained");
    assertEq(address(s_app).balance, reserve0, "no fee spent (no bridge)");
  }

  function test_Local_LzWithValue_NoHandler_ValueStaysInReserve() public {
    bytes32 id = keccak256("ld3");
    uint256 amount = 100e18;
    uint256 reserve0 = address(s_app).balance;

    // Sender prepaid 0.02 native; LOCAL delivery costs nothing and there is no handler, so the full
    // prepaid value is left in the reserve (becomes operator float) rather than refunded.
    _deliverLzVal(address(s_oftAsset), amount, id, 1, _msgLocal(_bz(s_user)), 0.02 ether);

    assertEq(s_vault.balanceOf(s_user), s_vault.previewDeposit(amount), "shares delivered locally");
    assertEq(s_srcUser.balance, 0, "no native returned to the source sender");
    assertEq(address(s_app).balance, reserve0 + 0.02 ether, "full prepaid value retained in reserve");
  }

  function test_Local_BypassesReturnPrefundRequirement() public {
    vm.prank(s_owner);
    s_app.setRequireLzReturnPrefunded(true); // would reject a value-less LZ bridge return

    bytes32 id = keccak256("ld4");
    uint256 amount = 100e18;
    _deliverLz(address(s_oftAsset), amount, id, 1, _msgLocal(_bz(s_user))); // no value

    // LOCAL has no return leg, so the prefund requirement does not apply: it still succeeds.
    assertFalse(s_app.isFailed(id), "local delivery not blocked by prefund requirement");
    assertEq(s_vault.balanceOf(s_user), s_vault.previewDeposit(amount), "shares delivered locally");
  }

  function test_Local_NonEvmRecipient_CapturedByBase() public {
    bytes32 id = keccak256("ld5");
    uint256 amount = 100e18;
    bytes32 solanaRecipient = keccak256("solana-wallet"); // high bytes set -> not an EVM address

    _deliverCcip(address(s_asset), amount, id, _msgLocal(solanaRecipient));

    // The non-EVM recipient is rejected (NonEvmLocalRecipient) -> base captures, deposit rolled back.
    assertTrue(s_app.isFailed(id), "captured: cannot deliver locally to a non-EVM recipient");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained for recovery");
  }

  function test_Local_MinAmountOutBreach_Captured() public {
    // The user's per-tx minAmountOut is enforced (measured) on the LOCAL leg: a floor above the
    // produced shares reverts -> the base captures the inbound for recovery. No silent short delivery.
    bytes32 id = keccak256("ld-moo");
    uint256 amount = 100e18;
    uint256 tooMuch = s_vault.previewDeposit(amount) + 1;
    bytes memory data = abi.encode(
      CrossChainVaultAdapter.VaultMessage({
        minAmountOut: tooMuch,
        destination: 0,
        recipient: _bz(s_user),
        failedMessageHandler: address(0),
        onlyLocalRefund: false
      })
    );
    _deliverLz(address(s_oftAsset), amount, id, 1, data); // deposit -> shares -> LOCAL; floor exceeds produced

    assertTrue(s_app.isFailed(id), "captured on LOCAL minAmountOut breach (measured)");
    assertEq(s_vault.balanceOf(s_user), 0, "nothing delivered locally");
    assertEq(s_asset.balanceOf(address(s_app)), amount, "inbound asset retained for recovery");
  }
}
