// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCcipRouter
 * @notice Test-only CCIP router: quotes a fixed fee, pulls the fee + token transfers on
 *         {ccipSend}, and can simulate rate-limit/pause reverts. Also exposes {deliverToReceiver}
 *         to drive inbound `ccipReceive` deliveries. NOT for production.
 */
contract MockCcipRouter is IRouterClient {
  using SafeERC20 for IERC20;

  uint256 public s_fee;
  bool public s_sendReverts;
  uint256 private s_nonce;
  /// @notice The `extraArgs` of the most recent {ccipSend} (lets tests assert the encoding/tag).
  bytes public s_lastExtraArgs;
  /// @notice The `receiver` of the most recent {ccipSend} (lets tests assert the encoding).
  bytes public s_lastReceiver;

  event Sent(bytes32 messageId, uint64 destChainSelector, address feeToken, uint256 fee);

  error MockCcipRouterInvalidSvmReceiver();
  error MockCcipRouterRateLimited();
  error MockCcipRouterInsufficientNativeFee();

  function setFee(
    uint256 _fee
  ) external {
    s_fee = _fee;
  }

  function setSendReverts(
    bool _reverts
  ) external {
    s_sendReverts = _reverts;
  }

  function isChainSupported(
    uint64
  ) external pure returns (bool) {
    return true;
  }

  function getFee(
    uint64,
    Client.EVM2AnyMessage memory _message
  ) external view returns (uint256) {
    _validateSvmReceiver(_message);
    return s_fee;
  }

  /// @dev Mirrors the FeeQuoter's `Internal._validate32ByteAddress` gate for SVM-family messages: the
  ///      encoded receiver must be EXACTLY 32 bytes (a token-only transfer uses the 32-byte zero word;
  ///      empty bytes revert). Real lanes fail in `getFee`, so the mock enforces it there too.
  function _validateSvmReceiver(
    Client.EVM2AnyMessage memory _message
  ) internal pure {
    if (_message.extraArgs.length >= 4 && bytes4(_message.extraArgs) == Client.SVM_EXTRA_ARGS_V1_TAG) {
      if (_message.receiver.length != 32) revert MockCcipRouterInvalidSvmReceiver();
    }
  }

  function ccipSend(
    uint64 _destChainSelector,
    Client.EVM2AnyMessage calldata _message
  ) external payable returns (bytes32 messageId) {
    if (s_sendReverts) revert MockCcipRouterRateLimited();
    _validateSvmReceiver(_message);
    s_lastExtraArgs = _message.extraArgs;
    s_lastReceiver = _message.receiver;

    if (_message.feeToken == address(0)) {
      if (msg.value < s_fee) revert MockCcipRouterInsufficientNativeFee();
    } else {
      IERC20(_message.feeToken).safeTransferFrom(msg.sender, address(this), s_fee);
    }

    uint256 len = _message.tokenAmounts.length;
    for (uint256 i; i < len; ++i) {
      IERC20(_message.tokenAmounts[i].token)
        .safeTransferFrom(msg.sender, address(this), _message.tokenAmounts[i].amount);
    }

    messageId = keccak256(abi.encode(_destChainSelector, _message.receiver, ++s_nonce));
    emit Sent(messageId, _destChainSelector, _message.feeToken, s_fee);
    return messageId;
  }

  /**
   * @notice Simulates an inbound CCIP delivery: transfers the message's tokens (which this mock
   *         must already hold) to `_receiver`, then calls `ccipReceive` as the router.
   * @param _receiver The CCIP-receiving contract.
   * @param _message  The inbound message.
   */
  function deliverToReceiver(
    address _receiver,
    Client.Any2EVMMessage calldata _message
  ) external {
    uint256 len = _message.destTokenAmounts.length;
    for (uint256 i; i < len; ++i) {
      IERC20(_message.destTokenAmounts[i].token).safeTransfer(_receiver, _message.destTokenAmounts[i].amount);
    }
    IAny2EVMMessageReceiver(_receiver).ccipReceive(_message);
  }
}
