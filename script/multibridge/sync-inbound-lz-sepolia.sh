#!/usr/bin/env bash
# Apply vaultAdapter.lzSrcEids/lzSrcOfts from config onto the live hub adapter (idempotent).
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

echo "adapter: $ADAPTER"
echo "config:  $CONFIG"

ADAPTER="$ADAPTER" CONFIG="$CONFIG" forge script script/multibridge/sepolia/SyncInboundLz.s.sol:SyncInboundLz \
  --rpc-url "$HUB_RPC_URL" \
  --account "$ACCOUNT" \
  --broadcast --slow --skip-simulation
