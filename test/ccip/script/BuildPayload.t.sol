// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BuildPayloadScript} from "../../../script/ccip/BuildPayload.s.sol";
import {CcipScriptBase} from "../../../script/ccip/CcipScriptBase.sol";
import {CrossChainERC4626Adapter} from "../../../src/ccip/CrossChainERC4626Adapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626Vault} from "../mocks/MockERC4626Vault.sol";
import {MockRouterClient} from "../mocks/MockRouterClient.sol";

import {Test} from "forge-std/Test.sol";

/// @notice Tests the read-only `pnpm ccip:build-payload` script against a locally deployed adapter.
/// @dev Env vars are process-global and test functions run in parallel, so every env-driven assertion lives in
/// `test_EnvDrivenBuildPayload`, which force-sets every variable before blanking one. The other tests call the
/// struct-based entry point only.
contract BuildPayloadTest is Test {
  uint64 private constant SELECTOR = 16015286601757825753;
  uint256 private constant AMOUNT = 1e18;
  uint256 private constant FEE = 1e15;

  BuildPayloadScript internal s_script;
  CrossChainERC4626Adapter internal s_adapter;
  MockRouterClient internal s_router;
  MockERC20 internal s_asset;
  MockERC4626Vault internal s_vault;
  address internal s_admin = makeAddr("admin");
  address internal s_user = makeAddr("user");
  address internal s_other = makeAddr("other");

  function setUp() public {
    s_script = new BuildPayloadScript();
    s_router = new MockRouterClient();
    s_asset = new MockERC20("CCIP-BnM", "BnM", 18);
    s_vault = new MockERC4626Vault(address(s_asset), "Vault CCIP-BnM", "vCCIP-BnM");
    s_adapter = new CrossChainERC4626Adapter(address(s_router), s_admin, s_admin, s_admin);
    // The 1:1 mock vault and the equal 1e15 fee rows make the deposit and redeem previews symmetric: with the fee
    // applied, `AMOUNT` previews to `AMOUNT - FEE`; without it, to the full `AMOUNT`.
    vm.startPrank(s_admin);
    s_adapter.setChainType(SELECTOR, CrossChainERC4626Adapter.ChainType.EVM);
    s_adapter.setTargetEnabled(address(s_vault), true);
    s_adapter.setProcessingEnabled(true, true);
    s_adapter.setAssetFee(SELECTOR, address(s_vault), FEE); // share row: deposit path
    s_adapter.setAssetFee(SELECTOR, address(s_asset), FEE); // asset row: redeem path
    vm.stopPrank();
  }

  function test_BuildsDepositPayload() public {
    BuildPayloadScript.Request memory request = _request(address(s_asset), true, s_user, 100, AMOUNT);
    (bytes memory payload, uint256 previewOut, uint256 minimumOut) = s_script.build(s_adapter, request);
    uint256 deliveryAndRefund = (uint256(uint160(s_user)) << 1) | 1;

    assertEq(previewOut, AMOUNT - FEE);
    assertEq(minimumOut, 989010000000000000); // (AMOUNT - FEE) * 9_900 / 10_000
    assertEq(
      payload,
      _expectedPayload(address(s_vault), s_user, 989010000000000000, deliveryAndRefund),
      "payload is the four 32-byte fields"
    );
  }

  function test_BuildsRedeemPayloadIdenticalToDeposit() public {
    // With the equal fee rows of these tutorials, the redemption payload is byte for byte the deposit payload.
    (bytes memory depositPayload,,) = s_script.build(s_adapter, _request(address(s_asset), true, s_user, 100, AMOUNT));
    (bytes memory redeemPayload,,) = s_script.build(s_adapter, _request(address(s_vault), true, s_user, 100, AMOUNT));

    assertEq(redeemPayload, depositPayload);
  }

  function test_ToleranceMovesMinimumOut() public {
    (, uint256 previewOut, uint256 minimumOut) =
      s_script.build(s_adapter, _request(address(s_asset), true, s_user, 0, AMOUNT));

    assertEq(previewOut, AMOUNT - FEE);
    assertEq(minimumOut, AMOUNT - FEE, "a zero tolerance keeps the full preview");

    (,, uint256 minimumOutHalfPercent) = s_script.build(s_adapter, _request(address(s_asset), true, s_user, 50, AMOUNT));
    assertEq(minimumOutHalfPercent, 994005000000000000, "0.5% tolerance"); // (AMOUNT - FEE) * 9_950 / 10_000
  }

  function test_NoReturnToSourceSkipsFeeAndFlag() public {
    (bytes memory payload, uint256 previewOut,) =
      s_script.build(s_adapter, _request(address(s_asset), false, s_user, 100, AMOUNT));
    uint256 deliveryAndRefund = uint256(uint160(s_user)) << 1;

    assertEq(previewOut, AMOUNT, "no fee when the output stays on this chain");
    assertEq(
      payload,
      _expectedPayload(address(s_vault), s_user, AMOUNT * 9_900 / 10_000, deliveryAndRefund),
      "bit 0 of deliveryAndRefund is unset"
    );
  }

  function test_RevertsWhenPreviewIsZero() public {
    // The flat fee consumes the whole deposit, so `preview` returns 0.
    vm.expectRevert(abi.encodeWithSelector(BuildPayloadScript.PreviewIsZero.selector));
    s_script.build(s_adapter, _request(address(s_asset), true, s_user, 100, FEE));
  }

  function test_RejectsToleranceAboveFull() public {
    vm.expectRevert(
      abi.encodeWithSelector(CcipScriptBase.ValueOutOfRange.selector, "TOLERANCE_BPS", uint256(10_001), uint256(10_000))
    );
    s_script.build(s_adapter, _request(address(s_asset), true, s_user, 10_001, AMOUNT));
  }

  function test_RejectsAdapterWithoutCode() public {
    address eoa = makeAddr("eoa");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.NoContractCode.selector, "ADAPTER", eoa));
    s_script.build(CrossChainERC4626Adapter(payable(eoa)), _request(address(s_asset), true, s_user, 100, AMOUNT));
  }

  function test_EnvDrivenBuildPayload() public {
    _setEnv();

    // A record left behind by an aborted run would resolve the target and the adapter, so start clean.
    string memory record = string.concat("deployments/ccip/", vm.toString(block.chainid), ".json");
    if (vm.exists(record)) vm.removeFile(record);

    // Blanking any required variable fails with a named error.
    vm.setEnv("REQUEST_TOKEN", "");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "REQUEST_TOKEN"));
    s_script.run();
    vm.setEnv("REQUEST_TOKEN", vm.toString(address(s_asset)));

    vm.setEnv("AMOUNT", "");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "AMOUNT"));
    s_script.run();
    vm.setEnv("AMOUNT", vm.toString(AMOUNT));

    vm.setEnv("SOURCE_CHAIN_SELECTOR", "");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "SOURCE_CHAIN_SELECTOR"));
    s_script.run();
    vm.setEnv("SOURCE_CHAIN_SELECTOR", vm.toString(uint256(SELECTOR)));

    vm.setEnv("TOLERANCE_BPS", "");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "TOLERANCE_BPS"));
    s_script.run();

    vm.setEnv("TOLERANCE_BPS", "10001");
    vm.expectRevert(
      abi.encodeWithSelector(CcipScriptBase.ValueOutOfRange.selector, "TOLERANCE_BPS", uint256(10001), uint256(10_000))
    );
    s_script.run();
    vm.setEnv("TOLERANCE_BPS", "100");

    // BENEFICIARY falls back to MY_ADDRESS; both blank fails.
    vm.setEnv("BENEFICIARY", "");
    vm.setEnv("MY_ADDRESS", "");
    vm.expectRevert(abi.encodeWithSelector(CcipScriptBase.MissingEnv.selector, "BENEFICIARY"));
    s_script.run();
    vm.setEnv("MY_ADDRESS", vm.toString(s_user));

    // REQUEST_TARGET and REQUEST_ADAPTER fall back to the deployment record; no record fails with a hint.
    vm.setEnv("REQUEST_TARGET", "");
    vm.expectRevert(
      abi.encodeWithSelector(
        BuildPayloadScript.TargetNotFound.selector, string.concat("set REQUEST_TARGET or deploy first (", record, ")")
      )
    );
    s_script.run();

    vm.setEnv("REQUEST_TARGET", vm.toString(address(s_vault)));
    vm.setEnv("REQUEST_ADAPTER", "");
    vm.expectRevert(
      abi.encodeWithSelector(
        BuildPayloadScript.AdapterNotFound.selector, string.concat("set REQUEST_ADAPTER or deploy first (", record, ")")
      )
    );
    s_script.run();

    // The record resolves the vault and the adapter; BENEFICIARY and LOCAL_REFUND_ADDRESS default to MY_ADDRESS.
    vm.setEnv("REQUEST_TARGET", "");
    vm.writeFile(
      record,
      string.concat(
        "{\"adapter\":\"",
        vm.toString(address(s_adapter)),
        "\",\"vaultTarget\":\"",
        vm.toString(address(s_vault)),
        "\"}"
      )
    );
    bytes memory payload = s_script.run();
    vm.removeFile(record);

    assertEq(
      payload,
      _expectedPayload(address(s_vault), s_user, 989010000000000000, (uint256(uint160(s_user)) << 1) | 1),
      "the record-resolved build matches the struct-based build"
    );

    // A record without a vault, as an adapter-only deploy writes, fails with a hint instead of an opaque
    // InvalidTarget(address(0)) from the adapter.
    vm.writeFile(
      record,
      string.concat(
        "{\"adapter\":\"",
        vm.toString(address(s_adapter)),
        "\",\"vaultTarget\":\"0x0000000000000000000000000000000000000000\"}"
      )
    );
    vm.expectRevert(
      abi.encodeWithSelector(
        BuildPayloadScript.TargetNotFound.selector,
        string.concat(record, " records vaultTarget 0x0: set REQUEST_TARGET or deploy with VAULT_TARGET")
      )
    );
    s_script.run();
    vm.removeFile(record);

    // REQUEST_TARGET, REQUEST_ADAPTER, BENEFICIARY and LOCAL_REFUND_ADDRESS override the record and the defaults;
    // RETURN_TO_SOURCE=false skips the fee and leaves bit 0 of deliveryAndRefund unset.
    vm.writeFile(
      record,
      string.concat("{\"adapter\":\"", vm.toString(s_other), "\",\"vaultTarget\":\"", vm.toString(s_other), "\"}")
    );
    vm.setEnv("REQUEST_TARGET", vm.toString(address(s_vault)));
    vm.setEnv("REQUEST_ADAPTER", vm.toString(address(s_adapter)));
    vm.setEnv("BENEFICIARY", vm.toString(s_other));
    vm.setEnv("LOCAL_REFUND_ADDRESS", vm.toString(s_admin));
    vm.setEnv("RETURN_TO_SOURCE", "false");
    payload = s_script.run();
    vm.removeFile(record);

    assertEq(
      payload,
      _expectedPayload(address(s_vault), s_other, AMOUNT * 9_900 / 10_000, uint256(uint160(s_admin)) << 1),
      "the overrides win over the record and the defaults"
    );
  }

  /// @dev Force-sets every variable the script reads, so no parallel test can leak state into this one.
  function _setEnv() private {
    vm.setEnv("REQUEST_TOKEN", vm.toString(address(s_asset)));
    vm.setEnv("REQUEST_TARGET", vm.toString(address(s_vault)));
    vm.setEnv("REQUEST_ADAPTER", vm.toString(address(s_adapter)));
    vm.setEnv("AMOUNT", vm.toString(AMOUNT));
    vm.setEnv("SOURCE_CHAIN_SELECTOR", vm.toString(uint256(SELECTOR)));
    vm.setEnv("TOLERANCE_BPS", "100");
    vm.setEnv("RETURN_TO_SOURCE", "true");
    vm.setEnv("BENEFICIARY", "");
    vm.setEnv("MY_ADDRESS", vm.toString(s_user));
    vm.setEnv("LOCAL_REFUND_ADDRESS", "");
  }

  /// @dev A deposit or redemption request for `amount`, returning to the source chain.
  function _request(
    address token,
    bool returnToSource,
    address beneficiary,
    uint256 toleranceBps,
    uint256 amount
  ) private view returns (BuildPayloadScript.Request memory) {
    return BuildPayloadScript.Request({
      token: token,
      target: address(s_vault),
      amount: amount,
      sourceChainSelector: SELECTOR,
      returnToSource: returnToSource,
      beneficiary: beneficiary,
      localRefund: beneficiary,
      toleranceBps: toleranceBps
    });
  }

  /// @dev The four payload words, built independently of the script's `abi.encode` of the adapter's struct: the
  /// addresses occupy the low 20 bytes of their words, as the adapter's `address(uint160(uint256(word)))` decodes.
  function _expectedPayload(
    address target,
    address beneficiary,
    uint256 minimumOut,
    uint256 deliveryAndRefund
  ) private pure returns (bytes memory) {
    return abi.encodePacked(
      bytes32(uint256(uint160(target))),
      bytes32(uint256(uint160(beneficiary))),
      bytes32(minimumOut),
      bytes32(deliveryAndRefund)
    );
  }
}
