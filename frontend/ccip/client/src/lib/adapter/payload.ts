import { encodeAbiParameters, parseAbiParameters, getAddress, pad, isAddress, toHex, type Hex } from "viem";
import { PublicKey } from "@solana/web3.js";

/**
 * Mirrors the on-chain `Payload` struct encoding for CrossChainERC4626Adapter.
 *
 *   struct Payload {
 *     address target;            // allowlisted vault
 *     bytes32 beneficiary;       // output recipient (EVM right-padded, or SVM 32-byte pubkey)
 *     uint256 minimumOut;        // floor on output AFTER fee skim
 *     uint256 deliveryAndRefund; // bit 0 = returnToSourceChain; bits 1..160 = localRefundAddress
 *   }
 *
 * `abi.encode` of four 32-byte words → exactly 128 bytes (CCIP_MESSAGE_PAYLOAD_LENGTH).
 */
export const CCIP_MESSAGE_PAYLOAD_LENGTH = 128;

export function packDeliveryAndRefund(
  returnToSourceChain: boolean,
  localRefundAddress?: string,
): bigint {
  const refund =
    localRefundAddress && isAddress(localRefundAddress)
      ? BigInt(getAddress(localRefundAddress))
      : 0n;
  if (refund >= 1n << 160n) throw new Error("localRefundAddress must fit in 160 bits");
  return (refund << 1n) | (returnToSourceChain ? 1n : 0n);
}

export function unpackDeliveryAndRefund(value: bigint): {
  returnToSourceChain: boolean;
  localRefundAddress: `0x${string}`;
} {
  const returnToSourceChain = (value & 1n) === 1n;
  const refundInt = (value >> 1n) & ((1n << 160n) - 1n);
  const localRefundAddress = getAddress(
    ("0x" + refundInt.toString(16).padStart(40, "0")) as `0x${string}`,
  );
  return { returnToSourceChain, localRefundAddress };
}

export type BeneficiaryType = "evm" | "svm";

export function encodeBeneficiary(beneficiary: string, type: BeneficiaryType = "evm"): Hex {
  if (type === "svm") {
    return toHex(new PublicKey(beneficiary).toBytes());
  }
  // EVM: right-align the 20-byte address into a 32-byte word (upper 96 bits MUST be zero)
  return pad(getAddress(beneficiary), { size: 32 });
}

export interface EncodePayloadOpts {
  target: string;
  beneficiary: string;
  beneficiaryType?: BeneficiaryType;
  minimumOut?: bigint;
  returnToSourceChain?: boolean;
  localRefundAddress?: string;
}

export function encodePayload(opts: EncodePayloadOpts): Hex {
  const encoded = encodeAbiParameters(parseAbiParameters("address, bytes32, uint256, uint256"), [
    getAddress(opts.target),
    encodeBeneficiary(opts.beneficiary, opts.beneficiaryType),
    opts.minimumOut ?? 1n,
    packDeliveryAndRefund(opts.returnToSourceChain ?? false, opts.localRefundAddress),
  ]);
  return encoded;
}

export function payloadByteLength(payload: Hex): number {
  return (payload.length - 2) / 2;
}
