import { encodePacked, encodeAbiParameters, parseAbiParameters, isAddress, pad, toHex, hexToBytes, isHex, type Hex } from "viem";
import { PublicKey } from "@solana/web3.js";
import { zeroPadValue } from "ethers";

export const EVM_EXTRA_ARGS_V1_TAG = "0x97a657c9" as const;
export const EVM_EXTRA_ARGS_V2_TAG = "0x181dcf10" as const;

export interface TokenAmount {
  token: `0x${string}`;
  amount: string;
}

export interface CCIPMessage {
  receiver: `0x${string}`;
  data: `0x${string}`;
  tokenAmounts: TokenAmount[];
  feeToken: `0x${string}`;
  extraArgs: `0x${string}`;
}

export function isValidAddress(value: string): value is `0x${string}` {
  return isAddress(value);
}

export function isValidHex(value: string): boolean {
  if (!value || value === "0x") return true;
  return isHex(value);
}

export function addressToBytes(address: string): `0x${string}` {
  if (!isAddress(address)) {
    throw new Error("Invalid address");
  }
  return encodeAbiParameters(
    parseAbiParameters("address"),
    [address as `0x${string}`]
  );
}

export function bytesToAddress(bytes: string): `0x${string}` | null {
  try {
    if (!isHex(bytes)) return null;
    const cleanBytes = bytes.toLowerCase();
    if (cleanBytes.length === 66) {
      const addressPart = "0x" + cleanBytes.slice(26);
      if (isAddress(addressPart)) {
        return addressPart as `0x${string}`;
      }
    }
    if (cleanBytes.length === 42 && isAddress(cleanBytes)) {
      return cleanBytes as `0x${string}`;
    }
    return null;
  } catch {
    return null;
  }
}

export function stringToHex(str: string): `0x${string}` {
  if (!str) return "0x";
  return toHex(str);
}

export function hexToString(hex: string): string {
  try {
    if (!hex || hex === "0x") return "";
    if (!isHex(hex)) return "";
    const bytes = hexToBytes(hex as Hex);
    return new TextDecoder().decode(bytes);
  } catch {
    return "";
  }
}

export function encodeExtraArgsV1(gasLimit: bigint): `0x${string}` {
  const encoded = encodeAbiParameters(
    parseAbiParameters("uint256"),
    [gasLimit]
  );
  return (EVM_EXTRA_ARGS_V1_TAG + encoded.slice(2)) as `0x${string}`;
}

export function encodeExtraArgsV2(gasLimit: bigint, allowOutOfOrder: boolean): `0x${string}` {
  const encoded = encodeAbiParameters(
    parseAbiParameters("uint256, bool"),
    [gasLimit, allowOutOfOrder]
  );
  return (EVM_EXTRA_ARGS_V2_TAG + encoded.slice(2)) as `0x${string}`;
}

export function decodeExtraArgs(hex: string): { version: "v1" | "v2" | "unknown"; gasLimit?: bigint; allowOutOfOrder?: boolean } {
  try {
    if (!hex || hex.length < 10) return { version: "unknown" };
    
    const tag = hex.slice(0, 10).toLowerCase();
    
    if (tag === EVM_EXTRA_ARGS_V1_TAG.toLowerCase()) {
      return { version: "v1" };
    }
    
    if (tag === EVM_EXTRA_ARGS_V2_TAG.toLowerCase()) {
      return { version: "v2" };
    }
    
    return { version: "unknown" };
  } catch {
    return { version: "unknown" };
  }
}

export function getByteLength(hex: string): number {
  if (!hex || hex === "0x") return 0;
  if (!isHex(hex)) return 0;
  return (hex.length - 2) / 2;
}

export function formatByteLength(bytes: number): string {
  if (bytes === 0) return "0 bytes";
  if (bytes === 1) return "1 byte";
  return `${bytes} bytes`;
}

export function isZeroPaddedAddress(hex: string): boolean {
  if (!isHex(hex) || hex.length !== 66) return false;
  const leadingBytes = hex.slice(2, 26).toLowerCase();
  if (leadingBytes !== "000000000000000000000000") return false;
  const addressPart = ("0x" + hex.slice(26).toLowerCase()) as `0x${string}`;
  return isAddress(addressPart, { strict: false });
}

