#!/usr/bin/env bash
# Deploy the USDC vault adapter clone + Fuji CCIP routes (requires factory in config/multibridge/sepolia.json).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f e2e/multibridge/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source e2e/multibridge/.env
  set +a
fi

: "${HUB_RPC_URL:?Set HUB_RPC_URL (e.g. in e2e/multibridge/.env)}"

export CONFIG="${CONFIG:-config/multibridge/sepolia.json}"
export VAULT_ADAPTER_KEY=".vaultAdapterUsdc"
export ROUTES_KEY=".usdcRoutes"

bash script/multibridge/deploy-adapter-sepolia.sh "$@"
