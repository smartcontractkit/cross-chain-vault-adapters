#!/usr/bin/env bash
# Sync USDC vault adapter allowlists + routes from config/multibridge/sepolia.json (vaultAdapterUsdc + usdcRoutes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f e2e/multibridge/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source e2e/multibridge/.env
  set +a
fi

: "${HUB_RPC_URL:?Set HUB_RPC_URL}"
CONFIG="${CONFIG:-config/multibridge/sepolia.json}"

ADAPTER="${ADAPTER:-$(jq -r '.adapters.usdc.app // empty' "$CONFIG")}"
if [[ -z "$ADAPTER" || "$ADAPTER" == "0x0000000000000000000000000000000000000000" || "$ADAPTER" == "null" ]]; then
  echo "Set ADAPTER to the USDC vault clone, or paste adapters.usdc.app in $CONFIG" >&2
  exit 1
fi

ACCOUNT="${FOUNDRY_ACCOUNT:-vaultdeployer}"

echo "adapter (usdc): $ADAPTER"
echo "config:         $CONFIG"

ADAPTER="$ADAPTER" CONFIG="$CONFIG" VAULT_ADAPTER_KEY=.vaultAdapterUsdc ROUTES_KEY=.usdcRoutes CCIP_ONLY=1 \
  forge script script/multibridge/sepolia/SyncHubConfig.s.sol:SyncHubConfig \
  --rpc-url "$HUB_RPC_URL" \
  --private-key "${PRIVATE_KEY:?Set PRIVATE_KEY in e2e/multibridge/.env}" \
  --broadcast --slow --skip-simulation
