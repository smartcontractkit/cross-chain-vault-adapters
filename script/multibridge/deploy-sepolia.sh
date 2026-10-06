#!/usr/bin/env bash
# Two-step Sepolia deploy (recommended): factory first, then clone + routes.
#
#   bash script/multibridge/deploy-factory-sepolia.sh    # step 1: impl + factory
#   # paste addresses into config/multibridge/sepolia.json
#   bash script/multibridge/deploy-adapter-sepolia.sh  # step 2: clone + routes
set -euo pipefail
echo "Use the two-step deploy flow instead:" >&2
echo "  bash script/multibridge/deploy-factory-sepolia.sh" >&2
echo "  bash script/multibridge/deploy-adapter-sepolia.sh" >&2
exit 1
