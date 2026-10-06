/**
 * LayerZero V2 endpoint-id (EID) registry.
 *
 * The multibridge adapter's LayerZero OFT and Stargate rails address destination chains by
 * LayerZero EID, not by chain id or CCIP selector. This is the read-side counterpart to
 * `ccip.config.ts` (which carries CCIP selectors + routers): a small map from EVM chain id to its
 * LayerZero EID + EndpointV2 address, so the send layer can resolve `sendParam.dstEid` (the hub) and
 * label return-leg destinations that are LayerZero EIDs.
 *
 * Values are the canonical LayerZero V2 testnet endpoints (all testnets share the same EndpointV2
 * address `0x6EDCE6...f10f`). Extend for additional chains / mainnet as needed.
 */
export interface LzChain {
  chainId: number;
  /** LayerZero V2 endpoint id. */
  eid: number;
  /** LayerZero EndpointV2 address on this chain. */
  endpoint: `0x${string}`;
  label: string;
  isTestnet: boolean;
}

/** Shared LayerZero V2 EndpointV2 address across all supported testnets. */
const V2_TESTNET_ENDPOINT = "0x6EDCE65403992e310A62460808c4b910D972f10f" as const;

export const LZ_CHAINS: LzChain[] = [
  { chainId: 11155111, eid: 40161, endpoint: V2_TESTNET_ENDPOINT, label: "Ethereum Sepolia", isTestnet: true },
  { chainId: 421614, eid: 40231, endpoint: V2_TESTNET_ENDPOINT, label: "Arbitrum Sepolia", isTestnet: true },
  { chainId: 97, eid: 40102, endpoint: V2_TESTNET_ENDPOINT, label: "BSC Testnet", isTestnet: true },
  { chainId: 43113, eid: 40106, endpoint: V2_TESTNET_ENDPOINT, label: "Avalanche Fuji", isTestnet: true },
  { chainId: 84532, eid: 40245, endpoint: V2_TESTNET_ENDPOINT, label: "Base Sepolia", isTestnet: true },
  { chainId: 11155420, eid: 40232, endpoint: V2_TESTNET_ENDPOINT, label: "OP Sepolia", isTestnet: true },
];

export function lzChainByChainId(chainId: number): LzChain | undefined {
  return LZ_CHAINS.find((c) => c.chainId === chainId);
}

export function lzChainByEid(eid: number): LzChain | undefined {
  return LZ_CHAINS.find((c) => c.eid === eid);
}

export function lzEidForChain(chainId: number): number | undefined {
  return lzChainByChainId(chainId)?.eid;
}

export function chainIdForLzEid(eid: number): number | undefined {
  return lzChainByEid(eid)?.chainId;
}

/** A LayerZero EID fits in uint32; a CCIP selector does not — used to disambiguate a `destination` key. */
export function isLzEid(destination: bigint): boolean {
  return destination > 0n && destination <= 0xffffffffn;
}
