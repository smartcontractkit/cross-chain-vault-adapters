import { encodeAbiParameters, decodeAbiParameters, pad, getAddress, toHex, type Address, type Hex } from "viem";
import { PublicKey } from "@solana/web3.js";

/**
 * Mirrors `CrossChainVaultAdapter.VaultMessage` — the compact, channel-agnostic application message
 * carried in the inbound `data` over ANY rail (CCIP `message.data`, or the LayerZero OFT / Stargate
 * compose payload). Encoded exactly as the contract's `abi.decode(inbound.data, (VaultMessage))`
 * expects: a single static tuple, field order matching the Solidity declaration.
 *
 *   struct VaultMessage {
 *     uint256 minAmountOut;        // slippage floor on the vault output (shares on deposit, assets on redeem)
 *     uint64  destination;         // RETURN-leg route key (0 = LOCAL, <= uint32.max = LZ EID, else CCIP selector)
 *     bytes32 recipient;           // beneficiary of the produced token (EVM low-20 or SVM 32-byte pubkey)
 *     address failedMessageHandler;// hub-side delegate for retry/refundLocal; 0x0 => refundToSource-only
 *     bool    onlyLocalRefund;     // true => permissionless refundToSource is disabled (handler must recover)
 *   }
 *
 * `destination` selects the RETURN rail/chain (resolved on-chain via the RouteRegistry); it is NOT the
 * inbound rail the token arrives on (that is the send function the user picks). Kept small for
 * size-constrained origins (e.g. Solana).
 */
export interface VaultMessageInput {
  minAmountOut: bigint;
  /** Return-leg route key. */
  destination: bigint;
  /** Beneficiary of the produced token — EVM address or Solana pubkey (see `recipientKind`). */
  recipient: string;
  recipientKind: "evm" | "svm";
  /** Hub-side handler allowed to retry / refund-local on failure. 0x0 => bounce-to-source only. */
  failedMessageHandler: Address;
  /**
   * Opt out of the permissionless bounce-to-source on failure (`refundToSource` then reverts with
   * `LocalRefundOnly`); recovery is left to the handler. Only takes effect when `failedMessageHandler`
   * is non-zero: a handler-less message always stays permissionlessly refundable.
   */
  onlyLocalRefund: boolean;
}

/** Encode a beneficiary into the 32-byte `recipient` word (EVM right-aligned, or SVM raw pubkey). */
export function encodeRecipient(recipient: string, kind: "evm" | "svm"): Hex {
  if (kind === "svm") {
    return toHex(new PublicKey(recipient).toBytes());
  }
  // EVM: right-align the 20-byte address into a 32-byte word (upper 96 bits zero).
  return pad(getAddress(recipient), { size: 32 });
}

const VAULT_MESSAGE_COMPONENTS = [
  { name: "minAmountOut", type: "uint256" },
  { name: "destination", type: "uint64" },
  { name: "recipient", type: "bytes32" },
  { name: "failedMessageHandler", type: "address" },
  { name: "onlyLocalRefund", type: "bool" },
] as const;

/** ABI-encode a `VaultMessage` (single static tuple) for the inbound `data` payload. */
export function encodeVaultMessage(m: VaultMessageInput): Hex {
  return encodeAbiParameters(
    [{ type: "tuple", components: VAULT_MESSAGE_COMPONENTS }],
    [
      {
        minAmountOut: m.minAmountOut,
        destination: m.destination,
        recipient: encodeRecipient(m.recipient, m.recipientKind),
        failedMessageHandler: getAddress(m.failedMessageHandler),
        onlyLocalRefund: m.onlyLocalRefund,
      },
    ],
  );
}

/** Decode a `VaultMessage` back from inbound `data` (e.g. a captured failed message's `Inbound.data`). */
export function decodeVaultMessage(data: Hex): {
  minAmountOut: bigint;
  destination: bigint;
  recipient: Hex;
  failedMessageHandler: Address;
  onlyLocalRefund: boolean;
} | null {
  try {
    const [tuple] = decodeAbiParameters(
      [{ type: "tuple", components: VAULT_MESSAGE_COMPONENTS }],
      data,
    ) as unknown as [
      {
        minAmountOut: bigint;
        destination: bigint;
        recipient: Hex;
        failedMessageHandler: Address;
        onlyLocalRefund: boolean;
      },
    ];
    return tuple;
  } catch {
    return null;
  }
}