export function extractAddressFromBytes(hex: string): `0x${string}` | null {
  if (!isHex(hex)) return null;
  const normalized = hex.toLowerCase();
  if (normalized.length === 42 && isAddress(normalized, { strict: false })) {
    return normalized as `0x${string}`;
  }
  if (normalized.length === 66 && isZeroPaddedAddress(normalized)) {
    return ("0x" + normalized.slice(26)) as `0x${string}`;
  }
  return null;
}

export function validateReceiver(value: string, mode: "address" | "bytes" = "address"): { valid: boolean; message: string; isAddress: boolean; extractedAddress?: string } {
  if (!value || value === "0x") {
    return { valid: false, message: "Receiver is required", isAddress: false };
  }
  
  if (mode === "address") {
    if (isAddress(value)) {
      return { valid: true, message: "Valid address (will be ABI-encoded)", isAddress: true };
    }
    return { valid: false, message: "Enter a valid address", isAddress: false };
  }
  
  if (!isHex(value)) {
    return { valid: false, message: "Must be valid hex (0x...)", isAddress: false };
  }
  
  const byteLen = getByteLength(value);
  if (byteLen === 20 && isAddress(value)) {
    return { valid: true, message: "Valid 20-byte address", isAddress: true, extractedAddress: value };
  }
  
  if (byteLen === 32) {
    if (isZeroPaddedAddress(value)) {
      const addr = extractAddressFromBytes(value);
      return { 
        valid: true, 
        message: "Valid zero-padded address", 
        isAddress: false, 
        extractedAddress: addr || undefined 
      };
    }
    return { 
      valid: false, 
      message: "First 12 bytes must be zero (ABI-encoded address)", 
      isAddress: false 
    };
  }
  
  return { valid: false, message: `Expected 20 or 32 bytes, got ${byteLen}`, isAddress: false };
}

export function validateData(value: string): { valid: boolean; message: string } {
  if (!value || value === "0x") {
    return { valid: true, message: "Empty data (0 bytes)" };
  }
  
  if (!isHex(value)) {
    return { valid: false, message: "Must be valid hex (0x...)" };
  }
  
  const byteLen = getByteLength(value);
  return { valid: true, message: formatByteLength(byteLen) };
}

export function validateTokenAmount(token: string, amount: string): { valid: boolean; message: string } {
  if (!token && !amount) {
    return { valid: true, message: "" };
  }
  
  if (!isAddress(token)) {
    return { valid: false, message: "Invalid token address" };
  }
  
  try {
    const amountBigInt = BigInt(amount);
    if (amountBigInt < BigInt(0)) {
      return { valid: false, message: "Amount must be positive" };
    }
    return { valid: true, message: "" };
  } catch {
    return { valid: false, message: "Invalid amount" };
  }
}

export function prepareReceiverBytes(value: string): `0x${string}` {
  if (isAddress(value)) {
    return addressToBytes(value);
  }
  if (isHex(value)) {
    return value as `0x${string}`;
  }
  return "0x";
}

