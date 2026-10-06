#!/usr/bin/env bash
# Step 2: factory.deploy(...) + route registry for your vault (requires step 1 addresses in config).
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

CONFIG="${CONFIG:-config/multibridge/sepolia.json}"
ACCOUNT="${FOUNDRY_ACCOUNT:-vaultdeployer}"

FACTORY=$(jq -r .hub.factory "$CONFIG")
if [[ "$FACTORY" == "0x0000000000000000000000000000000000000000" || -z "$FACTORY" ]]; then
  echo "hub.factory is not set in $CONFIG — run bash script/multibridge/deploy-factory-sepolia.sh first" >&2
  exit 1
fi

if [[ -z "${DEPLOYER:-}" ]]; then
  if [[ -n "${PRIVATE_KEY:-}" ]]; then
    DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
  else
    DEPLOYER=$(cast wallet address --account "$ACCOUNT")
  fi
fi
export DEPLOYER
echo "deployer: $DEPLOYER"

VERIFY_ARGS=()
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  VERIFY_ARGS=(--verify)
fi

AUTH_ARGS=(--account "$ACCOUNT")
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH_ARGS=(--private-key "$PRIVATE_KEY")
fi

# Pre-broadcast simulation false-reverts on Sepolia (same-tx vault.asset()); see SepoliaFactoryDeploy.t.sol.
EXTRA_ARGS=(--broadcast --slow)
if [[ "${SKIP_SIMULATION:-1}" == "1" ]]; then
  EXTRA_ARGS+=(--skip-simulation)
fi

CONFIG="$CONFIG" forge script script/multibridge/sepolia/DeployAdapterClone.s.sol:DeployAdapterClone \
  --rpc-url "$HUB_RPC_URL" \
  "${AUTH_ARGS[@]}" \
  "${EXTRA_ARGS[@]}" \
  "${VERIFY_ARGS[@]}"

DEPLOY_JSON="${ROOT}/deployments/multibridge/11155111.json"
if [[ -f "$DEPLOY_JSON" ]]; then
  APP=$(jq -r .app "$DEPLOY_JSON")
  IMPL=$(jq -r .implementation "$DEPLOY_JSON")
  echo ""
  echo "Adapter clone: https://sepolia.etherscan.io/address/${APP}"
  echo "Link proxy → implementation on Etherscan: ${IMPL}"
fi
