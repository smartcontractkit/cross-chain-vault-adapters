// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
  uint8 private immutable i_decimals;

  constructor(
    string memory name,
    string memory symbol,
    uint8 decimals_
  ) ERC20(name, symbol) {
    i_decimals = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return i_decimals;
  }

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }

  function burn(
    address from,
    uint256 amount
  ) external {
    _burn(from, amount);
  }
}
