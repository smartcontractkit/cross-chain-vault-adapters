import { encodeAbiParameters, pad, type Address, type Hex } from 'viem'
import { type VaultMessageCfg } from './config.js'

/**
 * ABI-encodes a `CrossChainVaultAdapter.VaultMessage` exactly as the contract's
 * `abi.decode(inbound.data, (VaultMessage))` expects — a single static tuple, field order matching the
 * Solidity declaration:
 *   (uint256 minAmountOut, uint64 destination, bytes32 recipient, address failedMessageHandler,
 *    bool onlyLocalRefund)
 *
 * `destination` packs the outbound rail + chain into one field (LayerZero EID if <= uint32.max, else a
 * CCIP selector). The outbound rail/destination is the user's choice (within the operator's allowlist);
 * the destination gas is operator config, not in the message. Kept small for size-constrained origins.
 */
export function encodeVaultMessage(m: VaultMessageCfg): Hex {
  const recipient32 = pad(m.recipient as Address, { size: 32 })

  return encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'minAmountOut', type: 'uint256' },
          { name: 'destination', type: 'uint64' },
          { name: 'recipient', type: 'bytes32' },
          { name: 'failedMessageHandler', type: 'address' },
          { name: 'onlyLocalRefund', type: 'bool' },
        ],
      },
    ],
    [
      {
        minAmountOut: BigInt(m.minAmountOut),
        destination: BigInt(m.destination),
        recipient: recipient32,
        failedMessageHandler: m.failedMessageHandler as Address,
        onlyLocalRefund: m.onlyLocalRefund ?? false,
      },
    ],
  )
}