export function encodeTokenAmounts(tokenAmounts: TokenAmount[]): Array<{ token: `0x${string}`; amount: bigint }> {
  return tokenAmounts
    .filter(ta => ta.token && ta.amount)
    .map(ta => ({
      token: ta.token,
      amount: BigInt(ta.amount),
    }));
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as const;

export interface StructField {
  type: string;
  name: string;
}

export interface ParsedStruct {
  name: string;
  fields: StructField[];
  warnings?: string[];
}

const SOLIDITY_TYPES = [
  "address", "bool", "string", "bytes",
  "bytes1", "bytes2", "bytes3", "bytes4", "bytes5", "bytes6", "bytes7", "bytes8",
  "bytes9", "bytes10", "bytes11", "bytes12", "bytes13", "bytes14", "bytes15", "bytes16",
  "bytes17", "bytes18", "bytes19", "bytes20", "bytes21", "bytes22", "bytes23", "bytes24",
  "bytes25", "bytes26", "bytes27", "bytes28", "bytes29", "bytes30", "bytes31", "bytes32",
  "uint8", "uint16", "uint24", "uint32", "uint40", "uint48", "uint56", "uint64",
  "uint72", "uint80", "uint88", "uint96", "uint104", "uint112", "uint120", "uint128",
  "uint136", "uint144", "uint152", "uint160", "uint168", "uint176", "uint184", "uint192",
  "uint200", "uint208", "uint216", "uint224", "uint232", "uint240", "uint248", "uint256",
  "int8", "int16", "int24", "int32", "int40", "int48", "int56", "int64",
  "int72", "int80", "int88", "int96", "int104", "int112", "int120", "int128",
  "int136", "int144", "int152", "int160", "int168", "int176", "int184", "int192",
  "int200", "int208", "int216", "int224", "int232", "int240", "int248", "int256",
];

export type ParseResult = {
  success: true;
  struct: ParsedStruct;
} | {
  success: false;
  error: string;
};

export function parseStructDefinition(input: string): ParseResult {
  const cleaned = input.replace(/\/\/.*$/gm, "").replace(/\/\*[\s\S]*?\*\//g, "").trim();
  
  const structMatch = cleaned.match(/struct\s+(\w+)\s*\{([^}]*)\}/);
  if (!structMatch) {
    return { success: false, error: "Could not find valid struct definition" };
  }
  
  const structName = structMatch[1];
  const body = structMatch[2];
  
  const fields: StructField[] = [];
  const unsupportedFields: string[] = [];
  const lines = body.split(";").filter(line => line.trim());
  
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    
    const parts = trimmed.split(/\s+/).filter(p => p);
    if (parts.length < 2) continue;
    
    let type = parts[0];
    let name = parts[parts.length - 1];
    name = name.replace(/[^a-zA-Z0-9_]/g, "");
    
    if (type.includes("[]") || type.includes("[")) {
      unsupportedFields.push(`${type} ${name} (arrays not supported)`);
      continue;
    }
    
    if (!SOLIDITY_TYPES.includes(type)) {
      unsupportedFields.push(`${type} ${name} (custom/nested types not supported)`);
      continue;
    }
    
    if (name) {
      fields.push({ type, name });
    }
  }
  
  if (unsupportedFields.length > 0 && fields.length === 0) {
    return { success: false, error: `Unsupported fields: ${unsupportedFields.join(", ")}` };
  }
  
  if (fields.length === 0) {
    return { success: false, error: "No valid fields found in struct" };
  }
  
  return { 
    success: true, 
    struct: { 
      name: structName, 
      fields,
      warnings: unsupportedFields.length > 0 ? unsupportedFields : undefined
    } 
  };
}

export function getInputPlaceholder(type: string): string {
  if (type === "address") return "0x...";
  if (type === "bytes32") return "0x..., EVM address, or Solana address";
  if (type === "bytes20") return "0x... or address";
  if (type.startsWith("bytes")) {
    const byteLen = parseInt(type.replace("bytes", ""), 10);
    if (!isNaN(byteLen) && byteLen >= 20) return "0x... or address";
    return "0x...";
  }
  if (type === "bool") return "true or false";
  if (type === "string") return "Text string";
  if (type.startsWith("uint") || type.startsWith("int")) return "0";
  return "";
}

export function isSolanaAddress(value: string): boolean {
  try {
    // Solana addresses are base58 encoded and typically 32-44 characters
    if (value.length < 32 || value.length > 44) return false;
    // Try to create a PublicKey - if it succeeds, it's a valid Solana address
    new PublicKey(value);
    return true;
  } catch {
    return false;
  }
}

export function solanaAddressToBytes32(solanaAddress: string): `0x${string}` | null {
  try {
    const pubkey = new PublicKey(solanaAddress);
    const hex = "0x" + pubkey.toBuffer().toString("hex");
    return zeroPadValue(hex, 32) as `0x${string}`;
  } catch {
    return null;
  }
}

export function convertAddressToBytes(address: string, targetType: string): `0x${string}` | null {
  // First check if it's a Solana address (for bytes32 fields)
  if (targetType === "bytes32" && isSolanaAddress(address)) {
    return solanaAddressToBytes32(address);
  }
  
  // Then check if it's an EVM address
  if (!isAddress(address)) return null;
  
  if (targetType === "bytes" || targetType === "bytes20") {
    return address.toLowerCase() as `0x${string}`;
  }
  
  if (targetType.startsWith("bytes")) {
    const targetLen = parseInt(targetType.replace("bytes", ""), 10);
    if (isNaN(targetLen) || targetLen < 20) return null;
    
    const addressWithoutPrefix = address.toLowerCase().slice(2);
    const paddingNeeded = (targetLen - 20) * 2;
    const padded = "0".repeat(paddingNeeded) + addressWithoutPrefix;
    return `0x${padded}` as `0x${string}`;
  }
  
  return null;
}

