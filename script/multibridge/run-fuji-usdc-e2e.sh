#!/usr/bin/env bash
# Full Fuji USDC e2e: CCIP deposit/redeem + intentional failure flows (Avalanche Fuji ↔ Sepolia hub).
# Writes a timestamped log dir with per-step logs and a summary.md with explorer links.
#
# Usage:
#   bash script/multibridge/run-fuji-usdc-e2e.sh                 # run everything
#   bash script/multibridge/run-fuji-usdc-e2e.sh --only deposits
#   bash script/multibridge/run-fuji-usdc-e2e.sh --only fail --recover-fail
#   bash script/multibridge/run-fuji-usdc-e2e.sh --dry-run
#
# Prerequisites:
#   1. USDC vault adapter deployed on Sepolia (admin configured)
#   2. adapters.usdc.app set in config/multibridge/sepolia.json (or export ADAPTER=0x…)
#   3. bash script/multibridge/sync-hub-config-usdc-sepolia.sh
#   4. Fuji USDC (0x5425…) for deposits; Fuji share token for redeems
#
# Env (from e2e/multibridge/.env): HUB_RPC_URL, SPOKE_FUJI_RPC_URL, PRIVATE_KEY, CONFIG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
E2E="$ROOT/e2e/multibridge"
CONFIG="${CONFIG:-config/multibridge/sepolia.json}"

ONLY="all"
DRY_RUN=0
RECOVER_FAIL=0
PAUSE_SEC="${PAUSE_SEC:-30}"
HUB_WAIT_SEC="${HUB_WAIT_SEC:-600}"
HUB_POLL_SEC="${HUB_POLL_SEC:-20}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \?//'
  echo
  echo "Options:"
  echo "  --only deposits|redeems|fail|all   subset of tests (default: all)"
  echo "  --recover-fail                     after fail tests, poll hub and run refundToSource"
  echo "  --pause SEC                        seconds between originate steps (default: 30)"
  echo "  --hub-wait SEC                     max seconds to wait for hub capture on fail tests (default: 600)"
  echo "  --hub-poll SEC                     poll interval for hub capture (default: 20)"
  echo "  --dry-run                          print planned steps, do not broadcast"
  echo "  -h, --help                         show this help"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    --recover-fail) RECOVER_FAIL=1; shift ;;
    --pause) PAUSE_SEC="$2"; shift 2 ;;
    --hub-wait) HUB_WAIT_SEC="$2"; shift 2 ;;
    --hub-poll) HUB_POLL_SEC="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$ONLY" in
  all|deposits|redeems|fail) ;;
  *) echo "invalid --only value: $ONLY" >&2; exit 1 ;;
esac

# shellcheck disable=SC1091
if [[ -f "$E2E/.env" ]]; then
  set -a
  source "$E2E/.env"
  set +a
fi

: "${HUB_RPC_URL:?Set HUB_RPC_URL in e2e/multibridge/.env}"
: "${SPOKE_FUJI_RPC_URL:?Set SPOKE_FUJI_RPC_URL in e2e/multibridge/.env}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY in e2e/multibridge/.env}"

ADAPTER="${ADAPTER:-$(jq -r '.adapters.usdc.app // empty' "$ROOT/$CONFIG")}"
if [[ -z "$ADAPTER" || "$ADAPTER" == "0x0000000000000000000000000000000000000000" || "$ADAPTER" == "null" ]]; then
  echo "USDC adapter not set — deploy clone, paste adapters.usdc.app in $CONFIG, or export ADAPTER=0x…" >&2
  exit 1
fi
export ADAPTER ADAPTER_PROFILE=usdc CONFIG

STAMP="$(date -u +%Y%m%d-%H%M%S)"
LOG_DIR="$ROOT/logs/fuji-usdc-e2e-$STAMP"
mkdir -p "$LOG_DIR"

SUMMARY="$LOG_DIR/summary.md"
MAIN_LOG="$LOG_DIR/run.log"

log() {
  local msg="[$(date -u +%H:%M:%S)] $*"
  echo "$msg" | tee -a "$MAIN_LOG"
}

json_field() {
  local json="$1" field="$2"
  node -e "const o=JSON.parse(process.argv[1]); const v=o[process.argv[2]]; process.stdout.write(v==null?'':String(v))" "$json" "$field" 2>/dev/null || true
}

