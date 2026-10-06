// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CrossChainVaultAdapter} from "../../../src/multibridge/examples/CrossChainVaultAdapter.sol";
import {MockCcipRouter} from "../mocks/MockCcipRouter.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockOFT} from "../mocks/MockOFT.sol";
import {MockUsdt} from "../mocks/MockUsdt.sol";

/// @notice Proves the adapter handles NATIVE USDT — both Ethereum-mainnet form (6 decimals,
///         non-standard: no-bool returns, approve-race, latent fee, blocklist) and the BNB Chain form
///         (18 decimals) — as the vault asset, end to end (deposit USDT -> shares; redeem shares ->
///         USDT), routed USDT over LayerZero (USDT0-style OFT) and shares over CCIP. Validates that
///         `SafeERC20.forceApprove` + balance-delta accounting are sufficient for native USDT.
contract NativeUsdtTest is Test {
  error ShareTransferFailed();

  address internal s_owner = makeAddr("owner");
  address internal s_lzEndpoint = makeAddr("lzEndpoint");
  address internal s_srcUser = makeAddr("srcUser");
  address internal s_user = makeAddr("user");
  MockCcipRouter internal s_ccipRouter;

  uint32 internal constant SRC_EID = 30_101;
  uint32 internal constant DST_EID = 30_110; // LayerZero destination (USDT out)
  uint64 internal constant SRC_SELECTOR = 5_009_297_550_715_157_269;
  uint64 internal constant DST_SELECTOR = 4_949_039_107_694_359_620; // CCIP destination (shares out)

  struct Env {
    address usdt;
    MockERC4626 vault;
    MockOFT usdtOft;
    CrossChainVaultAdapter app;
  }

  function setUp() public {
    s_ccipRouter = new MockCcipRouter();
    s_ccipRouter.setFee(0.01 ether);
  }

  /*//////////////////////////////////////////////////////////////
                               SETUP
  //////////////////////////////////////////////////////////////*/

  /// @dev Deploys a vault over a given native-USDT token + wires the app (USDT in/out over LayerZero
  ///      USDT0-style OFT; shares in/out over CCIP).
  function _deploy(
    address usdt
  ) internal returns (Env memory e) {
    e.usdt = usdt;
    e.vault = new MockERC4626(IERC20(usdt), "Vault USDT", "vUSDT");
    e.usdtOft = new MockOFT(usdt, 6); // USDT0 shared decimals = 6
    e.usdtOft.setNativeFee(0.02 ether);

    CrossChainVaultAdapter impl = new CrossChainVaultAdapter();
    e.app = CrossChainVaultAdapter(payable(Clones.clone(address(impl))));
    e.app.initialize(address(s_ccipRouter), s_lzEndpoint, s_owner, address(e.vault));

    vm.startPrank(s_owner);
    e.app.setLzOft(SRC_EID, address(e.usdtOft), true); // USDT arrives over LZ (USDT0 OFT)
    e.app.setCcipSource(SRC_SELECTOR, true); // shares arrive over CCIP
    e.app.setCcipDestination(DST_SELECTOR, true); // shares out over CCIP
    e.app.setLzDestination(DST_EID, true); // USDT out over LZ
    e.app.setOftForToken(usdt, address(e.usdtOft)); // USDT's OFT (USDT0)
    vm.stopPrank();

    // Seed the vault so it is never empty.
    _mintShares(e, address(this), _unit(usdt) * 1000);
    vm.deal(address(e.app), 100 ether);
    return e;
  }

  /// @dev One whole token in the USDT's own decimals.
  function _unit(
    address usdt
  ) internal view returns (uint256) {
    return 10 ** MockUsdt(usdt).decimals();
  }

  /// @dev OFT LD->SD conversion rate (shared decimals = 6): 1 for 6-dec USDT, 1e12 for 18-dec.
  function _oftRate(
    address usdt
  ) internal view returns (uint256) {
    uint8 d = MockUsdt(usdt).decimals();
    return d > 6 ? 10 ** (d - 6) : 1;
  }

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

  /// @dev Mints `shares` vault shares to `to` (by minting + depositing the required native USDT).
  function _mintShares(
    Env memory e,
    address to,
    uint256 shares
  ) internal {
    uint256 assets = e.vault.previewMint(shares);
    MockUsdt(e.usdt).mint(address(this), assets);
    SafeERC20.forceApprove(IERC20(e.usdt), address(e.vault), assets); // forceApprove: native-USDT approve-race safe
    e.vault.mint(shares, address(this));
    if (!e.vault.transfer(to, shares)) revert ShareTransferFailed();
  }

  /// @dev Delivers native USDT to the app over LayerZero (USDT0 OFT credits the token, then lzCompose).
  function _deliverUsdtLz(
    Env memory e,
    uint256 amount,
    bytes32 guid,
    uint64 nonce,
    bytes memory data
  ) internal {
    MockUsdt(e.usdt).mint(address(e.app), amount);
    bytes memory composeMsg = abi.encodePacked(_bz(s_srcUser), data);
    bytes memory message = OFTComposeMsgCodec.encode(nonce, SRC_EID, amount, composeMsg);
    vm.prank(s_lzEndpoint);
    e.app.lzCompose(address(e.usdtOft), guid, message, address(0), "");
  }

  /// @dev Delivers vault shares to the app over CCIP.
  function _deliverSharesCcip(
    Env memory e,
    uint256 shares,
    bytes32 messageId,
    bytes memory data
  ) internal {
    _mintShares(e, address(s_ccipRouter), shares);
    Client.EVMTokenAmount[] memory ta = new Client.EVMTokenAmount[](1);
    ta[0] = Client.EVMTokenAmount({token: address(e.vault), amount: shares});
    Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
      messageId: messageId,
      sourceChainSelector: SRC_SELECTOR,
      sender: abi.encode(s_srcUser),
      data: data,
      destTokenAmounts: ta
    });
    s_ccipRouter.deliverToReceiver(address(e.app), m);
  }

  /*//////////////////////////////////////////////////////////////
            ETHEREUM NATIVE USDT (6 dec, non-standard ERC-20)
  //////////////////////////////////////////////////////////////*/

  function test_EthUsdt_Deposit_NonStandardHandled() public {
    Env memory e = _deploy(address(new MockUsdt("Tether USD", "USDT", 6)));
    uint256 amount = 100e6;
    uint256 expShares = e.vault.previewDeposit(amount);

    _deliverUsdtLz(e, amount, keccak256("eth-d"), 1, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(e.vault.balanceOf(address(s_ccipRouter)), expShares, "shares bridged out via CCIP");
    assertEq(MockUsdt(e.usdt).balanceOf(address(e.app)), 0, "no USDT retained (deposited)");
  }

  function test_EthUsdt_Redeem_OutOverOft() public {
    Env memory e = _deploy(address(new MockUsdt("Tether USD", "USDT", 6)));
    uint256 shares = 100e6;
    uint256 expAssets = e.vault.previewRedeem(shares);

    _deliverSharesCcip(e, shares, keccak256("eth-r"), _msg(0, DST_EID, _bz(s_user)));

    // 6-dec USDT over 6-shared OFT => no dust; full amount locked in the OFT.
    assertEq(MockUsdt(e.usdt).balanceOf(address(e.usdtOft)), expAssets, "USDT bridged out (locked in OFT)");
  }

  function test_EthUsdt_ApproveRace_HandledAcrossDeposits() public {
    Env memory e = _deploy(address(new MockUsdt("Tether USD", "USDT", 6)));
    // Two back-to-back deposits: each forceApproves the vault. A bare approve would revert on the
    // second (non-zero -> non-zero); forceApprove zeroes first, so both succeed.
    _deliverUsdtLz(e, 50e6, keccak256("a1"), 1, _msg(0, DST_SELECTOR, _bz(s_user)));
    _deliverUsdtLz(e, 70e6, keccak256("a2"), 2, _msg(0, DST_SELECTOR, _bz(s_user)));
    assertEq(MockUsdt(e.usdt).balanceOf(address(e.app)), 0, "both deposits cleared");
  }

  /// @dev Sanity: the mock really is non-standard (bare IERC20 reverts; SafeERC20 + forceApprove work).
  function test_NativeUsdt_IsNonStandard_SafeERC20Works() public {
    MockUsdt usdt = new MockUsdt("Tether USD", "USDT", 6);
    usdt.mint(address(this), 100e6);
    address spender = makeAddr("spender");

    // approve-race: 0->100 ok, 100->200 reverts, forceApprove rescues.
    usdt.approve(spender, 100e6);
    vm.expectRevert(MockUsdt.UsdtApproveRace.selector);
    usdt.approve(spender, 200e6);
    SafeERC20.forceApprove(IERC20(address(usdt)), spender, 200e6);
    assertEq(usdt.allowance(address(this), spender), 200e6, "forceApprove set new allowance");

    // No-bool transfer works via SafeERC20; the raw transfer returns NO data (non-standard).
    SafeERC20.safeTransfer(IERC20(address(usdt)), s_user, 10e6);
    assertEq(usdt.balanceOf(s_user), 10e6, "safeTransfer moved USDT");
    (bool ok, bytes memory ret) = address(usdt).call(abi.encodeWithSelector(usdt.transfer.selector, s_user, 1e6));
    assertTrue(ok, "raw transfer executed");
    assertEq(ret.length, 0, "USDT transfer returns NO boolean (non-standard) -> SafeERC20 required");
  }

  /*//////////////////////////////////////////////////////////////
                BNB CHAIN NATIVE USDT (18 decimals)
  //////////////////////////////////////////////////////////////*/

  function test_BscUsdt_Deposit_18Decimals() public {
    Env memory e = _deploy(address(new MockUsdt("Binance-Peg BSC-USD", "USDT", 18)));
    uint256 amount = 100e18;
    uint256 expShares = e.vault.previewDeposit(amount);

    _deliverUsdtLz(e, amount, keccak256("bsc-d"), 1, _msg(0, DST_SELECTOR, _bz(s_user)));

    assertEq(e.vault.balanceOf(address(s_ccipRouter)), expShares, "shares out (18-dec asset)");
  }

  function test_BscUsdt_Redeem_18Decimals_DustFloored() public {
    Env memory e = _deploy(address(new MockUsdt("Binance-Peg BSC-USD", "USDT", 18)));
    uint256 shares = 100e18;
    uint256 expAssets = e.vault.previewRedeem(shares);
    uint256 rate = _oftRate(e.usdt); // 1e12 for 18-dec over 6-shared
    uint256 expSent = expAssets - (expAssets % rate);

    _deliverSharesCcip(e, shares, keccak256("bsc-r"), _msg(0, DST_EID, _bz(s_user)));

    assertEq(MockUsdt(e.usdt).balanceOf(address(e.usdtOft)), expSent, "USDT out, shared-decimals dust floored");
  }
}
