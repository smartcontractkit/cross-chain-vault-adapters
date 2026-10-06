#!/usr/bin/env bash
# Finish adapter setup: install CCIP routes (after factory.deploy only).
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
: "${ADAPTER:?Set ADAPTER to the clone address (e.g. 0x9371...)}"

ACCOUNT="${FOUNDRY_ACCOUNT:-vaultdeployer}"
CONFIG="${CONFIG:-config/multibridge/sepolia.json}"

if [[ -z "${DEPLOYER:-}" ]]; then
  if [[ -n "${PRIVATE_KEY:-}" ]]; then
    DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
  else
    DEPLOYER=$(cast wallet address --account "$ACCOUNT")
  fi
fi
export DEPLOYER

echo "adapter:  $ADAPTER"
echo "deployer: $DEPLOYER"

AUTH_ARGS=(--account "$ACCOUNT")
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH_ARGS=(--private-key "$PRIVATE_KEY")
fi

ADAPTER="$ADAPTER" CONFIG="$CONFIG" forge script script/multibridge/sepolia/FinishAdapterConfig.s.sol:FinishAdapterConfig \
  --rpc-url "$HUB_RPC_URL" \
  "${AUTH_ARGS[@]}" \
  --broadcast --slow --skip-simulation
