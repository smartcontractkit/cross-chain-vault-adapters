/**
 * Seed registry of known `CrossChainVaultAdapter` deployments plus the per-source-chain, per-rail
 * endpoints and return-leg destinations needed to originate a send.
 *
 * The dashboard works with ANY pasted adapter address (everything is discoverable on-chain), but the
 * SEND form needs off-chain hints that are NOT readable from the hub adapter:
 *
 *  - **CCIP**: the CCIP-bridged token on the SOURCE chain (the asset for a deposit, the vault share for
 *    a redeem). Auto-discoverable via the CCIP Cross-Chain-Token pool graph, but a hint avoids the
 *    lookup and covers tokens that aren't in the registry.
 *  - **OFT**: the LayerZero OFT adapter on the SOURCE chain that bridges the vault asset.
 *  - **Stargate**: the Stargate pool on the SOURCE chain for the vault asset.
 *
 * A source chain can appear under multiple rails (e.g. Arbitrum Sepolia offers both a CCIP share lane
 * and a Stargate USDT lane). Endpoints are keyed by source EVM chain id; the CCIP selector / LayerZero
 * EID for that chain come from `ccip.config.ts` / `lz.config.ts`.
 *
 * Without an entry, the dashboard still loads any adapter; the send form then offers the CCIP rail from
 * the adapter's CCIP inbound allowlist and derives return destinations from its on-chain routes.
 */

export type Rail = "ccip" | "oft" | "stargate";

/** Per-source-chain rail endpoints for one adapter. */
export interface SourceRailHints {
  /** Human label for the source chain (falls back to ccip.config name). */
  label?: string;
  /** CCIP-bridged tokens on this source chain (asset = deposit input, share = redeem input). */
  ccip?: { assetToken?: `0x${string}`; shareToken?: `0x${string}` };
  /** LayerZero OFT adapter on this source chain that bridges the vault asset (deposit). */
  oft?: { endpoint: `0x${string}`; token?: `0x${string}` };
  /** Stargate pool on this source chain for the vault asset (deposit). */
  stargate?: { pool: `0x${string}`; token?: `0x${string}` };
}

/** A return-leg destination the operator has wired (the `destination` route key in the VaultMessage). */
export interface ReturnDestination {
  /** Route key carried in the message (uint64 as string): 0 = LOCAL, <=u32max = LZ EID, else CCIP selector. */
  destination: string;
  label: string;
  /** How the hub delivers the produced token onward (matches the on-chain RouteRegistry rail). */
  rail: "CCIP" | "LZ_OFT" | "STARGATE" | "CCIP_SVM" | "LOCAL";
  /** Recipient encoding required for this destination. */
  recipientKind: "evm" | "svm";
}

export interface VaultAdapterEntry {
  adapterAddress: `0x${string}`;
  hubChainId: number;
  /** Hub LayerZero EID (dstEid for OFT/Stargate sends toward this adapter). */
  hubLzEid: number;
  /** Hub CCIP chain selector (destChainSelector for CCIP sends toward this adapter). */
  hubCcipSelector: string;
  label?: string;
  /** The served ERC-4626 vault (share token == vault address) + underlying asset, for display hints. */
  vault?: `0x${string}`;
  asset?: `0x${string}`;
  /** Hub-local Stargate pool (`lzCompose._from`) for inbound allowlist checks on remote spokes. */
  hubStargatePool?: `0x${string}`;
  /** Per source EVM chain id → rail endpoints available from that chain. */
  sources?: Record<string, SourceRailHints>;
  /** Return-leg destinations the operator configured (drives the return-destination picker). */
  returnDestinations?: ReturnDestination[];
}

/**
 * Add your own deployments here. Example shape (addresses are placeholders):
 *
 *   {
 *     adapterAddress: "0x...",            // CrossChainVaultAdapter on the hub
 *     hubChainId: 11155111,               // Ethereum Sepolia
 *     hubLzEid: 40161,
 *     hubCcipSelector: "16015286601757825753",
 *     label: "Sepolia USDT vault",
 *     vault: "0x...",
 *     asset: "0x...",
 *     hubStargatePool: "0x...",           // only if a Stargate lane is wired
 *     sources: {
 *       "421614": {                        // Arbitrum Sepolia
 *         ccip: { shareToken: "0x..." },   // CCIP-bridged vault share on the source (redeem)
 *         stargate: { pool: "0x...", token: "0x..." },
 *       },
 *       "43113": { ccip: { assetToken: "0x..." } },
 *     },
 *     returnDestinations: [                // optional; defaults to the adapter's on-chain routes
 *       { destination: "3478487238524512106", label: "Arbitrum Sepolia (CCIP)", rail: "CCIP", recipientKind: "evm" },
 *       { destination: "0", label: "Local (hub chain)", rail: "LOCAL", recipientKind: "evm" },
 *     ],
 *   }
 *
 * `config/multibridge/sepolia.json` at the repo root lists the addresses used by the E2E harness.
 */
export const KNOWN_ADAPTERS: VaultAdapterEntry[] = [];

export function findKnownAdapter(address: string, hubChainId: number): VaultAdapterEntry | undefined {
  return KNOWN_ADAPTERS.find(
    (a) => a.adapterAddress.toLowerCase() === address.toLowerCase() && a.hubChainId === hubChainId,
  );
}

/** Rail hints for a given source EVM chain id on an adapter. */
export function sourceHintsFor(
  entry: VaultAdapterEntry | undefined,
  sourceChainId: number,
): SourceRailHints | undefined {
  return entry?.sources?.[String(sourceChainId)];
}

/** Which rails an adapter exposes from a given source chain (by which endpoints are configured). */
export function railsForSource(hints: SourceRailHints | undefined): Rail[] {
  if (!hints) return [];
  const rails: Rail[] = [];
  if (hints.ccip) rails.push("ccip");
  if (hints.oft) rails.push("oft");
  if (hints.stargate) rails.push("stargate");
  return rails;
}
