// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MessagingFee, MessagingReceipt } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { IOFT, OFTReceipt, SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @notice The Stargate "bus" ticket returned by {IStargate.sendToken}. It is only meaningful for the
///         batched "bus" mode; in the instant "taxi" mode this router uses (`SendParam.oftCmd == ""`)
///         it is empty and ignored. Declared here purely so the `sendToken` return ABI-decodes.
struct Ticket {
    uint72 ticketId;
    bytes passenger;
}

/// @notice Whether a Stargate endpoint is a pooled-liquidity contract (`Pool`) or a hydra mint/burn
///         OFT (`OFT`). Both are `IOFT`-shaped and both deliver canonical, native token out.
enum StargateType {
    Pool,
    OFT
}

/**
 * @title IStargate
 * @notice Minimal Stargate V2 interface. Stargate pools/OFTs ARE LayerZero OFTs — `IStargate is IOFT`
 *         — so they expose the full `IOFT` surface (`token`, `approvalRequired`, `quoteSend`, `send`,
 *         …) and additionally the Stargate-native `sendToken` (which returns the bus `Ticket`) and
 *         `stargateType`. This router sends in instant "taxi" mode (empty `oftCmd`); the returned
 *         `Ticket` is ignored.
 * @dev Only the members the router uses are declared. See
 *      https://stargateprotocol.gitbook.io/stargate/v2-developer-docs.
 */
interface IStargate is IOFT {
    /// @notice Stargate's native send. In taxi mode (`sendParam.oftCmd == ""`) it bridges `amountLD`
    ///         immediately, charging the pool/LP fee so the destination receives `amountReceivedLD`
    ///         (which `sendParam.minAmountLD` floors). Behaves like `IOFT.send` but also returns the
    ///         (here-ignored) bus `Ticket`.
    /// @param sendParam    The OFT send parameters (dstEid, to, amountLD, minAmountLD, options, …).
    /// @param fee          The messaging fee (quote via {IOFT.quoteSend}); `nativeFee` paid as value.
    /// @param refundAddress Recipient of any excess native fee.
    /// @return msgReceipt  LayerZero messaging receipt (carries the `guid`).
    /// @return oftReceipt  Amounts sent/received in local decimals.
    /// @return ticket      Bus ticket; empty in taxi mode (ignored by this router).
    function sendToken(
        SendParam calldata sendParam,
        MessagingFee calldata fee,
        address refundAddress
    )
        external
        payable
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt, Ticket memory ticket);

    /// @notice Whether this endpoint is a pooled-liquidity Stargate (`Pool`) or a hydra OFT (`OFT`).
    /// @return t The Stargate endpoint type.
    function stargateType() external view returns (StargateType);
}
