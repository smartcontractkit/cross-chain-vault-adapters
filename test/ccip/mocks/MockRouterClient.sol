// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAny2EVMMessageReceiver} from "@chainlink/contracts-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts@4.8.3/token/ERC20/IERC20.sol";

contract MockRouterClient is IRouterClient {
  uint256 public fee = 0.01 ether;
  /// @dev Added to `getFee` return value as `feeIncrementPerSend * sendCount` so sequential `ccipSend` calls in one tx
  /// see rising quotes (fee-quote regression tests). `getFee` is `view` and cannot increment state; `sendCount`
  /// advances in `ccipSend`.
  uint256 public feeIncrementPerSend;
  uint256 public sendCount;
  uint256 private s_messageNonce;
  bool public revertOnSend;
  bool public revertOnGetFee;

  mapping(uint64 chainSelector => bool supported) public supportedChains;

  uint64 public lastDestinationChainSelector;
  bytes32 public lastMessageId;
  bytes public lastReceiverBytes;
  bytes public lastData;
  bytes public lastExtraArgs;
  address public lastFeeToken;
  uint256 public lastMsgValue;
  address public lastToken;
  uint256 public lastAmount;
  address public lastCaller;

  function setSupportedChain(
    uint64 chainSelector,
    bool supported
  ) external {
    supportedChains[chainSelector] = supported;
  }

  function setFee(
    uint256 fee_
  ) external {
    fee = fee_;
  }

  function setFeeIncrementPerSend(
    uint256 increment_
  ) external {
    feeIncrementPerSend = increment_;
  }

  /// @dev Test helper: next `getFee` / `ccipSend` sequence starts from base `fee` + `0` increment.
  function resetSendStateForTest() external {
    sendCount = 0;
    s_messageNonce = 0;
  }

  function setRevertOnSend(
    bool shouldRevert
  ) external {
    revertOnSend = shouldRevert;
  }

  function setRevertOnGetFee(
    bool shouldRevert
  ) external {
    revertOnGetFee = shouldRevert;
  }

  function isChainSupported(
    uint64 destChainSelector
  ) external view returns (bool supported) {
    return supportedChains[destChainSelector];
  }

  function getFee(
    uint64 destinationChainSelector,
    Client.EVM2AnyMessage memory
  ) external view returns (uint256) {
    if (!supportedChains[destinationChainSelector]) revert UnsupportedDestinationChain(destinationChainSelector);
    if (revertOnGetFee) revert InvalidMsgValue();
    return fee + feeIncrementPerSend * sendCount;
  }

  function ccipSend(
    uint64 destinationChainSelector,
    Client.EVM2AnyMessage calldata message
  ) external payable returns (bytes32) {
    if (!supportedChains[destinationChainSelector]) {
      revert UnsupportedDestinationChain(destinationChainSelector);
    }
    if (revertOnSend) revert InvalidMsgValue();
    uint256 requiredFee = fee + feeIncrementPerSend * sendCount;
    if (message.feeToken == address(0) && msg.value < requiredFee) revert InvalidMsgValue();
    if (message.feeToken != address(0) && msg.value != 0) revert InvalidMsgValue();

    for (uint256 i = 0; i < message.tokenAmounts.length; ++i) {
      IERC20(message.tokenAmounts[i].token).transferFrom(msg.sender, address(this), message.tokenAmounts[i].amount);
    }

    ++s_messageNonce;
    ++sendCount;

    lastDestinationChainSelector = destinationChainSelector;
    lastMessageId = keccak256(abi.encode(destinationChainSelector, msg.sender, s_messageNonce));
    lastReceiverBytes = message.receiver;
    lastData = message.data;
    lastExtraArgs = message.extraArgs;
    lastFeeToken = message.feeToken;
    lastMsgValue = msg.value;
    lastCaller = msg.sender;

    if (message.tokenAmounts.length > 0) {
      lastToken = message.tokenAmounts[0].token;
      lastAmount = message.tokenAmounts[0].amount;
    } else {
      lastToken = address(0);
      lastAmount = 0;
    }

    return lastMessageId;
  }

  function routeMessage(
    address receiver,
    Client.Any2EVMMessage memory message
  ) external {
    for (uint256 i = 0; i < message.destTokenAmounts.length; ++i) {
      IERC20(message.destTokenAmounts[i].token).transfer(receiver, message.destTokenAmounts[i].amount);
    }

    IAny2EVMMessageReceiver(receiver).ccipReceive(message);
  }
}
