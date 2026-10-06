// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @notice Test-only ERC20 with configurable decimals and unrestricted mint/burn.
 * @dev NOT for production. Used to exercise the router across 6/8/18-decimal assets.
 */
contract MockERC20 is ERC20 {
  uint8 private immutable i_decimals;

  constructor(
    string memory _name,
    string memory _symbol,
    uint8 _decimals
  ) ERC20(_name, _symbol) {
    i_decimals = _decimals;
  }

  function decimals() public view override returns (uint8) {
    return i_decimals;
  }

  function mint(
    address _to,
    uint256 _amount
  ) external {
    _mint(_to, _amount);
  }

  function burn(
    address _from,
    uint256 _amount
  ) external {
    _burn(_from, _amount);
  }
}