json_nested() {
  local json="$1" path="$2"
  node -e "
    const o = JSON.parse(process.argv[1]);
    const v = process.argv[2].split('.').reduce((a,k)=>a&&a[k], o);
    process.stdout.write(v==null?'':String(v));
  " "$json" "$path" 2>/dev/null || true
}

parse_e2e_result() {
  local file="$1"
  grep -E '^E2E_RESULT=' "$file" 2>/dev/null | tail -1 | sed 's/^E2E_RESULT=//' || true
}

parse_e2e_recover() {
  local file="$1"
  grep -E '^E2E_RECOVER_RESULT=' "$file" 2>/dev/null | tail -1 | sed 's/^E2E_RECOVER_RESULT=//' || true
}

fuji_share_token() {
  node -e "
    const fs = require('fs');
    const c = JSON.parse(fs.readFileSync('$ROOT/$CONFIG', 'utf8'));
    const t = c.spokes?.avalancheFuji?.shareToken;
    if (t && t !== '0x0000000000000000000000000000000000000000') console.log(t);
  " 2>/dev/null || true
}

# id|label|scenario|expect_fail
declare -a PLAN=()

add_test() {
  local id="$1" label="$2" scenario="$3" expect_fail="$4"
  case "$ONLY" in
    all) PLAN+=("$id|$label|$scenario|$expect_fail") ;;
    deposits)
      [[ "$id" == deposit-* ]] && PLAN+=("$id|$label|$scenario|$expect_fail")
      ;;
    redeems)
      [[ "$id" == redeem-* ]] && PLAN+=("$id|$label|$scenario|$expect_fail")
      ;;
    fail)
      [[ "$id" == fail-* ]] && PLAN+=("$id|$label|$scenario|$expect_fail")
      ;;
  esac
}

add_test deposit-fuji-usdc "Deposit USDC (CCIP) → hub → CCIP shares" deposit-fuji-usdc 0
add_test redeem-fuji-usdc "Redeem shares (CCIP) → hub → CCIP USDC" redeem-fuji-usdc 0
add_test fail-deposit-fuji-usdc "FAIL deposit (slippage breach, expect capture)" fail-deposit-fuji-usdc 1
add_test fail-redeem-fuji-usdc "FAIL redeem (slippage breach, expect capture)" fail-redeem-fuji-usdc 1

FUJI_SHARE="$(fuji_share_token)"
SKIP_FUJI_REDEEM=0
if [[ -z "$FUJI_SHARE" ]]; then
  SKIP_FUJI_REDEEM=1
  log "NOTE: spokes.avalancheFuji.shareToken not set — skipping redeem-fuji-usdc and fail-redeem-fuji-usdc"
fi

{
  echo "# Fuji USDC E2E run — $STAMP (UTC)"
  echo
  echo "- Config: \`$CONFIG\`"
  echo "- USDC adapter: \`$ADAPTER\`"
  echo "- Log dir: \`$LOG_DIR\`"
  echo "- Fee policy: CCIP originator pays via inbound token skim (\`inboundFees\` in \`vaultAdapterUsdc\` — run \`bash script/multibridge/sync-hub-config-usdc-sepolia.sh\` after edits)"
  echo "- Hub wait (fail tests): ${HUB_WAIT_SEC}s (poll every ${HUB_POLL_SEC}s)"
  echo "- Recover fail: $([[ $RECOVER_FAIL -eq 1 ]] && echo yes || echo no)"
  echo
  echo "## Steps"
  echo
} > "$SUMMARY"

PASS=0
FAIL=0
SKIP=0

