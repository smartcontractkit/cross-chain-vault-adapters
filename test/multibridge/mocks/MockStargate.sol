// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
  MessagingFee,
  MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTFeeDetail, OFTLimit, OFTReceipt, SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStargate, StargateType, Ticket} from "../../../src/multibridge/stargate/IStargate.sol";

/**
 * @title MockStargate
 * @notice Test-only Stargate V2 pool mock. Like {MockOFT} it is `IOFT`-shaped (Stargate pools ARE
 *         LayerZero OFTs) with two Stargate-specific traits modelled faithfully: (1) it implements the
 *         native `sendToken` returning a (taxi-empty) {Ticket}; (2) it charges a configurable pooled-LP
 *         fee, so the recipient receives LESS than sent (`amountReceivedLD < amountSentLD`) — the reason
 *         a route must carry a `minAmountLD` slippage floor. NOT for production.
 * @dev `approvalRequired` is true (ERC-20 pool), so the caller must approve this mock; on send it locks
 *      the SD-floored amount and leaves sub-SD dust with the caller, like the real pool.
 */
contract MockStargate is IStargate {
  using SafeERC20 for IERC20;

  address private immutable i_token;
  uint8 private immutable i_sharedDecimals;
  uint256 private immutable i_decimalConversionRate;
  uint256 public s_nativeFee;
  uint16 public s_lpFeeBps;
  uint64 private s_nonce;
  /// @notice The `to` (peer bytes32) of the most recent send — lets tests assert a 32-byte
  ///         (e.g. Solana) recipient survives unmodified.
  bytes32 public s_lastTo;

  error MockStargateInsufficientFee();
  error MockStargateSlippage();
  error MockStargateRefundFailed();

  constructor(
    address _token,
    uint8 _sharedDecimals,
    uint16 _lpFeeBps
  ) {
    i_token = _token;
    i_sharedDecimals = _sharedDecimals;
    s_lpFeeBps = _lpFeeBps;
    uint8 localDecimals = IERC20Metadata(_token).decimals();
    i_decimalConversionRate = localDecimals > _sharedDecimals ? 10 ** (localDecimals - _sharedDecimals) : 1;
  }

  function setNativeFee(
    uint256 _fee
  ) external {
    s_nativeFee = _fee;
  }

  function setLpFeeBps(
    uint16 _bps
  ) external {
    s_lpFeeBps = _bps;
  }

  function oftVersion() external pure returns (bytes4, uint64) {
    return (0x02e49c2c, 1);
  }

  function token() external view returns (address) {
    return i_token;
  }

  function approvalRequired() external pure returns (bool) {
    return true;
  }

  function sharedDecimals() external view returns (uint8) {
    return i_sharedDecimals;
  }

  function stargateType() external pure returns (StargateType) {
    return StargateType.Pool;
  }

  function quoteOFT(
    SendParam calldata _sendParam
  ) external view returns (OFTLimit memory limit, OFTFeeDetail[] memory fees, OFTReceipt memory receipt) {
    uint256 sent = _removeDust(_sendParam.amountLD);
    uint256 received = _afterLpFee(sent);
    limit = OFTLimit({minAmountLD: 0, maxAmountLD: type(uint256).max});
    fees = new OFTFeeDetail[](1);
    // Safe: `received = sent - LP fee <= sent`, so `sent - received` is a small non-negative fee.
    // forge-lint: disable-next-line(unsafe-typecast)
    fees[0] = OFTFeeDetail({feeAmountLD: int256(sent - received), description: "LP fee"});
    receipt = OFTReceipt({amountSentLD: sent, amountReceivedLD: received});
    return (limit, fees, receipt);
  }

  function quoteSend(
    SendParam calldata,
    bool
  ) external view returns (MessagingFee memory) {
    return MessagingFee({nativeFee: s_nativeFee, lzTokenFee: 0});
  }

  /// @notice Standard `IOFT.send` (taxi). Provided for interface completeness; delegates to the same
  ///         core as {sendToken} and drops the {Ticket}.
  function send(
    SendParam calldata _sendParam,
    MessagingFee calldata _fee,
    address _refundAddress
  ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
    (msgReceipt, oftReceipt,) = _send(_sendParam, _fee, _refundAddress);
    return (msgReceipt, oftReceipt);
  }

  /// @notice Stargate-native send returning the (taxi-empty) {Ticket}; the path the router uses.
  function sendToken(
    SendParam calldata _sendParam,
    MessagingFee calldata _fee,
    address _refundAddress
  ) external payable returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket) {
    return _send(_sendParam, _fee, _refundAddress);
  }

  function _send(
    SendParam calldata _sendParam,
    MessagingFee calldata _fee,
    address _refundAddress
  ) internal returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket) {
    if (msg.value < _fee.nativeFee) revert MockStargateInsufficientFee();
    s_lastTo = _sendParam.to;
    uint256 sent = _removeDust(_sendParam.amountLD);
    uint256 received = _afterLpFee(sent);
    if (received < _sendParam.minAmountLD) revert MockStargateSlippage();

    // ERC-20 pool: lock the SD-floored amount from the caller (sub-SD dust stays with the caller).
    IERC20(i_token).safeTransferFrom(msg.sender, address(this), sent);

    if (msg.value > _fee.nativeFee) {
      (bool ok,) = _refundAddress.call{value: msg.value - _fee.nativeFee}("");
      if (!ok) revert MockStargateRefundFailed();
    }

    bytes32 guid = keccak256(abi.encode(_sendParam.dstEid, _sendParam.to, sent, ++s_nonce));
    msgReceipt = MessagingReceipt({guid: guid, nonce: s_nonce, fee: _fee});
    oftReceipt = OFTReceipt({amountSentLD: sent, amountReceivedLD: received});
    ticket = Ticket({ticketId: 0, passenger: ""});
    emit OFTSent(guid, _sendParam.dstEid, msg.sender, sent, received);
    return (msgReceipt, oftReceipt, ticket);
  }

  function _afterLpFee(
    uint256 _amount
  ) internal view returns (uint256) {
    return _amount - (_amount * s_lpFeeBps) / 10_000;
  }

  function _removeDust(
    uint256 _amountLD
  ) internal view returns (uint256) {
    return _amountLD - (_amountLD % i_decimalConversionRate);
  }
}
