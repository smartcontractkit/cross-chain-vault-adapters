// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRefundCaller {
  function refundFailedMessage(
    bytes32 messageId
  ) external payable;
}

contract RejectEtherReceiver {
  error EtherRejected();

  receive() external payable {
    revert EtherRejected();
  }

  function callRefundFailedMessage(
    address receiver,
    bytes32 messageId
  ) external payable {
    IRefundCaller(receiver).refundFailedMessage{value: msg.value}(messageId);
  }
}
