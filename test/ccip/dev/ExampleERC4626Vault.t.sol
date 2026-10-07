// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts@5.1.0/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {CrossChainERC4626Adapter} from "../../../src/ccip/CrossChainERC4626Adapter.sol";
import {ExampleERC4626Vault} from "../../../src/ccip/dev/ExampleERC4626Vault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRouterClient} from "../mocks/MockRouterClient.sol";

/// @notice Unit tests for `ExampleERC4626Vault` and its use as an adapter target.
contract ExampleERC4626VaultTest is Test {
  uint64 internal constant SOURCE_CHAIN_SELECTOR = 3478487238524512106;
  uint256 internal constant AMOUNT = 0.1 ether;
  uint256 internal constant ADAPTER_FEE = 0.001 ether;
  address internal constant OWNER = address(0x0A11);
  address internal constant USER = address(0xA11CE);
  address internal constant BENEFICIARY = address(0xBEEF);

  MockERC20 internal s_asset;
  ExampleERC4626Vault internal s_vault;
  MockRouterClient internal s_router;
  CrossChainERC4626Adapter internal s_adapter;

  function setUp() public {
    s_asset = new MockERC20("CCIP-BnM", "CCIP-BnM", 18);
    s_vault = new ExampleERC4626Vault(IERC20(address(s_asset)), "Vault CCIP-BnM", "vCCIP-BnM", OWNER);

    s_router = new MockRouterClient();
    s_router.setSupportedChain(SOURCE_CHAIN_SELECTOR, true);
    s_adapter = new CrossChainERC4626Adapter(address(s_router), address(this), address(this), address(this));
    s_adapter.setChainType(SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);
    s_adapter.setTargetEnabled(address(s_vault), true);
    s_adapter.setProcessingEnabled(true, true);
    vm.deal(address(s_adapter), 1 ether);
  }

  function test_constructor_sets_metadata_and_owner() public view {
    assertEq(s_vault.asset(), address(s_asset));
    assertEq(s_vault.name(), "Vault CCIP-BnM");
    assertEq(s_vault.symbol(), "vCCIP-BnM");
    assertEq(s_vault.decimals(), 18);
    assertEq(s_vault.owner(), OWNER);
  }

  function test_constructor_reverts_for_zero_owner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new ExampleERC4626Vault(IERC20(address(s_asset)), "Vault CCIP-BnM", "vCCIP-BnM", address(0));
  }

  function test_deposit_and_redeem_are_one_to_one() public {
    s_asset.mint(USER, 1 ether);
    vm.startPrank(USER);
    s_asset.approve(address(s_vault), 1 ether);
    assertEq(s_vault.deposit(1 ether, USER), 1 ether);
    assertEq(s_vault.balanceOf(USER), 1 ether);
    assertEq(s_vault.totalAssets(), 1 ether);
    assertEq(s_vault.convertToAssets(1 ether), 1 ether);
    assertEq(s_vault.redeem(AMOUNT, USER, USER), AMOUNT);
    vm.stopPrank();
    assertEq(s_asset.balanceOf(USER), AMOUNT);
  }

  function test_adapter_deposit_local_delivery() public {
    _route(address(s_asset), AMOUNT, _payload(AMOUNT, false));
    assertEq(s_vault.balanceOf(BENEFICIARY), AMOUNT);
    assertEq(s_adapter.collectedFees(address(s_asset)), 0);
  }

  function test_adapter_deposit_return_charges_fee() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), ADAPTER_FEE);
    uint256 expected = AMOUNT - ADAPTER_FEE;
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), AMOUNT, true, SOURCE_CHAIN_SELECTOR), expected);

    _route(address(s_asset), AMOUNT, _payload(expected, true));
    assertEq(s_router.lastToken(), address(s_vault));
    assertEq(s_router.lastAmount(), expected);
    assertEq(s_router.lastDestinationChainSelector(), SOURCE_CHAIN_SELECTOR);
    assertEq(s_adapter.collectedFees(address(s_asset)), ADAPTER_FEE);
  }

  function test_adapter_redeem_return_charges_fee() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), ADAPTER_FEE);
    s_asset.mint(USER, AMOUNT);
    vm.startPrank(USER);
    s_asset.approve(address(s_vault), AMOUNT);
    s_vault.deposit(AMOUNT, address(s_router));
    vm.stopPrank();
    uint256 expected = AMOUNT - ADAPTER_FEE;
    assertEq(s_adapter.preview(address(s_vault), address(s_vault), AMOUNT, true, SOURCE_CHAIN_SELECTOR), expected);

    _route(address(s_vault), AMOUNT, _payload(expected, true));
    assertEq(s_router.lastToken(), address(s_asset));
    assertEq(s_router.lastAmount(), expected);
    assertEq(s_adapter.collectedFees(address(s_asset)), ADAPTER_FEE);
  }

  function test_adapter_minimum_output_not_met_fails_message() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), ADAPTER_FEE);
    bytes32 messageId = _route(address(s_asset), AMOUNT, _payload(AMOUNT, true));
    assertEq(uint256(s_adapter.messageErrorCode(messageId)), uint256(CrossChainERC4626Adapter.ErrorCode.BASIC));
    assertEq(s_asset.balanceOf(address(s_adapter)), AMOUNT);
    assertEq(s_vault.totalSupply(), 0);
  }

  function _route(
    address token,
    uint256 amount,
    bytes memory payload
  ) internal returns (bytes32 messageId) {
    if (token == address(s_asset)) s_asset.mint(address(s_router), amount);
    messageId = keccak256(abi.encode(token, amount, payload));
    Client.Any2EVMMessage memory message;
    message.messageId = messageId;
    message.sourceChainSelector = SOURCE_CHAIN_SELECTOR;
    message.sender = abi.encode(USER);
    message.data = payload;
    message.destTokenAmounts = new Client.EVMTokenAmount[](1);
    message.destTokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
    s_router.routeMessage(address(s_adapter), message);
    return messageId;
  }

  /// @dev 128-byte payload: target, beneficiary, minimumOut, deliveryAndRefund (bit 0 = return to source chain).
  function _payload(
    uint256 minimumOut,
    bool returnToSourceChain
  ) internal view returns (bytes memory) {
    return abi.encode(
      address(s_vault), bytes32(uint256(uint160(BENEFICIARY))), minimumOut, returnToSourceChain ? 1 : uint256(0)
    );
  }
}
