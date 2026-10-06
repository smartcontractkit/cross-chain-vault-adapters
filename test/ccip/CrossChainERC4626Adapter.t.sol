// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IAny2EVMMessageReceiverV2} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiverV2.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {ExtraArgsCodec} from "@chainlink/contracts-ccip/contracts/libraries/ExtraArgsCodec.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";
import {IAccessControl} from "@openzeppelin/contracts@5.0.2/access/IAccessControl.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts@5.0.2/access/extensions/IAccessControlEnumerable.sol";
import {IERC165} from "@openzeppelin/contracts@5.0.2/utils/introspection/IERC165.sol";
import {Test} from "forge-std/Test.sol";

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {MockRouterClient} from "./mocks/MockRouterClient.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {RejectEtherReceiver} from "./mocks/RejectEtherReceiver.sol";

contract CrossChainERC4626AdapterTest is Test {
  uint64 internal constant SOURCE_CHAIN_SELECTOR = 111;
  uint64 internal constant SVM_CHAIN_SELECTOR = 222;
  /// @dev Selector left unconfigured (`chains[selector] == NONE`) for negative / inference tests.
  uint64 internal constant UNCONFIGURED_CHAIN_SELECTOR = 999;

  address internal constant FEE_SETTER = address(0x1001);
  address internal constant FEE_COLLECTOR = address(0x1002);
  address internal constant BENEFICIARY = address(0xBEEF);
  address internal constant LOCAL_REFUND = address(0xCAFE);
  address internal constant ORIGINAL_SENDER = address(0xA11CE);

  MockRouterClient internal s_router;
  MockERC20 internal s_asset;
  MockERC20 internal s_otherToken;
  MockERC4626Vault internal s_vault;
  CrossChainERC4626Adapter internal s_adapter;

  event TargetProcessed(
    bytes32 indexed messageId,
    address indexed target,
    address indexed inputToken,
    address outputToken,
    uint256 inputAmount,
    uint256 outputAmount
  );
  event LocalTokenDelivered(
    bytes32 indexed messageId, address indexed token, address indexed beneficiary, uint256 amount
  );
  event MessageRefunded(
    bytes32 indexed messageId, uint64 indexed destinationChainSelector, bytes32 indexed beneficiary
  );
  event MessageRecoveredLocally(bytes32 indexed messageId, address indexed localRefundAddress);
  event FeeWithdrawn(address indexed asset, address indexed recipient, uint256 amount);
  event CCVsConfigSet(
    uint64 indexed sourceChainSelector, address[] requiredCCVs, address[] optionalCCVs, uint8 optionalThreshold
  );

  event InboundFinalitySet(uint64 indexed sourceChainSelector, bytes4 allowedFinalityConfig);

  event ChainTypeSet(uint64 indexed chainSelector, CrossChainERC4626Adapter.ChainType chainType);

  receive() external payable {}

  function setUp() public {
    s_router = new MockRouterClient();
    s_router.setSupportedChain(SOURCE_CHAIN_SELECTOR, true);
    s_router.setSupportedChain(SVM_CHAIN_SELECTOR, true);

    s_asset = new MockERC20("Asset", "AST", 18);
    s_otherToken = new MockERC20("Other", "OTH", 18);
    s_vault = new MockERC4626Vault(address(s_asset), "Vault Share", "vAST");

    s_adapter = new CrossChainERC4626Adapter(address(s_router), address(this), FEE_SETTER, FEE_COLLECTOR);
    s_adapter.setChainType(SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);
    s_adapter.setChainType(SVM_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.SVM);
    s_adapter.setTargetEnabled(address(s_vault), true);
    s_adapter.setProcessingEnabled(true, true);

    vm.deal(address(s_adapter), 100 ether);
  }

  function test_typeAndVersion_returns_expected_string() public {
    assertEq(s_adapter.typeAndVersion(), "CrossChainERC4626Adapter 1.0.0");
  }

  function test_setEvmReturnLaneFormat_reverts_when_format_unset() public {
    vm.expectRevert(CrossChainERC4626Adapter.InvalidEvmReturnExtraArgsFormat.selector);
    s_adapter.setEvmReturnLaneFormat(SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.UNSET);
  }

  function test_setEvmReturnRequestedFinality_reverts_zero_token() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidTarget.selector, address(0)));
    s_adapter.setEvmReturnRequestedFinality(SOURCE_CHAIN_SELECTOR, address(0), bytes4(0));
  }

  function test_setEvmReturnRequestedFinality_reverts_when_lane_is_legacy() public {
    s_adapter.setEvmReturnLaneFormat(
      SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.LEGACY_EXTRA_ARGS_V2
    );
    bytes4 requestedFinality = FinalityCodec.WAIT_FOR_SAFE_FLAG;
    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainERC4626Adapter.UnexpectedRequestedFinalityForLegacyFormat.selector, requestedFinality
      )
    );
    s_adapter.setEvmReturnRequestedFinality(SOURCE_CHAIN_SELECTOR, address(s_vault), requestedFinality);
  }

  function test_setChainType_emits_ChainTypeSet() public {
    uint64 sel = 333;
    vm.expectEmit(true, false, false, true);
    emit ChainTypeSet(sel, CrossChainERC4626Adapter.ChainType.EVM);
    s_adapter.setChainType(sel, CrossChainERC4626Adapter.ChainType.EVM);
  }

  function test_constructor_grants_expected_roles() public {
    assertTrue(s_adapter.hasRole(s_adapter.DEFAULT_ADMIN_ROLE(), address(this)));
    assertTrue(s_adapter.hasRole(s_adapter.FEE_SETTER_ROLE(), address(this)));
    assertTrue(s_adapter.hasRole(s_adapter.FEE_COLLECTOR_ROLE(), address(this)));
    assertTrue(s_adapter.hasRole(s_adapter.FEE_SETTER_ROLE(), FEE_SETTER));
    assertTrue(s_adapter.hasRole(s_adapter.FEE_COLLECTOR_ROLE(), FEE_COLLECTOR));
  }

  function test_roles_are_enumerable_on_chain() public {
    assertEq(s_adapter.getRoleMemberCount(s_adapter.DEFAULT_ADMIN_ROLE()), 1);
    assertEq(s_adapter.getRoleMember(s_adapter.DEFAULT_ADMIN_ROLE(), 0), address(this));
    assertEq(s_adapter.getRoleMemberCount(s_adapter.FEE_SETTER_ROLE()), 2);
    assertEq(s_adapter.getRoleMemberCount(s_adapter.FEE_COLLECTOR_ROLE()), 2);
  }

  function test_constructor_reverts_when_router_is_zero() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidRouter.selector, address(0)));
    new CrossChainERC4626Adapter(address(0), address(this), FEE_SETTER, FEE_COLLECTOR);
  }

  function test_constructor_reverts_when_default_admin_is_zero() public {
    vm.expectRevert(CrossChainERC4626Adapter.InvalidAdmin.selector);
    new CrossChainERC4626Adapter(address(s_router), address(0), FEE_SETTER, FEE_COLLECTOR);
  }

  function test_constructor_reverts_when_fee_setter_is_zero() public {
    vm.expectRevert(CrossChainERC4626Adapter.InvalidFeeSetter.selector);
    new CrossChainERC4626Adapter(address(s_router), address(this), address(0), FEE_COLLECTOR);
  }

  function test_constructor_reverts_when_fee_collector_is_zero() public {
    vm.expectRevert(CrossChainERC4626Adapter.InvalidFeeCollector.selector);
    new CrossChainERC4626Adapter(address(s_router), address(this), FEE_SETTER, address(0));
  }

  function test_supportsInterface_and_default_finality_config() public {
    assertTrue(s_adapter.supportsInterface(type(IAny2EVMMessageReceiver).interfaceId));
    assertTrue(s_adapter.supportsInterface(type(IAny2EVMMessageReceiverV2).interfaceId));
    assertTrue(s_adapter.supportsInterface(type(IAccessControlEnumerable).interfaceId));
    assertTrue(s_adapter.supportsInterface(type(IAccessControl).interfaceId));
    assertTrue(s_adapter.supportsInterface(type(IERC165).interfaceId));
    assertTrue(s_adapter.supportsInterface(type(IAccessControl).interfaceId));
    assertFalse(s_adapter.supportsInterface(bytes4(0xdeadbeef)));

    (
      address[] memory requiredCCVs,
      address[] memory optionalCCVs,
      uint8 optionalThreshold,
      bytes4 allowedFinalityConfig
    ) = s_adapter.getCCVsAndFinalityConfig(SOURCE_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));

    assertEq(requiredCCVs.length, 0);
    assertEq(optionalCCVs.length, 0);
    assertEq(optionalThreshold, 0);
    assertEq(allowedFinalityConfig, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
  }

  function test_ROUTER_getter_returns_deployed_router() public {
    assertEq(s_adapter.ROUTER(), address(s_router));
  }

  function test_preview_deposit_no_fee_matches_vault() public {
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, false, SOURCE_CHAIN_SELECTOR), 100 ether);
  }

  function test_preview_deposit_with_fee() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), 10 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 90 ether);
  }

  function test_preview_deposit_respects_vault_custom_preview() public {
    s_vault.setDepositBehavior(false, true, 77 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, false, SOURCE_CHAIN_SELECTOR), 77 ether);
  }

  function test_preview_redeem_no_fee() public {
    assertEq(s_adapter.preview(address(s_vault), address(s_vault), 50 ether, false, SOURCE_CHAIN_SELECTOR), 50 ether);
  }

  function test_preview_redeem_with_fee() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 5 ether);
    assertEq(s_adapter.preview(address(s_vault), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 95 ether);
  }

  function test_return_leg_fees_keyed_by_bridged_token_in_underlying_units() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), 10 ether);
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 3 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 90 ether);
    assertEq(s_adapter.preview(address(s_vault), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 97 ether);
  }

  function test_preview_returns_zero_when_amount_zero() public {
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 0, false, SOURCE_CHAIN_SELECTOR), 0);
  }

  function test_preview_revert_target_not_enabled() public {
    s_adapter.setTargetEnabled(address(s_vault), false);
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidTarget.selector, address(s_vault)));
    s_adapter.preview(address(s_asset), address(s_vault), 1 ether, false, SOURCE_CHAIN_SELECTOR);
  }

  function test_preview_revert_invalid_token_for_vault() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainERC4626Adapter.InvalidTargetToken.selector, address(s_vault), address(s_otherToken)
      )
    );
    s_adapter.preview(address(s_otherToken), address(s_vault), 1 ether, false, SOURCE_CHAIN_SELECTOR);
  }

  function test_preview_revert_deposits_disabled() public {
    s_adapter.setProcessingEnabled(false, true);
    vm.expectRevert(CrossChainERC4626Adapter.DepositsDisabled.selector);
    s_adapter.preview(address(s_asset), address(s_vault), 1 ether, false, SOURCE_CHAIN_SELECTOR);
  }

  function test_preview_revert_redeems_disabled() public {
    s_adapter.setProcessingEnabled(true, false);
    vm.expectRevert(CrossChainERC4626Adapter.RedeemsDisabled.selector);
    s_adapter.preview(address(s_vault), address(s_vault), 1 ether, false, SOURCE_CHAIN_SELECTOR);
  }

  function test_preview_returns_zero_when_deposit_fee_gte_amount() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), 100 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 0);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 50 ether, true, SOURCE_CHAIN_SELECTOR), 0);
  }

  function test_preview_returns_zero_when_redeem_fee_gte_preview_assets() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 100 ether);
    assertEq(s_adapter.preview(address(s_vault), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 0);
  }

  function test_preview_returns_zero_when_vault_preview_deposit_zero() public {
    s_vault.setDepositBehavior(false, true, 0);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, false, SOURCE_CHAIN_SELECTOR), 0);
  }

  function test_preview_reverts_when_return_route_fee_chain_not_configured() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidChain.selector, uint64(999)));
    s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, 999);
  }

  function test_preview_reverts_when_source_chain_not_configured_for_local_delivery() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidChain.selector, UNCONFIGURED_CHAIN_SELECTOR));
    s_adapter.preview(address(s_asset), address(s_vault), 100 ether, false, UNCONFIGURED_CHAIN_SELECTOR);
  }

  function test_preview_per_destination_fee_branch() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), 10 ether);
    s_adapter.setAssetFee(SVM_CHAIN_SELECTOR, address(s_vault), 3 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, SOURCE_CHAIN_SELECTOR), 90 ether);
    assertEq(s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, SVM_CHAIN_SELECTOR), 97 ether);
  }

  function test_admin_setters_revert_for_unauthorized_callers() public {
    vm.startPrank(address(0xCAFE));

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setChainType(SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setTargetEnabled(address(s_vault), true);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setProcessingEnabled(true, true);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.FEE_SETTER_ROLE()
      )
    );
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 1);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, new address[](0), new address[](0), 0);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setInboundFinality(SOURCE_CHAIN_SELECTOR, FinalityCodec.WAIT_FOR_FINALITY_FLAG);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.setEvmReturnLaneFormat(
      SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.LEGACY_EXTRA_ARGS_V2
    );

    vm.stopPrank();
  }

  function test_setCCVsConfig_updates_values() public {
    address[] memory requiredCCVs = new address[](2);
    requiredCCVs[0] = address(0x1111);
    requiredCCVs[1] = address(0x2222);

    address[] memory optionalCCVs = new address[](2);
    optionalCCVs[0] = address(0x3333);
    optionalCCVs[1] = address(0x4444);

    vm.expectEmit(true, false, false, true, address(s_adapter));
    emit CCVsConfigSet(SOURCE_CHAIN_SELECTOR, requiredCCVs, optionalCCVs, 1);
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, requiredCCVs, optionalCCVs, 1);

    vm.expectEmit(true, false, false, true, address(s_adapter));
    emit InboundFinalitySet(SOURCE_CHAIN_SELECTOR, FinalityCodec.WAIT_FOR_SAFE_FLAG);
    s_adapter.setInboundFinality(SOURCE_CHAIN_SELECTOR, FinalityCodec.WAIT_FOR_SAFE_FLAG);

    (
      address[] memory returnedRequired,
      address[] memory returnedOptional,
      uint8 returnedThreshold,
      bytes4 returnedFinality
    ) = s_adapter.getCCVsAndFinalityConfig(SOURCE_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));

    assertEq(returnedRequired.length, 2);
    assertEq(returnedRequired[0], requiredCCVs[0]);
    assertEq(returnedRequired[1], requiredCCVs[1]);
    assertEq(returnedOptional.length, 2);
    assertEq(returnedOptional[0], optionalCCVs[0]);
    assertEq(returnedOptional[1], optionalCCVs[1]);
    assertEq(returnedThreshold, 1);
    assertEq(returnedFinality, FinalityCodec.WAIT_FOR_SAFE_FLAG);
    assertEq(s_adapter.inboundFinality(SOURCE_CHAIN_SELECTOR), FinalityCodec.WAIT_FOR_SAFE_FLAG);

    (,,, bytes4 otherSelFinality) =
      s_adapter.getCCVsAndFinalityConfig(SVM_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));
    assertEq(otherSelFinality, bytes4(0));

    (address[] memory otherRequired,,,) =
      s_adapter.getCCVsAndFinalityConfig(SVM_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));
    assertEq(otherRequired.length, 0);
  }

  function test_setCCVsConfig_per_source_isolation() public {
    address[] memory sourceRequired = new address[](1);
    sourceRequired[0] = address(0xA001);
    address[] memory svmRequired = new address[](1);
    svmRequired[0] = address(0xB001);

    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, sourceRequired, new address[](0), 0);
    s_adapter.setCCVsConfig(SVM_CHAIN_SELECTOR, svmRequired, new address[](0), 0);

    (address[] memory returnedSourceRequired,,,) =
      s_adapter.getCCVsAndFinalityConfig(SOURCE_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));
    (address[] memory returnedSvmRequired,,,) =
      s_adapter.getCCVsAndFinalityConfig(SVM_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));

    assertEq(returnedSourceRequired.length, 1);
    assertEq(returnedSourceRequired[0], sourceRequired[0]);
    assertEq(returnedSvmRequired.length, 1);
    assertEq(returnedSvmRequired[0], svmRequired[0]);
  }

  function test_setCCVsConfig_reverts_for_invalid_optional_threshold() public {
    address[] memory optionalCCVs = new address[](1);
    optionalCCVs[0] = address(0x3333);

    vm.expectRevert(
      abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidOptionalThreshold.selector, uint8(2), uint256(1))
    );
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, new address[](0), optionalCCVs, 2);
  }

  function test_setCCVsConfig_reverts_on_duplicate_ccv_in_required() public {
    address dup = address(0xD00D);
    address[] memory requiredCCVs = new address[](2);
    requiredCCVs[0] = dup;
    requiredCCVs[1] = dup;

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.DuplicateCCV.selector, dup));
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, requiredCCVs, new address[](0), 0);
  }

  function test_setCCVsConfig_reverts_on_duplicate_ccv_in_optional() public {
    address dup = address(0xD02D);
    address[] memory optionalCCVs = new address[](2);
    optionalCCVs[0] = dup;
    optionalCCVs[1] = dup;

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.DuplicateCCV.selector, dup));
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, new address[](0), optionalCCVs, 1);
  }

  function test_setCCVsConfig_reverts_when_optional_ccvs_configured_but_threshold_zero() public {
    address[] memory optionalCCVs = new address[](1);
    optionalCCVs[0] = address(0x3333);

    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainERC4626Adapter.OptionalCCVsRequirePositiveThreshold.selector, optionalCCVs.length
      )
    );
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, new address[](0), optionalCCVs, 0);
  }

  function test_setCCVsConfig_reverts_when_optional_ccv_is_zero_address() public {
    address[] memory optionalCCVs = new address[](1);
    optionalCCVs[0] = address(0);

    vm.expectRevert(CrossChainERC4626Adapter.InvalidOptionalCCV.selector);
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, new address[](0), optionalCCVs, 1);
  }

  function test_setCCVsConfig_allows_zero_address_in_required_ccvs() public {
    address[] memory requiredCCVs = new address[](1);
    requiredCCVs[0] = address(0);

    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, requiredCCVs, new address[](0), 0);

    (address[] memory returnedRequired,,,) =
      s_adapter.getCCVsAndFinalityConfig(SOURCE_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER));
    assertEq(returnedRequired.length, 1);
    assertEq(returnedRequired[0], address(0));
  }

  function test_setCCVsConfig_reverts_when_same_ccv_in_required_and_optional() public {
    address ccv = address(0xB0B0);
    address[] memory requiredCCVs = new address[](1);
    requiredCCVs[0] = ccv;
    address[] memory optionalCCVs = new address[](1);
    optionalCCVs[0] = ccv;

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.DuplicateCCV.selector, ccv));
    s_adapter.setCCVsConfig(SOURCE_CHAIN_SELECTOR, requiredCCVs, optionalCCVs, 1);
  }

  function test_setTargetEnabled_reverts_for_zero_target() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidTarget.selector, address(0)));
    s_adapter.setTargetEnabled(address(0), true);
  }

  function test_setAssetFee_reverts_for_zero_asset() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidTarget.selector, address(0)));
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(0), 1);
  }

  function test_setAssetFee_allows_staging_before_chain_enabled() public {
    s_adapter.setAssetFee(UNCONFIGURED_CHAIN_SELECTOR, address(s_vault), 7 ether);
    assertEq(s_adapter.assetFees(UNCONFIGURED_CHAIN_SELECTOR, address(s_vault)), 7 ether);

    s_adapter.setChainType(UNCONFIGURED_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);
    assertEq(
      s_adapter.preview(address(s_asset), address(s_vault), 100 ether, true, UNCONFIGURED_CHAIN_SELECTOR), 93 ether
    );
  }

  function test_setAssetFees_sets_multiple_rows() public {
    uint64[] memory selectors = new uint64[](2);
    selectors[0] = SOURCE_CHAIN_SELECTOR;
    selectors[1] = SVM_CHAIN_SELECTOR;
    address[] memory assets_ = new address[](2);
    assets_[0] = address(s_asset);
    assets_[1] = address(s_otherToken);
    uint256[] memory fees_ = new uint256[](2);
    fees_[0] = 9 ether;
    fees_[1] = 4 ether;

    s_adapter.setAssetFees(selectors, assets_, fees_);
    assertEq(s_adapter.assetFees(SOURCE_CHAIN_SELECTOR, address(s_asset)), 9 ether);
    assertEq(s_adapter.assetFees(SVM_CHAIN_SELECTOR, address(s_otherToken)), 4 ether);
  }

  function test_setAssetFees_reverts_when_array_lengths_mismatch() public {
    uint64[] memory selectors = new uint64[](1);
    selectors[0] = SOURCE_CHAIN_SELECTOR;
    address[] memory assets_ = new address[](2);
    assets_[0] = address(s_asset);
    assets_[1] = address(s_otherToken);
    uint256[] memory fees_ = new uint256[](1);
    fees_[0] = 1 ether;

    vm.expectRevert(CrossChainERC4626Adapter.FeeConfigLengthMismatch.selector);
    s_adapter.setAssetFees(selectors, assets_, fees_);
  }

  function test_setAssetFees_reverts_for_unauthorized_caller() public {
    uint64[] memory selectors = new uint64[](0);
    address[] memory assets_ = new address[](0);
    uint256[] memory fees_ = new uint256[](0);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xCAFE), s_adapter.FEE_SETTER_ROLE()
      )
    );
    vm.prank(address(0xCAFE));
    s_adapter.setAssetFees(selectors, assets_, fees_);
  }

  function test_processMessage_reverts_when_not_self() public {
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("direct-process"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1
    );

    vm.expectRevert(CrossChainERC4626Adapter.OnlySelf.selector);
    s_adapter.processMessage(message);
  }

  function test_ccipReceive_reverts_when_not_router() public {
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("not-router"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1
    );

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidRouter.selector, address(this)));
    s_adapter.ccipReceive(message);
  }

  /// @dev Chain allowlisting is enforced in `processMessage` (`onlyValidChain`). `ccipReceive` catches the revert so
  /// delivery completes; outbound `sendToken` still requires `chains[dest] != NONE` when no override is passed (or it
  /// reverts `InvalidChain`).
  function test_processMessage_reverts_for_disabled_source_chain_when_self_called() public {
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("disabled-source-process"),
      UNCONFIGURED_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1
    );

    vm.prank(address(s_adapter));
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidChain.selector, UNCONFIGURED_CHAIN_SELECTOR));
    s_adapter.processMessage(message);
  }

  function test_failure_disabled_source_chain_marks_message_failed() public {
    bytes32 messageId = keccak256("disabled-source");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      UNCONFIGURED_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1
    );
    s_asset.mint(address(s_router), 1);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_deposit_local_delivery_succeeds() public {
    bytes32 messageId = keccak256("deposit-local");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 100 ether, false),
      address(s_asset),
      100 ether
    );
    s_asset.mint(address(s_router), 100 ether);

    vm.expectEmit(true, true, true, true, address(s_adapter));
    emit TargetProcessed(messageId, address(s_vault), address(s_asset), address(s_vault), 100 ether, 100 ether);
    vm.expectEmit(true, true, true, true, address(s_adapter));
    emit LocalTokenDelivered(messageId, address(s_vault), BENEFICIARY, 100 ether);
    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_vault.balanceOf(BENEFICIARY), 100 ether);
    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.NONE))
    );
    assertEq(s_asset.balanceOf(address(s_adapter)), 0);
    assertEq(s_adapter.collectedFees(address(s_asset)), 0);
    assertEq(s_vault.lastDepositAssets(), 100 ether);
    assertEq(s_vault.lastDepositReceiver(), address(s_adapter));
  }

  function test_deposit_bridge_back_uses_default_evm_extra_args() public {
    bytes32 messageId = keccak256("deposit-bridge-evm");
    bytes32 beneficiary = _toBytes32(BENEFICIARY);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), beneficiary, 50 ether, true),
      address(s_asset),
      50 ether
    );
    s_asset.mint(address(s_router), 50 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_router.sendCount(), 1);
    assertEq(s_router.lastDestinationChainSelector(), SOURCE_CHAIN_SELECTOR);
    assertEq(s_router.lastToken(), address(s_vault));
    assertEq(s_router.lastAmount(), 50 ether);
    assertEq(s_router.lastReceiverBytes(), abi.encode(BENEFICIARY));
    assertEq(s_router.lastData(), bytes(""));
    assertEq(s_router.lastFeeToken(), address(0));
    assertEq(s_router.lastMsgValue(), s_router.fee());
    assertEq(s_router.lastCaller(), address(s_adapter));
    assertEq(
      s_router.lastExtraArgs(),
      Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}))
    );
  }

  function test_deposit_bridge_back_uses_generic_extra_args_v3_when_configured() public {
    s_adapter.setEvmReturnLaneFormat(
      SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.EvmReturnExtraArgsFormat.GENERIC_EXTRA_ARGS_V3_BASIC
    );
    s_adapter.setEvmReturnRequestedFinality(
      SOURCE_CHAIN_SELECTOR, address(s_vault), FinalityCodec.WAIT_FOR_FINALITY_FLAG
    );
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("deposit-bridge-v3"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 25 ether, true),
      address(s_asset),
      25 ether
    );
    s_asset.mint(address(s_router), 25 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_router.sendCount(), 1);
    bytes memory expected = ExtraArgsCodec._getBasicEncodedExtraArgsV3(0, FinalityCodec.WAIT_FOR_FINALITY_FLAG);
    assertEq(s_router.lastExtraArgs(), expected);
  }

  /// @dev Lane format unset → legacy V2 for all tokens on that selector.
  function test_deposit_bridge_back_uses_legacy_extra_args_when_lane_format_unset() public {
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("deposit-bridge-v3-only-asset"),
      SOURCE_CHAIN_SELECTOR,
      abi.encodePacked(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 25 ether, true),
      address(s_asset),
      25 ether
    );
    s_asset.mint(address(s_router), 25 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_router.sendCount(), 1);
    assertEq(
      s_router.lastExtraArgs(),
      Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 0, allowOutOfOrderExecution: true}))
    );
  }

  function test_deposit_bridge_back_uses_default_svm_extra_args() public {
    bytes32 svmBeneficiary = bytes32(uint256(0xB0B));
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("deposit-bridge-svm"),
      SVM_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodeSvmPayload(address(s_vault), svmBeneficiary, 40 ether, true),
      address(s_asset),
      40 ether
    );
    s_asset.mint(address(s_router), 40 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(_encodeSvmPayload(address(s_vault), svmBeneficiary, 40 ether, true).length, 128);
    assertEq(s_router.lastDestinationChainSelector(), SVM_CHAIN_SELECTOR);
    assertEq(s_router.lastReceiverBytes(), abi.encode(address(0)));
    assertEq(s_router.lastData(), bytes(""));
    assertEq(s_router.lastFeeToken(), address(0));
    assertEq(s_router.lastMsgValue(), s_router.fee());
    assertEq(
      s_router.lastExtraArgs(),
      Client._svmArgsToBytes(
        Client.SVMExtraArgsV1({
          computeUnits: 0,
          accountIsWritableBitmap: 0,
          allowOutOfOrderExecution: true,
          tokenReceiver: svmBeneficiary,
          accounts: new bytes32[](0)
        })
      )
    );
  }

  function test_processMessage_reverts_when_payload_not_128_bytes() public {
    bytes memory longPayload = _encodeLegacyFiveFieldPayload(address(s_vault), _toBytes32(BENEFICIARY), 1 ether, false);
    assertEq(longPayload.length, 192);
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("svm-evm-payload"),
      SVM_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      longPayload,
      address(s_asset),
      1 ether
    );
    vm.prank(address(s_adapter));
    vm.expectRevert(
      abi.encodeWithSelector(CrossChainERC4626Adapter.InvalidPayloadLength.selector, uint256(192), uint256(128))
    );
    s_adapter.processMessage(message);
  }

  function test_redeem_local_delivery_skips_asset_fee_even_when_configured() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 10 ether);
    s_asset.mint(address(s_vault), 100 ether);
    s_vault.mintShares(address(s_router), 100 ether);

    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("redeem-local"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 90 ether, false),
      address(s_vault),
      100 ether
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_asset.balanceOf(BENEFICIARY), 100 ether);
    assertEq(s_adapter.collectedFees(address(s_asset)), 0);
  }

  function test_redeem_bridge_back_succeeds() public {
    s_asset.mint(address(s_vault), 60 ether);
    s_vault.mintShares(address(s_router), 60 ether);

    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("redeem-bridge"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 60 ether, true),
      address(s_vault),
      60 ether
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(s_router.sendCount(), 1);
    assertEq(s_router.lastDestinationChainSelector(), SOURCE_CHAIN_SELECTOR);
    assertEq(s_router.lastToken(), address(s_asset));
    assertEq(s_router.lastAmount(), 60 ether);
    assertEq(s_router.lastReceiverBytes(), abi.encode(BENEFICIARY));
    assertEq(s_router.lastData(), bytes(""));
    assertEq(s_router.lastFeeToken(), address(0));
    assertEq(s_router.lastMsgValue(), s_router.fee());
  }

  function test_failure_large_revert_data_still_marks_message_failed() public {
    bytes memory largeRevertData = new bytes(32_768);
    for (uint256 i = 0; i < largeRevertData.length; ++i) {
      largeRevertData[i] = bytes1(uint8(i));
    }
    s_vault.setLargeDepositRevertData(largeRevertData);

    bytes32 messageId = keccak256("large-revert-data");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    vm.expectEmit(true, true, true, true, address(s_adapter));
    emit CrossChainERC4626Adapter.MessageFailed(messageId);
    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
    CrossChainERC4626Adapter.FailedMessageRecord memory stored = s_adapter.getFailedMessageRecord(messageId);
    assertEq(stored.sourceChainSelector, SOURCE_CHAIN_SELECTOR);
    assertEq(stored.sender, _ccipEvmSender(ORIGINAL_SENDER));
    assertEq(stored.destTokenAmounts.length, 1);
    assertEq(stored.destTokenAmounts[0].amount, 1 ether);
  }

  function test_failure_large_message_data_not_stored_in_failed_record() public {
    bytes memory oversizedData = new bytes(32_768);
    bytes32 messageId = keccak256("large-message-data");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId, SOURCE_CHAIN_SELECTOR, _ccipEvmSender(ORIGINAL_SENDER), oversizedData, address(s_asset), 1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );

    CrossChainERC4626Adapter.FailedMessageRecord memory stored = s_adapter.getFailedMessageRecord(messageId);
    assertEq(stored.sourceChainSelector, SOURCE_CHAIN_SELECTOR);
    assertEq(stored.destTokenAmounts[0].amount, 1 ether);
    assertEq(stored.localRefundAddress, address(0));

    uint256 gasBefore = gasleft();
    s_adapter.estimateRefundFee(messageId);
    uint256 estimateGas = gasBefore - gasleft();
    assertLt(estimateGas, 500_000);
  }

  function test_failure_invalid_target_marks_message_failed() public {
    s_adapter.setTargetEnabled(address(s_vault), false);
    bytes32 messageId = keccak256("invalid-target");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_deposits_disabled_marks_message_failed() public {
    s_adapter.setProcessingEnabled(false, true);
    bytes32 messageId = keccak256("deposits-disabled");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_redeems_disabled_marks_message_failed() public {
    s_adapter.setProcessingEnabled(true, false);
    s_asset.mint(address(s_vault), 1 ether);
    s_vault.mintShares(address(s_router), 1 ether);

    bytes32 messageId = keccak256("redeems-disabled");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_vault),
      1 ether
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_invalid_token_count_marks_message_failed() public {
    bytes32 messageId = keccak256("invalid-token-count");
    Client.Any2EVMMessage memory message;
    message.messageId = messageId;
    message.sourceChainSelector = SOURCE_CHAIN_SELECTOR;
    message.sender = _ccipEvmSender(ORIGINAL_SENDER);
    message.data = _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false);
    message.destTokenAmounts = new Client.EVMTokenAmount[](2);
    message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(s_asset), amount: 1 ether});
    message.destTokenAmounts[1] = Client.EVMTokenAmount({token: address(s_otherToken), amount: 1 ether});

    s_asset.mint(address(s_router), 1 ether);
    s_otherToken.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_invalid_input_token_marks_message_failed() public {
    bytes32 messageId = keccak256("invalid-input-token");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_otherToken),
      1 ether
    );
    s_otherToken.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_amount_zero_marks_message_failed() public {
    bytes32 messageId = keccak256("amount-zero");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      0
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_deposit_fee_exceeds_amount_marks_message_failed() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), 1 ether);
    bytes32 messageId = keccak256("deposit-fee-exceeds");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 0, true),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_minimum_output_not_met_marks_message_failed() public {
    uint256 inboundAmount = 10 ether;
    s_vault.setDepositBehavior(false, true, 5 ether);
    bytes32 messageId = keccak256("minimum-output");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), inboundAmount, false),
      address(s_asset),
      inboundAmount
    );
    s_asset.mint(address(s_router), inboundAmount);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
    // Deposit ran inside processMessage then MinimumOutputNotMet reverted the self-call;
    // inbound underlying stays on the adapter (vault deposit effects roll back).
    assertEq(s_asset.balanceOf(address(s_adapter)), inboundAmount);
    assertEq(s_vault.balanceOf(address(s_adapter)), 0);
  }

  function test_failure_minimum_output_not_met_after_redeem_holds_inbound_shares() public {
    uint256 inboundShares = 100 ether;
    s_vault.setRedeemBehavior(false, true, 5 ether);
    s_asset.mint(address(s_vault), inboundShares);
    s_vault.mintShares(address(s_router), inboundShares);

    bytes32 messageId = keccak256("minimum-output-redeem");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 10 ether, false),
      address(s_vault),
      inboundShares
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
    assertEq(s_vault.balanceOf(address(s_adapter)), inboundShares);
    assertEq(s_asset.balanceOf(address(s_adapter)), 0);
  }

  function test_failure_bridge_back_after_deposit_holds_inbound_asset() public {
    uint256 inboundAmount = 1 ether;
    vm.deal(address(s_adapter), 0);
    bytes32 messageId = keccak256("no-native-balance");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, true),
      address(s_asset),
      inboundAmount
    );
    s_asset.mint(address(s_router), inboundAmount);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
    assertEq(s_asset.balanceOf(address(s_adapter)), inboundAmount);
    assertEq(s_vault.balanceOf(address(s_adapter)), 0);
  }

  function test_failure_no_output_received_marks_message_failed() public {
    s_vault.setRedeemBehavior(false, true, 0);
    s_asset.mint(address(s_vault), 1 ether);
    s_vault.mintShares(address(s_router), 1 ether);

    bytes32 messageId = keccak256("no-output");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_vault),
      1 ether
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_refundFailedMessage_succeeds_and_updates_status() public {
    bytes32 messageId = _createFailedDepositMessage();
    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    (bool canRefund, bytes32 originalSender,, uint256 tokenAmount, uint256 requiredFee) =
      s_adapter.checkRefundEligibility(messageId);

    assertTrue(canRefund);
    assertEq(originalSender, _toBytes32(ORIGINAL_SENDER));
    assertEq(tokenAmount, 1 ether);
    assertEq(requiredFee, estimatedFee);

    uint256 receiverBalanceBefore = address(s_adapter).balance;
    vm.expectEmit(true, true, true, true, address(s_adapter));
    emit MessageRefunded(messageId, SOURCE_CHAIN_SELECTOR, _toBytes32(ORIGINAL_SENDER));
    s_adapter.refundFailedMessage{value: estimatedFee + 1 ether}(messageId);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.RESOLVED))
    );
    assertEq(s_router.sendCount(), 1);
    assertEq(s_router.lastToken(), address(s_asset));
    assertEq(s_router.lastAmount(), 1 ether);
    assertEq(s_router.lastReceiverBytes(), abi.encode(ORIGINAL_SENDER));
    assertEq(address(s_adapter).balance, receiverBalanceBefore);
  }

  /// @dev Refund must keep SVM wire shape using `refundChainFamilySnapshot` if `chains[source]` is later retyped EVM.
  function test_refundFailedMessage_uses_svm_encoding_after_chain_retyped_to_evm() public {
    bytes32 messageId = keccak256("svm-fail-chain-retype");
    s_adapter.setTargetEnabled(address(s_vault), false);

    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SVM_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodeSvmPayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);
    s_adapter.setTargetEnabled(address(s_vault), true);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );

    s_adapter.setChainType(SVM_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);

    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    s_adapter.refundFailedMessage{value: estimatedFee + 0.5 ether}(messageId);

    assertEq(s_router.lastDestinationChainSelector(), SVM_CHAIN_SELECTOR);
    assertEq(s_router.lastReceiverBytes(), abi.encode(address(0)));
    assertEq(
      s_router.lastExtraArgs(),
      Client._svmArgsToBytes(
        Client.SVMExtraArgsV1({
          computeUnits: 0,
          accountIsWritableBitmap: 0,
          allowOutOfOrderExecution: true,
          tokenReceiver: _toBytes32(ORIGINAL_SENDER),
          accounts: new bytes32[](0)
        })
      )
    );
    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.RESOLVED))
    );
  }

  /// @dev When `chains[source]` was unset at failure, refund encoding is inferred from `message.sender` (32-byte
  /// non-canonical → SVM).
  function test_refundFailedMessage_infers_svm_when_source_chain_unconfigured() public {
    s_router.setSupportedChain(UNCONFIGURED_CHAIN_SELECTOR, true);

    bytes32 messageId = keccak256("unconfigured-svm-infer");
    bytes32 svmPubkey = keccak256("svm-sender-pubkey");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      UNCONFIGURED_CHAIN_SELECTOR,
      abi.encodePacked(svmPubkey),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );

    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    s_adapter.refundFailedMessage{value: estimatedFee + 0.5 ether}(messageId);

    assertEq(s_router.lastDestinationChainSelector(), UNCONFIGURED_CHAIN_SELECTOR);
    assertEq(s_router.lastReceiverBytes(), abi.encode(address(0)));
    assertEq(
      s_router.lastExtraArgs(),
      Client._svmArgsToBytes(
        Client.SVMExtraArgsV1({
          computeUnits: 0,
          accountIsWritableBitmap: 0,
          allowOutOfOrderExecution: true,
          tokenReceiver: svmPubkey,
          accounts: new bytes32[](0)
        })
      )
    );
    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.RESOLVED))
    );
  }

  /// @dev Unset `chains[source]` with CCIP-encoded 32-byte EVM `sender` infers EVM outbound encoding for refunds.
  function test_refundFailedMessage_infers_evm_when_source_chain_unconfigured() public {
    s_router.setSupportedChain(UNCONFIGURED_CHAIN_SELECTOR, true);

    bytes32 messageId = keccak256("unconfigured-evm-infer");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      UNCONFIGURED_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    s_adapter.refundFailedMessage{value: estimatedFee + 0.5 ether}(messageId);

    assertEq(s_router.lastDestinationChainSelector(), UNCONFIGURED_CHAIN_SELECTOR);
    assertEq(s_router.lastReceiverBytes(), abi.encode(ORIGINAL_SENDER));
  }

  function test_refundFailedMessage_reverts_when_message_not_failed() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.MessageNotFailed.selector, bytes32("not-failed")));
    s_adapter.refundFailedMessage(bytes32("not-failed"));
  }

  function test_refundFailedMessage_reverts_when_fee_too_low() public {
    bytes32 messageId = _createFailedDepositMessage();
    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);

    vm.expectRevert(
      abi.encodeWithSelector(CrossChainERC4626Adapter.InsufficientRecoveryFee.selector, estimatedFee, estimatedFee - 1)
    );
    s_adapter.refundFailedMessage{value: estimatedFee - 1}(messageId);
  }

  /// @dev Regression: pre-execution fee sum can be below the actual sum when sequential `ccipSend` calls raise
  /// `getFee`; post-loop `msg.value` check must use accumulated paid fees.
  function test_refundFailedMessage_reverts_when_preflight_estimate_underestimates_sequential_router_fees() public {
    uint256 baseFee = s_router.fee();
    uint256 inc = 0.001 ether;
    s_router.setFeeIncrementPerSend(inc);
    s_router.resetSendStateForTest();

    bytes32 messageId = keccak256("multi-leg-refund-fee-rise");
    s_adapter.setTargetEnabled(address(s_vault), false);

    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    message.destTokenAmounts = new Client.EVMTokenAmount[](2);
    message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(s_asset), amount: 1 ether});
    message.destTokenAmounts[1] = Client.EVMTokenAmount({token: address(s_asset), amount: 1 ether});

    s_asset.mint(address(s_router), 2 ether);
    s_router.routeMessage(address(s_adapter), message);
    s_adapter.setTargetEnabled(address(s_vault), true);

    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    assertEq(estimatedFee, 2 * baseFee, "static estimate uses same router sendCount for each leg");

    uint256 actualPaidSum = baseFee + (baseFee + inc);

    vm.expectRevert(
      abi.encodeWithSelector(CrossChainERC4626Adapter.InsufficientRecoveryFee.selector, actualPaidSum, estimatedFee)
    );
    s_adapter.refundFailedMessage{value: estimatedFee}(messageId);
  }

  function test_refundFailedMessage_reverts_for_invalid_sender_format() public {
    bytes32 messageId = keccak256("bad-sender");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      hex"01",
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    vm.expectRevert(CrossChainERC4626Adapter.InvalidSenderAddressFormat.selector);
    s_adapter.refundFailedMessage{value: 1 ether}(messageId);
  }

  function test_refundFailedMessage_reverts_when_excess_refund_recipient_rejects_eth() public {
    bytes32 messageId = _createFailedDepositMessage();
    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    RejectEtherReceiver rejector = new RejectEtherReceiver();

    vm.expectRevert(CrossChainERC4626Adapter.RefundFailed.selector);
    rejector.callRefundFailedMessage{value: estimatedFee + 1 ether}(address(s_adapter), messageId);
  }

  function test_withdrawFee_succeeds() public {
    _accrueDepositFee(10 ether);

    vm.prank(FEE_COLLECTOR);
    vm.expectEmit(true, true, true, true, address(s_adapter));
    emit FeeWithdrawn(address(s_asset), BENEFICIARY, 10 ether);
    s_adapter.withdrawFee(address(s_asset), BENEFICIARY, 10 ether);

    assertEq(s_asset.balanceOf(BENEFICIARY), 10 ether);
    assertEq(s_adapter.collectedFees(address(s_asset)), 0);
  }

  function test_withdrawFee_reverts_for_invalid_inputs_and_balances() public {
    vm.prank(FEE_COLLECTOR);
    vm.expectRevert(CrossChainERC4626Adapter.InvalidRecipient.selector);
    s_adapter.withdrawFee(address(s_asset), address(0), 1);

    vm.prank(FEE_COLLECTOR);
    vm.expectRevert(CrossChainERC4626Adapter.AmountIsZero.selector);
    s_adapter.withdrawFee(address(s_asset), BENEFICIARY, 0);

    vm.prank(FEE_COLLECTOR);
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.InsufficientFeeBalance.selector, 0, 1));
    s_adapter.withdrawFee(address(s_asset), BENEFICIARY, 1);
  }

  function test_withdrawFee_reverts_when_actual_balance_is_insufficient() public {
    _accrueDepositFee(10 ether);
    s_asset.burn(address(s_adapter), 10 ether);

    vm.prank(FEE_COLLECTOR);
    vm.expectRevert("ERC20: transfer amount exceeds balance");
    s_adapter.withdrawFee(address(s_asset), BENEFICIARY, 5 ether);
  }

  function test_privileged_fund_moving_functions_revert_for_unauthorized_callers() public {
    address attacker = address(0xCAFE);

    vm.startPrank(attacker);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, s_adapter.FEE_COLLECTOR_ROLE()
      )
    );
    s_adapter.withdrawFee(address(s_asset), BENEFICIARY, 1 ether);

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, s_adapter.DEFAULT_ADMIN_ROLE()
      )
    );
    s_adapter.recoverNative(BENEFICIARY);

    vm.stopPrank();
  }

  function test_recoverNative_succeeds() public {
    vm.deal(address(this), 1 ether);
    (bool success,) = address(s_adapter).call{value: 1 ether}("");
    assertTrue(success);

    uint256 receiverBalance = address(s_adapter).balance;
    uint256 beforeBalance = BENEFICIARY.balance;
    s_adapter.recoverNative(BENEFICIARY);

    assertEq(BENEFICIARY.balance, beforeBalance + receiverBalance);
  }

  function test_recoverNative_reverts_when_recipient_rejects_eth() public {
    RejectEtherReceiver rejector = new RejectEtherReceiver();
    vm.deal(address(this), 1 ether);
    (bool success,) = address(s_adapter).call{value: 1 ether}("");
    assertTrue(success);

    vm.expectRevert(CrossChainERC4626Adapter.RecoverNativeFailed.selector);
    s_adapter.recoverNative(address(rejector));
  }

  function test_recoverNative_reverts_for_invalid_inputs_and_zero_balance() public {
    vm.expectRevert(CrossChainERC4626Adapter.InvalidRecipient.selector);
    s_adapter.recoverNative(address(0));

    vm.deal(address(s_adapter), 0);
    vm.expectRevert(CrossChainERC4626Adapter.AmountIsZero.selector);
    s_adapter.recoverNative(BENEFICIARY);
  }

  function test_withdrawFee_nonReentrant_blocks_token_callback_reentry() public {
    ReentrantERC20 reentrantAsset = new ReentrantERC20("Reentrant Asset", "RAT", 18);
    MockERC4626Vault reentrantVault = new MockERC4626Vault(address(reentrantAsset), "Reentrant Vault", "rVLT");
    CrossChainERC4626Adapter adapter =
      new CrossChainERC4626Adapter(address(s_router), address(this), FEE_SETTER, FEE_COLLECTOR);

    adapter.setChainType(SOURCE_CHAIN_SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);
    adapter.setTargetEnabled(address(reentrantVault), true);
    adapter.setProcessingEnabled(true, true);
    adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(reentrantVault), 10 ether);

    vm.deal(address(adapter), 100 ether);

    reentrantAsset.mint(address(s_router), 100 ether);
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256("reentrant-fee"),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(reentrantVault), _toBytes32(BENEFICIARY), 90 ether, true),
      address(reentrantAsset),
      100 ether
    );
    s_router.routeMessage(address(adapter), message);

    adapter.grantRole(adapter.FEE_COLLECTOR_ROLE(), address(reentrantAsset));
    reentrantAsset.configureReentrancy(
      address(adapter),
      abi.encodeWithSelector(adapter.withdrawFee.selector, address(reentrantAsset), BENEFICIARY, 1 ether),
      true
    );

    vm.prank(FEE_COLLECTOR);
    adapter.withdrawFee(address(reentrantAsset), BENEFICIARY, 10 ether);

    assertFalse(reentrantAsset.lastReentrancyCallSuccess());
    assertEq(bytes4(reentrantAsset.lastReentrancyReturnData()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
  }

  function test_failure_redeem_fee_exceeds_amount_marks_message_failed() public {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_asset), 1 ether);
    s_asset.mint(address(s_vault), 1 ether);
    s_vault.mintShares(address(s_router), 1 ether);

    bytes32 messageId = keccak256("redeem-fee-exceeds");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 0, true),
      address(s_vault),
      1 ether
    );

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_failure_local_delivery_with_invalid_beneficiary_marks_message_failed() public {
    bytes32 invalidBeneficiary = bytes32(type(uint256).max);
    bytes32 messageId = keccak256("invalid-beneficiary");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), invalidBeneficiary, 1 ether, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);

    s_router.routeMessage(address(s_adapter), message);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.BASIC))
    );
  }

  function test_checkRefundEligibility_returns_false_for_non_failed_and_invalid_sender() public {
    (bool canRefund,,,,) = s_adapter.checkRefundEligibility(bytes32("not-failed"));
    assertFalse(canRefund);

    bytes32 invalidSenderMessageId = keccak256("eligibility-invalid-sender");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory invalidSenderMessage = _buildMessage(
      invalidSenderMessageId,
      SOURCE_CHAIN_SELECTOR,
      hex"01",
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), invalidSenderMessage);

    (canRefund,,,,) = s_adapter.checkRefundEligibility(invalidSenderMessageId);
    assertFalse(canRefund);

    Client.Any2EVMMessage memory zeroMessageIdMessage = _buildMessage(
      bytes32(0),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), zeroMessageIdMessage);

    (canRefund,,,,) = s_adapter.checkRefundEligibility(bytes32(0));
    assertTrue(canRefund);

    s_adapter.setTargetEnabled(address(s_vault), true);
  }

  function test_estimateRefundFee_reverts_when_message_not_failed() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.MessageNotFailed.selector, bytes32("missing")));
    s_adapter.estimateRefundFee(bytes32("missing"));
  }

  function test_refundFailedMessage_reverts_when_failed_message_token_amount_is_zero() public {
    bytes32 messageId = keccak256("refund-zero-amount");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      0
    );
    s_router.routeMessage(address(s_adapter), message);

    (bool canRefund,,,,) = s_adapter.checkRefundEligibility(messageId);
    assertFalse(canRefund);

    vm.expectRevert(CrossChainERC4626Adapter.NoRefundableTokenAmounts.selector);
    s_adapter.estimateRefundFee(messageId);

    vm.expectRevert(CrossChainERC4626Adapter.NoRefundableTokenAmounts.selector);
    s_adapter.refundFailedMessage{value: 0}(messageId);
  }

  function test_refundFailedMessage_skips_zero_dest_amount_entries() public {
    bytes32 messageId = keccak256("refund-mixed-zero-nonzero");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message;
    message.messageId = messageId;
    message.sourceChainSelector = SOURCE_CHAIN_SELECTOR;
    message.sender = _ccipEvmSender(ORIGINAL_SENDER);
    message.data = _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false);
    message.destTokenAmounts = new Client.EVMTokenAmount[](2);
    message.destTokenAmounts[0] = Client.EVMTokenAmount({token: address(s_asset), amount: 0});
    message.destTokenAmounts[1] = Client.EVMTokenAmount({token: address(s_asset), amount: 1 ether});

    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    (bool canRefund, bytes32 sender, address token, uint256 tokenAmt, uint256 reqFee) =
      s_adapter.checkRefundEligibility(messageId);
    assertTrue(canRefund);
    assertEq(sender, _toBytes32(ORIGINAL_SENDER));
    assertEq(token, address(s_asset));
    assertEq(tokenAmt, 1 ether);
    assertEq(reqFee, s_router.fee());

    uint256 balBefore = address(s_adapter).balance;
    s_adapter.refundFailedMessage{value: reqFee + 0.5 ether}(messageId);
    assertEq(s_router.sendCount(), 1);
    assertEq(s_router.lastAmount(), 1 ether);
    assertEq(s_router.lastToken(), address(s_asset));
    assertEq(address(s_adapter).balance, balBefore);
  }

  function test_packDeliveryAndRefund_roundtrip() public pure {
    assertEq(_packDeliveryAndRefund(false, address(0)), 0);
    assertEq(_packDeliveryAndRefund(true, address(0)), 1);
    assertEq(_packDeliveryAndRefund(false, LOCAL_REFUND), uint256(uint160(LOCAL_REFUND)) << 1);
    assertEq(_packDeliveryAndRefund(true, LOCAL_REFUND), (uint256(uint160(LOCAL_REFUND)) << 1) | 1);
  }

  function test_recoverFailedMessageLocally_succeeds_and_updates_status() public {
    bytes32 messageId = keccak256("local-recover-success");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false, LOCAL_REFUND),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    (bool canRecover, address localRefund, address token, uint256 tokenAmount) =
      s_adapter.checkLocalRecoveryEligibility(messageId);
    assertTrue(canRecover);
    assertEq(localRefund, LOCAL_REFUND);
    assertEq(token, address(s_asset));
    assertEq(tokenAmount, 1 ether);

    CrossChainERC4626Adapter.FailedMessageRecord memory stored = s_adapter.getFailedMessageRecord(messageId);
    assertEq(stored.localRefundAddress, LOCAL_REFUND);

    vm.prank(LOCAL_REFUND);
    vm.expectEmit(true, true, false, true, address(s_adapter));
    emit MessageRecoveredLocally(messageId, LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(messageId);

    assertEq(
      uint256(uint8(s_adapter.messageErrorCode(messageId))), uint256(uint8(CrossChainERC4626Adapter.ErrorCode.RESOLVED))
    );
    assertEq(s_asset.balanceOf(LOCAL_REFUND), 1 ether);
    assertEq(s_router.sendCount(), 0);
  }

  function test_recoverFailedMessageLocally_reverts_when_caller_not_local_refund_address() public {
    bytes32 messageId = keccak256("local-recover-unauthorized");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false, LOCAL_REFUND),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    vm.expectRevert(
      abi.encodeWithSelector(CrossChainERC4626Adapter.UnauthorizedLocalRefund.selector, BENEFICIARY, LOCAL_REFUND)
    );
    vm.prank(BENEFICIARY);
    s_adapter.recoverFailedMessageLocally(messageId);
  }

  function test_recoverFailedMessageLocally_reverts_when_local_refund_address_zero() public {
    bytes32 messageId = _createFailedDepositMessage();

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.NoLocalRefundAddress.selector, messageId));
    vm.prank(LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(messageId);

    (bool canRecover,,,) = s_adapter.checkLocalRecoveryEligibility(messageId);
    assertFalse(canRecover);
  }

  function test_recoverFailedMessageLocally_reverts_when_message_not_failed() public {
    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.MessageNotFailed.selector, bytes32("not-failed")));
    vm.prank(LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(bytes32("not-failed"));
  }

  function test_local_and_cross_chain_recovery_are_mutually_exclusive() public {
    bytes32 messageId = keccak256("local-vs-cross-chain");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false, LOCAL_REFUND),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    vm.prank(LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(messageId);

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.MessageNotFailed.selector, messageId));
    s_adapter.refundFailedMessage{value: 1 ether}(messageId);
  }

  function test_cross_chain_then_local_recovery_are_mutually_exclusive() public {
    bytes32 messageId = keccak256("cross-chain-vs-local");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false, LOCAL_REFUND),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    uint256 estimatedFee = s_adapter.estimateRefundFee(messageId);
    s_adapter.refundFailedMessage{value: estimatedFee + 1 ether}(messageId);

    vm.expectRevert(abi.encodeWithSelector(CrossChainERC4626Adapter.MessageNotFailed.selector, messageId));
    vm.prank(LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(messageId);
  }

  function test_recoverFailedMessageLocally_reverts_when_failed_message_token_amount_is_zero() public {
    bytes32 messageId = keccak256("local-recover-zero-amount");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false, LOCAL_REFUND),
      address(s_asset),
      0
    );
    s_router.routeMessage(address(s_adapter), message);

    (bool canRecover,,,) = s_adapter.checkLocalRecoveryEligibility(messageId);
    assertFalse(canRecover);

    vm.expectRevert(CrossChainERC4626Adapter.NoRefundableTokenAmounts.selector);
    vm.prank(LOCAL_REFUND);
    s_adapter.recoverFailedMessageLocally(messageId);
  }

  function test_failure_invalid_payload_length_stores_zero_local_refund_address() public {
    bytes32 messageId = keccak256("invalid-payload-local-refund");
    s_adapter.setTargetEnabled(address(s_vault), false);
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodeLegacyFiveFieldPayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);

    CrossChainERC4626Adapter.FailedMessageRecord memory stored = s_adapter.getFailedMessageRecord(messageId);
    assertEq(stored.localRefundAddress, address(0));

    (bool canRecover,,,) = s_adapter.checkLocalRecoveryEligibility(messageId);
    assertFalse(canRecover);
  }

  function test_checkLocalRecoveryEligibility_returns_false_when_message_not_failed() public {
    (bool canRecover,,,) = s_adapter.checkLocalRecoveryEligibility(bytes32("not-failed"));
    assertFalse(canRecover);
  }

  function _accrueDepositFee(
    uint256 feeAmount
  ) internal {
    s_adapter.setAssetFee(SOURCE_CHAIN_SELECTOR, address(s_vault), feeAmount);

    uint256 grossAmount = feeAmount * 10;
    Client.Any2EVMMessage memory message = _buildMessage(
      keccak256(abi.encode("accrue-fee", feeAmount)),
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), grossAmount - feeAmount, true),
      address(s_asset),
      grossAmount
    );
    s_asset.mint(address(s_router), grossAmount);
    s_router.routeMessage(address(s_adapter), message);
  }

  function _createFailedDepositMessage() internal returns (bytes32 messageId) {
    s_adapter.setTargetEnabled(address(s_vault), false);
    messageId = keccak256("failed-deposit-message");
    Client.Any2EVMMessage memory message = _buildMessage(
      messageId,
      SOURCE_CHAIN_SELECTOR,
      _ccipEvmSender(ORIGINAL_SENDER),
      _encodePayload(address(s_vault), _toBytes32(BENEFICIARY), 1, false),
      address(s_asset),
      1 ether
    );
    s_asset.mint(address(s_router), 1 ether);
    s_router.routeMessage(address(s_adapter), message);
    s_adapter.setTargetEnabled(address(s_vault), true);
    return messageId;
  }

  function _buildMessage(
    bytes32 messageId,
    uint64 sourceChainSelector,
    bytes memory sender,
    bytes memory data,
    address token,
    uint256 amount
  ) internal pure returns (Client.Any2EVMMessage memory message) {
    message.messageId = messageId;
    message.sourceChainSelector = sourceChainSelector;
    message.sender = sender;
    message.data = data;
    message.destTokenAmounts = new Client.EVMTokenAmount[](1);
    message.destTokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});
    return message;
  }

  function _encodePayload(
    address target,
    bytes32 beneficiary,
    uint256 minimumOut,
    bool returnToSourceChain
  ) internal pure returns (bytes memory) {
    return _encodePayload(target, beneficiary, minimumOut, returnToSourceChain, address(0));
  }

  function _encodePayload(
    address target,
    bytes32 beneficiary,
    uint256 minimumOut,
    bool returnToSourceChain,
    address localRefundAddress
  ) internal pure returns (bytes memory) {
    return abi.encode(target, beneficiary, minimumOut, _packDeliveryAndRefund(returnToSourceChain, localRefundAddress));
  }

  function _packDeliveryAndRefund(
    bool returnToSourceChain,
    address localRefundAddress
  ) internal pure returns (uint256 deliveryAndRefund) {
    deliveryAndRefund = (uint256(uint160(localRefundAddress)) << 1) | (returnToSourceChain ? 1 : 0);
    return deliveryAndRefund;
  }

  /// @dev Pre-remediation EVM payload shape `(,,,, bytes)` with empty trailing bytes (192 bytes) — for negative tests
  /// only.
  function _encodeLegacyFiveFieldPayload(
    address target,
    bytes32 beneficiary,
    uint256 minimumOut,
    bool returnToSourceChain
  ) internal pure returns (bytes memory) {
    return abi.encode(target, beneficiary, minimumOut, returnToSourceChain, bytes(""));
  }

  /// @dev Same encoding as `_encodePayload` (128-byte `Payload`); kept for SVM-named test scenarios.
  function _encodeSvmPayload(
    address target,
    bytes32 beneficiary,
    uint256 minimumOut,
    bool returnToSourceChain
  ) internal pure returns (bytes memory) {
    return _encodePayload(target, beneficiary, minimumOut, returnToSourceChain);
  }

  function _toBytes32(
    address account
  ) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(account)));
  }

  /// @dev CCIP OnRamp encodes EVM senders with `abi.encode(address)`, producing 32-byte left-padded values.
  function _ccipEvmSender(
    address account
  ) internal pure returns (bytes memory) {
    return abi.encode(account);
  }
}
