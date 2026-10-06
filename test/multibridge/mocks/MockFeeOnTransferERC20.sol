// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockFeeOnTransferERC20
 * @notice Test-only ERC20 that burns a basis-point fee from every transfer, so the recipient receives
 *         strictly less than the sent amount. Used to prove the delivered-amount floor on LOCAL
 *         delivery is measured on the recipient's balance delta. NOT for production.
 */
contract MockFeeOnTransferERC20 is ERC20 {
  uint16 public immutable i_feeBps;

  constructor(
    string memory _name,
    string memory _symbol,
    uint16 _feeBps
  ) ERC20(_name, _symbol) {
    i_feeBps = _feeBps;
  }

  function mint(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }

  /// @dev Burns the fee out of `value` before crediting the recipient (mint/burn paths unaffected).
  function _update(
    address from,
    address to,
    uint256 value
  ) internal override {
    if (from != address(0) && to != address(0)) {
      uint256 fee = (value * i_feeBps) / 10_000;
      if (fee > 0) {
        super._update(from, address(0), fee); // burn the fee
        value -= fee;
      }
    }
    super._update(from, to, value);
  }
}
