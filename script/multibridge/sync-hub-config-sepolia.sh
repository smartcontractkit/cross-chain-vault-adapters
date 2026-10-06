#!/usr/bin/env bash
# Sync hub adapter allowlists + route registry from config/multibridge/sepolia.json (idempotent).
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
: "${ADAPTER:?Set ADAPTER to the hub clone (e.g. 0x9371...)}"

ACCOUNT="${FOUNDRY_ACCOUNT:-vaultdeployer}"
CONFIG="${CONFIG:-config/multibridge/sepolia.json}"

AUTH_ARGS=(--account "$ACCOUNT")
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH_ARGS=(--private-key "$PRIVATE_KEY")
fi

echo "adapter: $ADAPTER"
echo "config:  $CONFIG"

USDC_ADAPTER=$(jq -r '.adapters.usdc.app // empty' "$CONFIG")
if [[ -n "$USDC_ADAPTER" && "$USDC_ADAPTER" != "null" && "$(echo "$ADAPTER" | tr '[:upper:]' '[:lower:]')" == "$(echo "$USDC_ADAPTER" | tr '[:upper:]' '[:lower:]')" ]]; then
  echo "ERROR: ADAPTER is the USDC clone ($USDC_ADAPTER)." >&2
  echo "Use: bash script/multibridge/sync-hub-config-usdc-sepolia.sh" >&2
  exit 1
fi

ADAPTER="$ADAPTER" CONFIG="$CONFIG" forge script script/multibridge/sepolia/SyncHubConfig.s.sol:SyncHubConfig \
  --rpc-url "$HUB_RPC_URL" \
  "${AUTH_ARGS[@]}" \
  --broadcast --slow --skip-simulation
