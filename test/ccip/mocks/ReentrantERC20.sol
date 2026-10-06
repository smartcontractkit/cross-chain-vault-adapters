// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

contract ReentrantERC20 is MockERC20 {
  address public reentrancyTarget;
  bytes public reentrancyCallData;
  bool public reenterOnTransfer;
  bool private s_inHook;

  bool public lastReentrancyCallSuccess;
  bytes public lastReentrancyReturnData;

  constructor(
    string memory name,
    string memory symbol,
    uint8 decimals_
  ) MockERC20(name, symbol, decimals_) {}

  function configureReentrancy(
    address target,
    bytes memory callData,
    bool enabled
  ) external {
    reentrancyTarget = target;
    reentrancyCallData = callData;
    reenterOnTransfer = enabled;
  }

  function transfer(
    address to,
    uint256 amount
  ) public override returns (bool) {
    bool success = super.transfer(to, amount);
    _attemptReentrancy();
    return success;
  }

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) public override returns (bool) {
    bool success = super.transferFrom(from, to, amount);
    _attemptReentrancy();
    return success;
  }

  function _attemptReentrancy() private {
    if (!reenterOnTransfer || s_inHook || reentrancyTarget == address(0)) return;

    s_inHook = true;
    (lastReentrancyCallSuccess, lastReentrancyReturnData) = reentrancyTarget.call(reentrancyCallData);
    s_inHook = false;
  }
}