export function getInputType(solidityType: string): "address" | "bytes" | "bool" | "number" | "string" {
  if (solidityType === "address") return "address";
  if (solidityType.startsWith("bytes")) return "bytes";
  if (solidityType === "bool") return "bool";
  if (solidityType.startsWith("uint") || solidityType.startsWith("int")) return "number";
  return "string";
}

export function validateFieldValue(type: string, value: string): { valid: boolean; message: string; convertedValue?: string } {
  if (!value) return { valid: false, message: "Required" };
  
  if (type === "address") {
    return isAddress(value) 
      ? { valid: true, message: "" }
      : { valid: false, message: "Invalid address" };
  }
  
  if (type.startsWith("bytes")) {
    const expectedBytes = type === "bytes" ? null : parseInt(type.replace("bytes", ""), 10);
    
    // Check for Solana address conversion (for bytes32 fields)
    if (type === "bytes32" && isSolanaAddress(value)) {
      const converted = solanaAddressToBytes32(value);
      if (converted) {
        return { valid: true, message: "Solana address converted to bytes32", convertedValue: converted };
      }
    }
    
    // Check for EVM address conversion
    if (isAddress(value) && expectedBytes && expectedBytes >= 20) {
      const converted = convertAddressToBytes(value, type);
      if (converted) {
        return { valid: true, message: "EVM address converted", convertedValue: converted };
      }
    }
    
    if (!isHex(value)) {
      // If it's bytes32 and not hex, check if it might be a Solana address
      if (type === "bytes32" && isSolanaAddress(value)) {
        const converted = solanaAddressToBytes32(value);
        if (converted) {
          return { valid: true, message: "Solana address converted to bytes32", convertedValue: converted };
        }
      }
      return { valid: false, message: "Must be hex (0x...), EVM address, or Solana address" };
    }
    if (expectedBytes) {
      const actualBytes = getByteLength(value);
      if (actualBytes !== expectedBytes) {
        return { valid: false, message: `Expected ${expectedBytes} bytes, got ${actualBytes}` };
      }
    }
    return { valid: true, message: "" };
  }
  
  if (type === "bool") {
    const lower = value.toLowerCase();
    return (lower === "true" || lower === "false")
      ? { valid: true, message: "" }
      : { valid: false, message: "Must be true or false" };
  }
  
  if (type.startsWith("uint") || type.startsWith("int")) {
    try {
      BigInt(value);
      return { valid: true, message: "" };
    } catch {
      return { valid: false, message: "Invalid number" };
    }
  }
  
  return { valid: true, message: "" };
}

export type EncodeResult = {
  success: true;
  data: `0x${string}`;
} | {
  success: false;
  error: string;
};

export function encodeStructData(fields: StructField[], values: Record<string, string>): EncodeResult {
  try {
    const types = fields.map(f => f.type).join(", ");
    const abiParams = parseAbiParameters(types);
    
    const encodedValues = fields.map(field => {
      const value = values[field.name] || "";
      const type = field.type;
      
      if (type === "address") {
        return value as `0x${string}`;
      }
      if (type.startsWith("bytes")) {
        const validation = validateFieldValue(type, value);
        if (validation.convertedValue) {
          return validation.convertedValue as `0x${string}`;
        }
        return value as `0x${string}`;
      }
      if (type === "bool") {
        return value.toLowerCase() === "true";
      }
      if (type.startsWith("uint") || type.startsWith("int")) {
        return BigInt(value);
      }
      if (type === "string") {
        return value;
      }
      return value;
    });
    
    const encoded = encodeAbiParameters(abiParams, encodedValues);
    return { success: true, data: encoded };
  } catch (error: any) {
    console.error("Encoding error:", error);
    return { success: false, error: error.message || "Failed to encode struct data" };
  }
}