run_initiate() {
  local id="$1" label="$2" scenario="$3" expect_fail="$4"
  local step_log="$LOG_DIR/${id}.log"

  if [[ "$id" == redeem-fuji-usdc || "$id" == fail-redeem-fuji-usdc ]] && [[ "$SKIP_FUJI_REDEEM" -eq 1 ]]; then
    log "SKIP $id — Fuji shareToken not configured"
    echo "### SKIP \`$id\` — $label" >> "$SUMMARY"
    echo "_Fuji shareToken missing in \`${CONFIG}\`_" >> "$SUMMARY"
    echo >> "$SUMMARY"
    SKIP=$((SKIP + 1))
    return 0
  fi

  log "━━━ $id: $label (SCENARIO=$scenario) ━━━"
  echo "### $id — $label" >> "$SUMMARY"
  echo "_scenario: \`$scenario\`_" >> "$SUMMARY"
  echo >> "$SUMMARY"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN — would run: cd e2e/multibridge && SCENARIO=$scenario pnpm run initiate"
    echo "**dry-run** — not broadcast" >> "$SUMMARY"
    echo >> "$SUMMARY"
    return 0
  fi

  local rc=0
  (
    cd "$E2E"
    export CONFIG ADAPTER ADAPTER_PROFILE=usdc
    SCENARIO="$scenario" pnpm run initiate
  ) > "$step_log" 2>&1 || rc=$?

  cat "$step_log" | tee -a "$MAIN_LOG"

  if [[ "$rc" -ne 0 ]]; then
    log "FAIL $id — originate exited $rc (see $step_log)"
    echo "**FAIL** — originate exited with code $rc" >> "$SUMMARY"
    echo "\`\`\`" >> "$SUMMARY"
    tail -20 "$step_log" >> "$SUMMARY"
    echo "\`\`\`" >> "$SUMMARY"
    echo >> "$SUMMARY"
    FAIL=$((FAIL + 1))
    return "$rc"
  fi

  local result json
  result="$(parse_e2e_result "$step_log")"
  if [[ -z "$result" ]]; then
    log "FAIL $id — no E2E_RESULT line in output"
    echo "**FAIL** — missing E2E_RESULT JSON" >> "$SUMMARY"
    echo >> "$SUMMARY"
    FAIL=$((FAIL + 1))
    return 1
  fi

  local tx_hash msg_id channel native_url cc_tx cc_msg
  tx_hash="$(json_field "$result" txHash)"
  msg_id="$(json_field "$result" messageId)"
  channel="$(json_field "$result" channel)"
  native_url="$(json_nested "$result" links.nativeTx)"
  cc_tx="$(json_nested "$result" links.crossChainTx)"
  cc_msg="$(json_nested "$result" links.crossChainMsg)"

  log "OK $id — tx=$tx_hash  messageId/guid=$msg_id  rail=$channel"
  log "  native tx:  $native_url"
  log "  cross-chain: $cc_tx"
  log "  message:     $cc_msg"

  {
    echo "**OK** — originate broadcast"
    echo "- Native tx: [$tx_hash]($native_url)"
    if [[ "$channel" == "ccip" ]]; then
      echo "- CCIP message: [$msg_id]($cc_msg)"
      echo "- CCIP tx: [$tx_hash]($cc_tx)"
    else
      echo "- LayerZero Scan (tx): [$tx_hash]($cc_tx)"
      echo "- LayerZero Scan (guid): [$msg_id]($cc_msg)"
    fi
    echo "- Message id / guid: \`$msg_id\`"
  } >> "$SUMMARY"

  if [[ "$expect_fail" == "1" ]]; then
    echo "- _Expected: hub delivery reverts on minAmountOut → MessageFailed_" >> "$SUMMARY"
    wait_and_maybe_recover "$id" "$msg_id" "$scenario"
  fi

  echo >> "$SUMMARY"
  PASS=$((PASS + 1))
  return 0
}

