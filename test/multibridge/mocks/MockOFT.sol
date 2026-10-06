// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
  MessagingFee,
  MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {
  IOFT,
  OFTFeeDetail,
  OFTLimit,
  OFTReceipt,
  SendParam
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal burn hook used to simulate native-OFT (burn-from-holder) semantics in tests.
interface IMockBurnable {
  function burn(
    address from,
    uint256 amount
  ) external;
}

/**
 * @title MockOFT
 * @notice Test-only LayerZero OFT *adapter* mock over an existing ERC20, reproducing the
 *         local-decimals (LD) <-> shared-decimals (SD) dust truncation and a configurable native
 *         fee. NOT for production.
 * @dev On {send} it locks only the SD-floored amount (`amountSentLD`) from the caller, leaving the
 *      sub-SD remainder behind in the caller — exactly the dust behaviour the router books into its
 *      residue ledger. `approvalRequired` is true (adapter), so the caller must approve this mock.
 */
contract MockOFT is IOFT {
  using SafeERC20 for IERC20;

  address private immutable i_token;
  uint8 private immutable i_sharedDecimals;
  uint256 private immutable i_decimalConversionRate;
  uint256 public s_nativeFee;
  bool public s_approvalRequired = true;
  uint64 private s_nonce;
  /// @notice The `to` (peer bytes32) of the most recent {send} — lets tests assert a 32-byte
  ///         (e.g. Solana) recipient survives unmodified.
  bytes32 public s_lastTo;
  /// @notice The `extraOptions` of the most recent {send} (lets tests assert the lzReceive gas).
  bytes public s_lastExtraOptions;

  error MockOFTInsufficientFee();
  error MockOFTSlippage();
  error MockOFTRefundFailed();

  constructor(
    address _token,
    uint8 _sharedDecimals
  ) {
    i_token = _token;
    i_sharedDecimals = _sharedDecimals;
    uint8 localDecimals = IERC20Metadata(_token).decimals();
    i_decimalConversionRate = localDecimals > _sharedDecimals ? 10 ** (localDecimals - _sharedDecimals) : 1;
  }

  function setNativeFee(
    uint256 _fee
  ) external {
    s_nativeFee = _fee;
  }

  /// @notice Toggles adapter (true) vs native-OFT (false) semantics for {send}.
  function setApprovalRequired(
    bool _required
  ) external {
    s_approvalRequired = _required;
  }

  function oftVersion() external pure returns (bytes4, uint64) {
    return (0x02e49c2c, 1);
  }

  function token() external view returns (address) {
    return i_token;
  }

  function approvalRequired() external view returns (bool) {
    return s_approvalRequired;
  }

  function sharedDecimals() external view returns (uint8) {
    return i_sharedDecimals;
  }

  function quoteOFT(
    SendParam calldata _sendParam
  ) external view returns (OFTLimit memory limit, OFTFeeDetail[] memory fees, OFTReceipt memory receipt) {
    uint256 sent = _removeDust(_sendParam.amountLD);
    limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
    fees = new OFTFeeDetail[](0);
    receipt = OFTReceipt({amountSentLD: sent, amountReceivedLD: sent});
    return (limit, fees, receipt);
  }

  function quoteSend(
    SendParam calldata,
    bool
  ) external view returns (MessagingFee memory) {
    return MessagingFee({nativeFee: s_nativeFee, lzTokenFee: 0});
  }

  function send(
    SendParam calldata _sendParam,
    MessagingFee calldata _fee,
    address _refundAddress
  ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
    if (msg.value < _fee.nativeFee) revert MockOFTInsufficientFee();
    s_lastTo = _sendParam.to;
    s_lastExtraOptions = _sendParam.extraOptions;
    uint256 sent = _removeDust(_sendParam.amountLD);
    if (sent < _sendParam.minAmountLD) revert MockOFTSlippage();

    if (s_approvalRequired) {
      // Adapter locks only the SD-floored amount; dust remains with the caller.
      IERC20(i_token).safeTransferFrom(msg.sender, address(this), sent);
    } else {
      // Native-OFT semantics: burn the SD-floored amount directly from the caller (no approval).
      IMockBurnable(i_token).burn(msg.sender, sent);
    }

    if (msg.value > _fee.nativeFee) {
      (bool ok,) = _refundAddress.call{value: msg.value - _fee.nativeFee}("");
      if (!ok) revert MockOFTRefundFailed();
    }

    bytes32 guid = keccak256(abi.encode(_sendParam.dstEid, _sendParam.to, sent, ++s_nonce));
    msgReceipt = MessagingReceipt({guid: guid, nonce: s_nonce, fee: _fee});
    oftReceipt = OFTReceipt({amountSentLD: sent, amountReceivedLD: sent});
    emit OFTSent(guid, _sendParam.dstEid, msg.sender, sent, sent);
    return (msgReceipt, oftReceipt);
  }

  function _removeDust(
    uint256 _amountLD
  ) internal view returns (uint256) {
    return _amountLD - (_amountLD % i_decimalConversionRate);
  }
}
