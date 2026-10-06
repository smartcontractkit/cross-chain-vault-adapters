#!/usr/bin/env bash
# Dump full on-chain state for a hub CrossChainVaultAdapter clone (roles, routes, return-leg fees).
#
# Usage:
#   ADAPTER=0x6C93… bash script/multibridge/inspect-adapter.sh
#   ADAPTER=0xfcc0… JSON=1 bash script/multibridge/inspect-adapter.sh          # machine-readable
#   ADAPTER_PROFILE=usdc ADAPTER=0x6C93… bash script/multibridge/inspect-adapter.sh
#
# Env: HUB_RPC_URL, CONFIG (default config/multibridge/sepolia.json), ADAPTER (required)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/e2e/multibridge"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${ADAPTER:?Set ADAPTER=0x… (hub clone)}"
: "${HUB_RPC_URL:?Set HUB_RPC_URL}"

export ADAPTER CONFIG="${CONFIG:-config/multibridge/sepolia.json}"

pnpm run inspect:adapter "$@"
