// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console

import {CrossChainERC4626Adapter} from "../../src/ccip/CrossChainERC4626Adapter.sol";
import {CcipScriptBase} from "./CcipScriptBase.sol";

import {console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @notice Read-only builder of the 128-byte CCIP request payload for a deposit or a redemption, using the same
/// `.env` as the deploy scripts. Calls the adapter's `preview`, applies the tolerance, packs the delivery and
/// refund options, ABI-encodes the payload, and prints it with every field value. Sends no transactions.
/// @dev pnpm ccip:build-payload --rpc-url $RPC_URL
///
/// Required env vars: `REQUEST_TOKEN` (the token as the adapter receives it: the vault's asset for a deposit,
/// the vault itself for a redemption), `AMOUNT` (in `REQUEST_TOKEN`'s smallest units), `SOURCE_CHAIN_SELECTOR`
/// (the chain the request is sent from), and `TOLERANCE_BPS` (an explicit choice, in basis points:
/// `minimumOut = preview * (10_000 - TOLERANCE_BPS) / 10_000`, so 100 is a 1% tolerance and 50 is 0.5%).
/// Optional env vars: `REQUEST_TARGET` (the vault; default: the `vaultTarget` field of
/// `deployments/ccip/<chainId>.json`), `REQUEST_ADAPTER` (default: the `adapter` field of the same record),
/// `RETURN_TO_SOURCE` (default `true`), `BENEFICIARY` (default `MY_ADDRESS`), `LOCAL_REFUND_ADDRESS` (default:
/// the beneficiary).
///
/// The payload is `abi.encode` of the adapter's `Payload` struct, so it is byte-identical to
/// `cast abi-encode "f(address,address,uint256,uint256)"` and to the payload encoders of the E2E tooling and the
/// reference frontends. The `PAYLOAD:` line is machine-readable: capture it with `awk '/PAYLOAD:/ {print $2}'`.
contract BuildPayloadScript is CcipScriptBase {
  using stdJson for string;

  error AdapterNotFound(string hint);
  error TargetNotFound(string hint);
  error PreviewIsZero();
  error UnexpectedPayloadLength(uint256 length);

  /// @notice One request to build the payload for.
  /// @dev A script input aggregate that never reaches storage, so slot packing is irrelevant.
  // solhint-disable-next-line gas-struct-packing
  struct Request {
    address token; // token as the adapter receives it
    address target; // allowlisted vault the request acts on
    uint256 amount; // in the token's smallest units
    uint64 sourceChainSelector; // chain the request is sent from
    bool returnToSource; // return the output to the source chain
    address beneficiary; // receives the output on the source chain
    address localRefund; // takes the token back on this chain if the request fails
    uint256 toleranceBps; // minimumOut = preview * (10_000 - toleranceBps) / 10_000
  }

  /// @notice Reads the env vars and prints the payload for the resolved adapter and vault.
  function run() external view returns (bytes memory payload) {
    address beneficiary = _beneficiary();
    address localRefund = _optionalAddress("LOCAL_REFUND_ADDRESS");
    if (localRefund == address(0)) localRefund = beneficiary;
    Request memory request = Request({
      token: _requireAddress("REQUEST_TOKEN"),
      target: _resolveTarget(),
      amount: _requireUint("AMOUNT"),
      sourceChainSelector: _toUint64("SOURCE_CHAIN_SELECTOR", _requireUint("SOURCE_CHAIN_SELECTOR")),
      returnToSource: vm.envOr("RETURN_TO_SOURCE", true),
      beneficiary: beneficiary,
      localRefund: localRefund,
      toleranceBps: _requireUint("TOLERANCE_BPS")
    });
    (payload,,) = build(CrossChainERC4626Adapter(payable(_resolveAdapter())), request);
    return payload;
  }

  /// @notice Builds and prints the payload for `request`, and returns it with the preview and the minimum out.
  function build(
    CrossChainERC4626Adapter adapter,
    Request memory request
  ) public view returns (bytes memory payload, uint256 previewOut, uint256 minimumOut) {
    _requireCode("ADAPTER", address(adapter));
    if (request.toleranceBps > 10_000) {
      revert ValueOutOfRange("TOLERANCE_BPS", request.toleranceBps, 10_000);
    }
    previewOut = adapter.preview(
      request.token, request.target, request.amount, request.returnToSource, request.sourceChainSelector
    );
    if (previewOut == 0) revert PreviewIsZero();
    minimumOut = previewOut * (10_000 - request.toleranceBps) / 10_000;
    uint256 deliveryAndRefund = (uint256(uint160(request.localRefund)) << 1) | (request.returnToSource ? 1 : 0);
    payload = abi.encode(
      CrossChainERC4626Adapter.Payload({
        target: request.target,
        beneficiary: bytes32(uint256(uint160(request.beneficiary))),
        minimumOut: minimumOut,
        deliveryAndRefund: deliveryAndRefund
      })
    );
    if (payload.length != 128) revert UnexpectedPayloadLength(payload.length);

    console2.log("Adapter:            ", address(adapter));
    console2.log("Token:              ", request.token);
    console2.log("Vault target:       ", request.target);
    console2.log("Amount:             ", request.amount);
    console2.log("Return to source:   ", request.returnToSource);
    console2.log("Source selector:    ", request.sourceChainSelector);
    console2.log("Tolerance (bps):    ", request.toleranceBps);
    console2.log("Preview:            ", previewOut);
    console2.log("Minimum out:        ", minimumOut);
    console2.log("Beneficiary:        ", request.beneficiary);
    console2.log("Local refund:       ", request.localRefund);
    console2.log("Delivery and refund:", deliveryAndRefund);
    console2.log("Byte length:        ", payload.length);
    console2.log("PAYLOAD:", vm.toString(payload));
    return (payload, previewOut, minimumOut);
  }

  /// @dev `BENEFICIARY`, or `MY_ADDRESS` when unset.
  function _beneficiary() private view returns (address beneficiary) {
    beneficiary = _optionalAddress("BENEFICIARY");
    if (beneficiary == address(0)) beneficiary = _optionalAddress("MY_ADDRESS");
    if (beneficiary == address(0)) revert MissingEnv("BENEFICIARY");
    return beneficiary;
  }

  /// @dev `REQUEST_TARGET`, or the `vaultTarget` field of the deployment record when unset.
  function _resolveTarget() private view returns (address target) {
    target = _optionalAddress("REQUEST_TARGET");
    if (target != address(0)) return target;
    string memory path = _recordPath();
    if (!vm.exists(path)) {
      revert TargetNotFound(string.concat("set REQUEST_TARGET or deploy first (", path, ")"));
    }
    target = vm.readFile(path).readAddress(".vaultTarget");
    if (target == address(0)) {
      revert TargetNotFound(string.concat(
          path, " records vaultTarget 0x0: set REQUEST_TARGET or deploy with VAULT_TARGET"
        ));
    }
    return target;
  }

  /// @dev `REQUEST_ADAPTER`, or the `adapter` field of the deployment record when unset.
  function _resolveAdapter() private view returns (address adapter) {
    adapter = _optionalAddress("REQUEST_ADAPTER");
    if (adapter != address(0)) return adapter;
    string memory path = _recordPath();
    if (!vm.exists(path)) {
      revert AdapterNotFound(string.concat("set REQUEST_ADAPTER or deploy first (", path, ")"));
    }
    return vm.readFile(path).readAddress(".adapter");
  }

  /// @dev The deployment record that `pnpm ccip:deploy` writes.
  function _recordPath() private view returns (string memory) {
    return string.concat("deployments/ccip/", vm.toString(block.chainid), ".json");
  }

  /// @dev A required unsigned integer.
  function _requireUint(
    string memory name
  ) private view returns (uint256 value) {
    if (!_isSet(name)) revert MissingEnv(name);
    return vm.envUint(name);
  }
}
