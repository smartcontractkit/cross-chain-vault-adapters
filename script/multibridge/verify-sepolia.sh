#!/usr/bin/env bash
# Verify Sepolia deployment from deployments/multibridge/11155111.json on Etherscan.
# Requires: ETHERSCAN_API_KEY (export or in e2e/multibridge/.env), forge, cast
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [[ -f e2e/multibridge/.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source e2e/multibridge/.env
  set +a
fi

: "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY (export or add to e2e/multibridge/.env)}"

DEPLOY_JSON="${ROOT}/deployments/multibridge/11155111.json"
if [[ ! -f "$DEPLOY_JSON" ]]; then
  echo "missing $DEPLOY_JSON — deploy first (DeploySepoliaVaultAdapter.s.sol)" >&2
  exit 1
fi

IMPL=$(jq -r .implementation "$DEPLOY_JSON")
FACTORY=$(jq -r .factory "$DEPLOY_JSON")
APP=$(jq -r .app "$DEPLOY_JSON")

echo "Verifying CrossChainVaultAdapter implementation: $IMPL"
forge verify-contract \
  --chain sepolia \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  "$IMPL" \
  src/multibridge/examples/CrossChainVaultAdapter.sol:CrossChainVaultAdapter \
  --watch

FACTORY_ARGS=$(cast abi-encode "constructor(address)" "$IMPL")
echo "Verifying CrossChainVaultAdapterFactory: $FACTORY"
forge verify-contract \
  --chain sepolia \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --constructor-args "$FACTORY_ARGS" \
  "$FACTORY" \
  src/multibridge/CrossChainVaultAdapterFactory.sol:CrossChainVaultAdapterFactory \
  --watch

cat <<EOF

Implementation and factory submitted to Etherscan.

The deployed adapter clone ($APP) is an EIP-1167 minimal proxy. After the
implementation is verified, open the clone on Sepolia Etherscan and use
"More Options" → "Is this a proxy?" (or it may auto-detect) and point it at:

  $IMPL

Clone (adapter app): https://sepolia.etherscan.io/address/$APP
Implementation:      https://sepolia.etherscan.io/address/$IMPL
Factory:               https://sepolia.etherscan.io/address/$FACTORY

EOF
