// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts@5.1.0/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@5.1.0/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts@5.1.0/token/ERC20/extensions/ERC4626.sol";

/// @notice Example ERC-4626 vault for testnet tutorials. Not audited. Do not use it in production.
/// @dev OpenZeppelin `ERC4626` with no added logic: shares convert 1:1 to assets until the vault receives assets
/// outside `deposit` and `mint`. `Ownable` adds only `owner()`, so the share token's CCIP admin can be registered
/// through `RegistryModuleOwnerCustom.registerAdminViaOwner`.
contract ExampleERC4626Vault is ERC4626, Ownable {
  constructor(
    IERC20 asset_,
    string memory name_,
    string memory symbol_,
    address initialOwner
  ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(initialOwner) {}
}
