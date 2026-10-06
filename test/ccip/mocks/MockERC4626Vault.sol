// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";

contract MockERC4626Vault is ERC20 {
  error DepositFailed();
  error RedeemFailed();

  IERC20 private immutable i_asset;

  bool public revertOnDeposit;
  bool public revertOnDepositWithLargeData;
  bytes public largeDepositRevertData;
  bool public revertOnRedeem;
  bool public useCustomDepositResult;
  bool public useCustomRedeemResult;
  uint256 public customDepositResult;
  uint256 public customRedeemResult;

  uint256 public lastDepositAssets;
  address public lastDepositReceiver;
  uint256 public lastRedeemShares;
  address public lastRedeemReceiver;
  address public lastRedeemOwner;

  constructor(
    address asset_,
    string memory name,
    string memory symbol
  ) ERC20(name, symbol) {
    i_asset = IERC20(asset_);
  }

  function asset() external view returns (address) {
    return address(i_asset);
  }

  function setDepositBehavior(
    bool shouldRevert,
    bool useCustomResult,
    uint256 result
  ) external {
    revertOnDeposit = shouldRevert;
    revertOnDepositWithLargeData = false;
    largeDepositRevertData = "";
    useCustomDepositResult = useCustomResult;
    customDepositResult = result;
  }

  function setLargeDepositRevertData(
    bytes calldata revertData
  ) external {
    revertOnDeposit = false;
    revertOnDepositWithLargeData = true;
    largeDepositRevertData = revertData;
  }

  function setRedeemBehavior(
    bool shouldRevert,
    bool useCustomResult,
    uint256 result
  ) external {
    revertOnRedeem = shouldRevert;
    useCustomRedeemResult = useCustomResult;
    customRedeemResult = result;
  }

  function mintShares(
    address to,
    uint256 amount
  ) external {
    _mint(to, amount);
  }

  function fundAssets(
    uint256 amount
  ) external {
    i_asset.transferFrom(msg.sender, address(this), amount);
  }

  function previewDeposit(
    uint256 assets
  ) external view returns (uint256 shares) {
    if (revertOnDeposit) revert DepositFailed();
    shares = useCustomDepositResult ? customDepositResult : assets;
    return shares;
  }

  function previewRedeem(
    uint256 shares
  ) external view returns (uint256 assets) {
    if (revertOnRedeem) revert RedeemFailed();
    assets = useCustomRedeemResult ? customRedeemResult : shares;
    return assets;
  }

  function deposit(
    uint256 assets,
    address receiver
  ) external returns (uint256 shares) {
    if (revertOnDepositWithLargeData) {
      bytes memory err = largeDepositRevertData;
      assembly {
        revert(add(err, 32), mload(err))
      }
    }
    if (revertOnDeposit) revert DepositFailed();

    lastDepositAssets = assets;
    lastDepositReceiver = receiver;

    i_asset.transferFrom(msg.sender, address(this), assets);

    shares = useCustomDepositResult ? customDepositResult : assets;
    _mint(receiver, shares);
    return shares;
  }

  function redeem(
    uint256 shares,
    address receiver,
    address owner
  ) external returns (uint256 assets) {
    if (revertOnRedeem) revert RedeemFailed();

    lastRedeemShares = shares;
    lastRedeemReceiver = receiver;
    lastRedeemOwner = owner;

    if (msg.sender != owner) {
      uint256 currentAllowance = allowance(owner, msg.sender);
      if (currentAllowance != type(uint256).max) {
        _approve(owner, msg.sender, currentAllowance - shares);
      }
    }

    _burn(owner, shares);

    assets = useCustomRedeemResult ? customRedeemResult : shares;
    i_asset.transfer(receiver, assets);
    return assets;
  }
}
