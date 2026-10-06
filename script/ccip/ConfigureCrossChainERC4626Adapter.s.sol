// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {console2} from "forge-std/Script.sol";

/// @notice Applies the post-deploy settings the factory does not cover: EVM return-lane `extraArgs` format (CCIP v1 or
/// v2), per-token return finality, inbound finality, CCVs, and native funding for return-leg fees. Every group is
/// optional; unset groups are skipped. All setters except funding need `DEFAULT_ADMIN_ROLE`, so broadcast as the admin.
/// @dev Fill in `.env` at the repo root (see `.env.example`), then:
/// pnpm ccip:configure --rpc-url $RPC_URL --account admin --broadcast
///
/// Env vars (all lists are comma-separated and parallel within a group):
/// - `ADAPTER` (required).
/// - `RETURN_LANE_SELECTORS`, `RETURN_LANE_FORMATS`: 1 = legacy `GenericExtraArgsV2` (CCIP v1 lanes, also the default
///   for unset lanes), 2 = `GenericExtraArgsV3` basic (CCIP v2 lanes).
/// - `RETURN_FINALITY_SELECTORS`, `RETURN_FINALITY_TOKENS`, `RETURN_FINALITIES`: requested finality per return lane
///   and bridged token, only for v2 lanes. `0x00000000` waits for finality, `0x00010000` for the `safe` tag, and
///   `1`..`65535` for that many blocks.
/// - `INBOUND_FINALITY_SELECTORS`, `INBOUND_FINALITIES`: allowed finality for inbound messages per source chain.
/// - `CCV_SOURCE_SELECTOR`, `CCV_REQUIRED`, `CCV_OPTIONAL`, `CCV_OPTIONAL_THRESHOLD`: CCV policy for one source chain.
/// - `FUND_NATIVE_WEI`: native amount to send to the adapter for return-leg CCIP fees.
contract ConfigureCrossChainERC4626AdapterScript is CcipScriptBase {
  error InvalidReturnLaneFormat(uint64 destinationChainSelector, uint256 format);
  error NotACrossChainERC4626Adapter(address adapter);
  error FundingFailed(address adapter, uint256 amount);

  struct ReturnFinality {
    uint64 destinationChainSelector;
    address token;
    bytes4 requestedFinality;
  }

  struct InboundFinality {
    uint64 sourceChainSelector;
    bytes4 allowedFinalityConfig;
  }

  struct Settings {
    uint64[] returnLaneSelectors;
    CrossChainERC4626Adapter.EvmReturnExtraArgsFormat[] returnLaneFormats;
    ReturnFinality[] returnFinalities;
    InboundFinality[] inboundFinalities;
    address[] requiredCcvs;
    address[] optionalCcvs;
    uint256 fundNativeWei;
    uint64 ccvSourceSelector; // ─╮ packed with the next two fields
    uint8 optionalThreshold; //   │
    bool setCcvs; // ─────────────╯
  }

  /// @notice Reads `.env` and applies it to `ADAPTER`.
  function run() external {
    CrossChainERC4626Adapter adapter = CrossChainERC4626Adapter(payable(_requireAddress("ADAPTER")));
    configure(adapter, loadSettings());
  }

  /// @notice Parses the settings from env vars. Public so tests and tooling can reuse it.
  function loadSettings() public view returns (Settings memory settings) {
    uint256[] memory laneSelectors = _uintArray("RETURN_LANE_SELECTORS");
    uint256[] memory laneFormats = _uintArray("RETURN_LANE_FORMATS");
    _requireSameLength("RETURN_LANE_SELECTORS", laneSelectors.length, "RETURN_LANE_FORMATS", laneFormats.length);
    settings.returnLaneSelectors = new uint64[](laneSelectors.length);
    settings.returnLaneFormats = new CrossChainERC4626Adapter.EvmReturnExtraArgsFormat[](laneSelectors.length);
    for (uint256 i = 0; i < laneSelectors.length; ++i) {
      uint64 selector = _toUint64("RETURN_LANE_SELECTORS", laneSelectors[i]);
      uint256 format = laneFormats[i];
      if (format == 0 || format > uint256(type(CrossChainERC4626Adapter.EvmReturnExtraArgsFormat).max)) {
        revert InvalidReturnLaneFormat(selector, format);
      }
      settings.returnLaneSelectors[i] = selector;
      settings.returnLaneFormats[i] = CrossChainERC4626Adapter.EvmReturnExtraArgsFormat(format);
    }

    uint256[] memory finalitySelectors = _uintArray("RETURN_FINALITY_SELECTORS");
    address[] memory finalityTokens = _addressArray("RETURN_FINALITY_TOKENS");
    uint256[] memory finalities = _uintArray("RETURN_FINALITIES");
    _requireSameLength(
      "RETURN_FINALITY_SELECTORS", finalitySelectors.length, "RETURN_FINALITY_TOKENS", finalityTokens.length
    );
    _requireSameLength("RETURN_FINALITY_TOKENS", finalityTokens.length, "RETURN_FINALITIES", finalities.length);
    settings.returnFinalities = new ReturnFinality[](finalitySelectors.length);
    for (uint256 i = 0; i < finalitySelectors.length; ++i) {
      if (finalityTokens[i] == address(0)) revert ZeroAddress("RETURN_FINALITY_TOKENS");
      settings.returnFinalities[i] = ReturnFinality({
        destinationChainSelector: _toUint64("RETURN_FINALITY_SELECTORS", finalitySelectors[i]),
        token: finalityTokens[i],
        requestedFinality: _toBytes4("RETURN_FINALITIES", finalities[i])
      });
    }

    uint256[] memory inboundSelectors = _uintArray("INBOUND_FINALITY_SELECTORS");
    uint256[] memory inboundFinalities = _uintArray("INBOUND_FINALITIES");
    _requireSameLength(
      "INBOUND_FINALITY_SELECTORS", inboundSelectors.length, "INBOUND_FINALITIES", inboundFinalities.length
    );
    settings.inboundFinalities = new InboundFinality[](inboundSelectors.length);
    for (uint256 i = 0; i < inboundSelectors.length; ++i) {
      settings.inboundFinalities[i] = InboundFinality({
        sourceChainSelector: _toUint64("INBOUND_FINALITY_SELECTORS", inboundSelectors[i]),
        allowedFinalityConfig: _toBytes4("INBOUND_FINALITIES", inboundFinalities[i])
      });
    }

    uint256 ccvSource = _optionalUint("CCV_SOURCE_SELECTOR", 0);
    if (ccvSource != 0) {
      settings.setCcvs = true;
      settings.ccvSourceSelector = _toUint64("CCV_SOURCE_SELECTOR", ccvSource);
      settings.requiredCcvs = _addressArray("CCV_REQUIRED");
      settings.optionalCcvs = _addressArray("CCV_OPTIONAL");
      uint256 threshold = _optionalUint("CCV_OPTIONAL_THRESHOLD", 0);
      if (threshold > type(uint8).max) revert ValueOutOfRange("CCV_OPTIONAL_THRESHOLD", threshold, type(uint8).max);
      settings.optionalThreshold = uint8(threshold);
    }

    settings.fundNativeWei = _optionalUint("FUND_NATIVE_WEI", 0);
    return settings;
  }

  /// @notice Applies `settings` to `adapter` in the order the contract requires (lane format before finality).
  function configure(
    CrossChainERC4626Adapter adapter,
    Settings memory settings
  ) public {
    _requireAdapter(adapter);

    vm.startBroadcast();
    for (uint256 i = 0; i < settings.returnLaneSelectors.length; ++i) {
      adapter.setEvmReturnLaneFormat(settings.returnLaneSelectors[i], settings.returnLaneFormats[i]);
      console2.log("Return lane format set:", settings.returnLaneSelectors[i], uint256(settings.returnLaneFormats[i]));
    }
    for (uint256 i = 0; i < settings.returnFinalities.length; ++i) {
      ReturnFinality memory row = settings.returnFinalities[i];
      adapter.setEvmReturnRequestedFinality(row.destinationChainSelector, row.token, row.requestedFinality);
      console2.log("Return finality set:   ", row.destinationChainSelector, row.token);
    }
    for (uint256 i = 0; i < settings.inboundFinalities.length; ++i) {
      InboundFinality memory row = settings.inboundFinalities[i];
      adapter.setInboundFinality(row.sourceChainSelector, row.allowedFinalityConfig);
      console2.log("Inbound finality set:  ", row.sourceChainSelector);
    }
    if (settings.setCcvs) {
      adapter.setCCVsConfig(
        settings.ccvSourceSelector, settings.requiredCcvs, settings.optionalCcvs, settings.optionalThreshold
      );
      console2.log("CCV config set:        ", settings.ccvSourceSelector);
    }
    if (settings.fundNativeWei != 0) {
      (bool ok,) = address(adapter).call{value: settings.fundNativeWei}("");
      if (!ok) revert FundingFailed(address(adapter), settings.fundNativeWei);
      console2.log("Funded adapter (wei):  ", settings.fundNativeWei);
    }
    vm.stopBroadcast();
  }

  function _requireAdapter(
    CrossChainERC4626Adapter adapter
  ) private view {
    _requireCode("ADAPTER", address(adapter));
    (bool ok, bytes memory data) = address(adapter).staticcall(abi.encodeWithSignature("typeAndVersion()"));
    if (!ok || keccak256(bytes(abi.decode(data, (string)))) != keccak256(bytes("CrossChainERC4626Adapter 1.0.0"))) {
      revert NotACrossChainERC4626Adapter(address(adapter));
    }
  }
}
