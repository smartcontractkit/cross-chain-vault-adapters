// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

/// @notice Shared env parsing and input checks for the CCIP deploy, configure and check scripts.
/// @dev Arrays are comma-separated env vars (for example `CHAIN_SELECTORS=111,222`). An unset or empty var is an empty
/// array. Numbers accept decimal or `0x` hex.
abstract contract CcipScriptBase is Script {
  error MissingEnv(string name);
  error ZeroAddress(string name);
  error NoContractCode(string name, address account);
  error ArrayLengthMismatch(string nameA, uint256 lengthA, string nameB, uint256 lengthB);
  error ValueOutOfRange(string name, uint256 value, uint256 max);

  /// @notice Reads a required address and rejects `address(0)`.
  function _requireAddress(
    string memory name
  ) internal view returns (address value) {
    if (!_isSet(name)) revert MissingEnv(name);
    value = vm.envAddress(name);
    if (value == address(0)) revert ZeroAddress(name);
    return value;
  }

  /// @notice Reads an optional address; unset or empty means `address(0)`.
  function _optionalAddress(
    string memory name
  ) internal view returns (address value) {
    if (!_isSet(name)) return address(0);
    return vm.envAddress(name);
  }

  /// @notice Reads a required boolean (`true` or `false`).
  function _requireBool(
    string memory name
  ) internal view returns (bool value) {
    if (!_isSet(name)) revert MissingEnv(name);
    return vm.envBool(name);
  }

  /// @notice Reads an optional unsigned integer; unset or empty means `defaultValue`.
  function _optionalUint(
    string memory name,
    uint256 defaultValue
  ) internal view returns (uint256 value) {
    if (!_isSet(name)) return defaultValue;
    return vm.envUint(name);
  }

  /// @notice Reads an optional comma-separated list of unsigned integers.
  function _uintArray(
    string memory name
  ) internal view returns (uint256[] memory values) {
    if (!_isSet(name)) return new uint256[](0);
    return vm.envUint(name, ",");
  }

  /// @notice Reads an optional comma-separated list of addresses.
  function _addressArray(
    string memory name
  ) internal view returns (address[] memory values) {
    if (!_isSet(name)) return new address[](0);
    return vm.envAddress(name, ",");
  }

  /// @notice True when `name` is set to a non-empty value (an empty `.env` entry counts as unset).
  function _isSet(
    string memory name
  ) internal view returns (bool) {
    return vm.envExists(name) && bytes(vm.envString(name)).length != 0;
  }

  /// @notice Reverts unless `account` has deployed code.
  function _requireCode(
    string memory name,
    address account
  ) internal view {
    if (account.code.length == 0) revert NoContractCode(name, account);
  }

  /// @notice Reverts unless two arrays have the same length.
  function _requireSameLength(
    string memory nameA,
    uint256 lengthA,
    string memory nameB,
    uint256 lengthB
  ) internal pure {
    if (lengthA != lengthB) revert ArrayLengthMismatch(nameA, lengthA, nameB, lengthB);
  }

  /// @notice Narrows `value` to `uint64` (chain selectors) with a named error on overflow.
  function _toUint64(
    string memory name,
    uint256 value
  ) internal pure returns (uint64) {
    if (value > type(uint64).max) revert ValueOutOfRange(name, value, type(uint64).max);
    return uint64(value);
  }

  /// @notice Narrows `value` to a `bytes4` finality config (for example `0x00010000`).
  function _toBytes4(
    string memory name,
    uint256 value
  ) internal pure returns (bytes4) {
    if (value > type(uint32).max) revert ValueOutOfRange(name, value, type(uint32).max);
    return bytes4(uint32(value));
  }
}