wait_and_maybe_recover() {
  local id="$1" guid="$2" scenario="$3"
  local waited=0
  local status_log="$LOG_DIR/${id}-status.log"
  local captured=0

  log "Waiting for hub capture (GUID=$guid, up to ${HUB_WAIT_SEC}s) ..."
  echo "#### Hub capture — \`$id\`" >> "$SUMMARY"

  while [[ "$waited" -lt "$HUB_WAIT_SEC" ]]; do
    local status_json rc=0
    (
      cd "$E2E"
      export CONFIG ADAPTER ADAPTER_PROFILE=usdc
      SCENARIO="$scenario"
      GUID="$guid" pnpm run recover:status
    ) > "$status_log" 2>&1 || rc=$?

    cat "$status_log" >> "$MAIN_LOG"
    status_json="$(parse_e2e_recover "$status_log")"

    if [[ "$rc" -ne 0 && -z "$status_json" ]]; then
      log "ERROR recover:status exited $rc — $(tail -1 "$status_log")"
      echo "- Hub capture: **error** — recover:status failed (see \`${id}-status.log\`)" >> "$SUMMARY"
      return "$rc"
    fi

    local is_failed is_refunded
    is_failed="$(json_field "$status_json" isFailed)"
    is_refunded="$(json_field "$status_json" isRefunded)"

    if [[ "$is_failed" == "true" ]]; then
      captured=1
      log "Hub captured failure for $id (isFailed=true)"
      echo "- Hub capture: **yes** (\`isFailed=true\`)" >> "$SUMMARY"
      break
    fi
    if [[ "$is_refunded" == "true" ]]; then
      log "Already refunded for $id"
      echo "- Hub capture: already **refunded**" >> "$SUMMARY"
      captured=2
      break
    fi

    log "  not captured yet (${waited}s / ${HUB_WAIT_SEC}s) ..."
    sleep "$HUB_POLL_SEC"
    waited=$((waited + HUB_POLL_SEC))
  done

  if [[ "$captured" -eq 0 ]]; then
    log "WARN $id — hub did not capture within ${HUB_WAIT_SEC}s (check CCIP relay)"
    echo "- Hub capture: **timeout** — check cross-chain relay manually" >> "$SUMMARY"
    echo "- GUID: \`$guid\`" >> "$SUMMARY"
    return 0
  fi

  if [[ "$RECOVER_FAIL" -ne 1 || "$captured" -eq 2 ]]; then
    [[ "$RECOVER_FAIL" -ne 1 ]] && echo "- Recovery: skipped (pass \`--recover-fail\` to run refundToSource)" >> "$SUMMARY"
    return 0
  fi

  local refund_log="$LOG_DIR/${id}-refund.log"
  log "Running refundToSource for $id ..."
  local rc=0
  (
    cd "$E2E"
    export CONFIG ADAPTER ADAPTER_PROFILE=usdc
    SCENARIO="$scenario"
    GUID="$guid" pnpm run recover:refund
  ) > "$refund_log" 2>&1 || rc=$?

  cat "$refund_log" | tee -a "$MAIN_LOG"

  if [[ "$rc" -ne 0 ]]; then
    log "FAIL $id recovery — exit $rc"
    echo "- Recovery: **FAIL** (exit $rc)" >> "$SUMMARY"
    return "$rc"
  fi

  local recover_json refund_tx hub_url
  recover_json="$(parse_e2e_recover "$refund_log")"
  refund_tx="$(json_field "$recover_json" refundTxHash)"
  hub_url="$(json_nested "$recover_json" links.hubTx)"

  log "OK $id recovery — hub tx=$refund_tx"
  echo "- Recovery: **OK** — [hub tx $refund_tx]($hub_url)" >> "$SUMMARY"
}

# ── main ──────────────────────────────────────────────────────────────────────

log "Fuji USDC E2E — log dir: $LOG_DIR"
log "Adapter: $ADAPTER"
log "Mode: only=$ONLY  recover_fail=$RECOVER_FAIL  pause=${PAUSE_SEC}s  dry_run=$DRY_RUN"
log "Planned steps: ${#PLAN[@]}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  for entry in "${PLAN[@]}"; do
    IFS='|' read -r id label scenario expect_fail <<< "$entry"
    if [[ "$id" == redeem-fuji-usdc || "$id" == fail-redeem-fuji-usdc ]] && [[ "$SKIP_FUJI_REDEEM" -eq 1 ]]; then
      log "  SKIP $id"
    else
      log "  RUN  $id ($scenario)"
    fi
  done
  log "Dry run complete."
  exit 0
fi

if [[ ! -d "$E2E/node_modules" ]]; then
  log "Installing e2e dependencies ..."
  (cd "$E2E" && pnpm install) | tee -a "$MAIN_LOG"
fi

i=0
for entry in "${PLAN[@]}"; do
  IFS='|' read -r id label scenario expect_fail <<< "$entry"
  i=$((i + 1))
  run_initiate "$id" "$label" "$scenario" "$expect_fail" || true
  if [[ "$i" -lt "${#PLAN[@]}" ]]; then
    log "Pausing ${PAUSE_SEC}s before next step ..."
    sleep "$PAUSE_SEC"
  fi
done

TOTAL=$((PASS + FAIL + SKIP))

{
  echo "## Summary"
  echo
  echo "| Result | Count |"
  echo "|--------|------:|"
  echo "| OK | $PASS |"
  echo "| FAIL | $FAIL |"
  echo "| SKIP | $SKIP |"
  echo "| **Total** | **$TOTAL** |"
  echo
  echo "Full log: \`$MAIN_LOG\`"
  echo
  echo "Track CCIP: https://ccip.chain.link"
} >> "$SUMMARY"

log ""
log "════════════════════════════════════════════"
log "  Done — OK: $PASS  FAIL: $FAIL  SKIP: $SKIP"
log "  Log:     $MAIN_LOG"
log "  Summary: $SUMMARY"
log "════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
