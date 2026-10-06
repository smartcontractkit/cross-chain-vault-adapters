#!/usr/bin/env bash
# Step 1: deploy CrossChainVaultAdapter implementation + factory on Ethereum Sepolia.
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

ACCOUNT="${FOUNDRY_ACCOUNT:-vaultdeployer}"
VERIFY_ARGS=()
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  VERIFY_ARGS=(--verify)
fi

AUTH_ARGS=(--account "$ACCOUNT")
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  AUTH_ARGS=(--private-key "$PRIVATE_KEY")
fi

FOUNDRY_PROFILE=deploy forge script script/multibridge/DeployImplementationAndFactory.s.sol:DeployImplementationAndFactory \
  --rpc-url "$HUB_RPC_URL" \
  "${AUTH_ARGS[@]}" \
  --broadcast --slow \
  "${VERIFY_ARGS[@]}"

cat <<'EOF'

Step 1 done. Copy the implementation + factory addresses from the output above into
config/multibridge/sepolia.json:

  "hub": {
    ...
    "factory": "0x...",
    "implementation": "0x..."
  }

Then run step 2:

  bash script/multibridge/deploy-adapter-sepolia.sh

EOF
