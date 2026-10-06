/**
 * Optional seed registry of known CrossChainERC4626Adapter deployments and per-vault
 * display hints. The dashboard works with ANY pasted adapter address; this just provides
 * quick-pick presets and prefilled source-token hints. Everything is still discoverable
 * on-chain without an entry here.
 */

export interface VaultHint {
  vaultAddress: `0x${string}`;
  displayName?: string;
  /** Per-source-chain bridged token addresses used to prefill the send form. */
  sourceTokens?: Record<
    string /* source chain selector */,
    { assetToken?: `0x${string}`; shareToken?: `0x${string}` }
  >;
}

export interface AdapterEntry {
  adapterAddress: `0x${string}`;
  hubChainId: number; // EVM chain id where the adapter is deployed
  label?: string;
  vaultHints?: VaultHint[];
}

export const KNOWN_ADAPTERS: AdapterEntry[] = [
  {
    adapterAddress: "0x7F1f21a2CedD1f1771731330e49b92B484E5C775",
    hubChainId: 11155111, // Ethereum Sepolia
    label: "Sepolia demo adapter",
    vaultHints: [
      {
        vaultAddress: "0x525a9B5D84EB3C388263fE08667DB0251848FF4b",
        displayName: "Demo vUSDC vault",
        sourceTokens: {
          // Avalanche Fuji selector
          "14767482510784806043": {
            assetToken: "0xD21341536c5cF5EB1bcb58f6723cE26e8D8E90e4",
            shareToken: "0xBaC503B53C9468f2A92De6aD60CD17ac951eF707",
          },
        },
      },
    ],
  },
];

export function findKnownAdapter(address: string, hubChainId: number): AdapterEntry | undefined {
  return KNOWN_ADAPTERS.find(
    (a) => a.adapterAddress.toLowerCase() === address.toLowerCase() && a.hubChainId === hubChainId,
  );
}

export function vaultHintFor(
  entry: AdapterEntry | undefined,
  vaultAddress: string,
): VaultHint | undefined {
  return entry?.vaultHints?.find(
    (v) => v.vaultAddress.toLowerCase() === vaultAddress.toLowerCase(),
  );
}
