// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockERC4626
 * @notice Test-only ERC-4626 vault built on the OpenZeppelin implementation, with helpers to move
 *         the share price (yield/loss) and to force pathological return values.
 * @dev NOT for production. The OZ base already applies virtual-shares inflation-attack mitigation;
 *      these helpers let tests probe slippage and rounding behaviour at the router's call site.
 */
contract MockERC4626 is ERC4626 {
  using SafeERC20 for IERC20;

  /// @notice When true, {deposit}/{redeem} revert to simulate a misbehaving/paused vault.
  bool public s_reverting;

  error MockERC4626Reverting();

  constructor(
    IERC20 _asset,
    string memory _name,
    string memory _symbol
  ) ERC20(_name, _symbol) ERC4626(_asset) {}

  /// @notice Donates assets to the vault to raise the share price (positive yield).
  function simulateYield(
    uint256 _assets
  ) external {
    // Pull assets from caller into the vault, increasing assets-per-share.
    IERC20(asset()).safeTransferFrom(msg.sender, address(this), _assets);
  }

  /// @notice Burns assets from the vault to lower the share price (loss), via a transfer out.
  function simulateLoss(
    uint256 _assets,
    address _sink
  ) external {
    IERC20(asset()).safeTransfer(_sink, _assets);
  }

  /// @notice Toggles a hard revert on deposit/redeem.
  function setReverting(
    bool _reverting
  ) external {
    s_reverting = _reverting;
  }

  function deposit(
    uint256 _assets,
    address _receiver
  ) public override returns (uint256) {
    if (s_reverting) revert MockERC4626Reverting();
    return super.deposit(_assets, _receiver);
  }

  function redeem(
    uint256 _shares,
    address _receiver,
    address _owner
  ) public override returns (uint256) {
    if (s_reverting) revert MockERC4626Reverting();
    return super.redeem(_shares, _receiver, _owner);
  }
}
