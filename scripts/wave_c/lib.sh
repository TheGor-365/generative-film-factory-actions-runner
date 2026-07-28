#!/usr/bin/env bash
set -uo pipefail

policy_error() {
  printf '%s\n' "POLICY_ERROR=$1" "RESULT=ERROR" "EXIT_CODE=2" "NO_FAKE_GREEN=true"
  exit 2
}

if [[ $# -ne 2 ]]; then
  policy_error "INVALID_RUNNER_ARGUMENT_COUNT"
fi

private_checkout=$1
phase=$2
: "${GATE_ID:?GATE_ID is required}"
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_BRANCH:?PRIVATE_BRANCH is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${RUNNER_REPO:?RUNNER_REPO is required}"
: "${RUNNER_SHA:?RUNNER_SHA is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"
: "${GFF_WAVE_C_WORK_ROOT:?GFF_WAVE_C_WORK_ROOT is required}"

[[ "$GATE_ID" == "GFF_WAVE_C_G1_V03_VALIDATION_v01" ]] || policy_error "GATE_ID_NOT_ALLOWLISTED"
[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || policy_error "PRIVATE_REPO_NOT_ALLOWLISTED"
[[ "$PRIVATE_BRANCH" == "main" ]] || policy_error "PRIVATE_BRANCH_NOT_ALLOWLISTED"
[[ "$RUNNER_REPO" == "TheGor-365/generative-film-factory-actions-runner" ]] || policy_error "RUNNER_REPO_NOT_ALLOWLISTED"
[[ "$STATUS_CONTEXT" == "public-runner/gff/wave-c-validation" ]] || policy_error "STATUS_CONTEXT_NOT_ALLOWLISTED"
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_PRIVATE_SHA"
[[ "$RUNNER_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_RUNNER_SHA"

contract_path="contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json"
helper_path="scripts/wave_c/evidence_contract.py"
[[ -f "$contract_path" ]] || policy_error "GATE_CONTRACT_MISSING"
[[ -f "$helper_path" ]] || policy_error "EVIDENCE_HELPER_MISSING"

work_root=$GFF_WAVE_C_WORK_ROOT
logs_root="$work_root/logs"
evidence_root="$work_root/evidence"
records_path="$evidence_root/gate_state.json"
component_matrix_path="$evidence_root/component_matrix_v02.json"
component_summary_path="$evidence_root/component_test_summary.json"
doctor_path="$evidence_root/doctor.json"
run_a_root="$work_root/run-a"
run_b_root="$work_root/run-b"
aggregate_root="$evidence_root/aggregate"
v03_root="$work_root/canonical-v03"

base_env=(
  "HOME=$HOME"
  "PATH=$PATH"
  "LANG=C.UTF-8"
  "LC_ALL=C.UTF-8"
  "TMPDIR=$work_root/tmp"
  "XDG_CACHE_HOME=$work_root/tmp/xdg"
  "FACTORY_MVP_SOURCE_HEAD=$PRIVATE_SHA"
  "FACTORY_MVP_MODE=deterministic"
  "FACTORY_MVP_MEDIA_MODE=deterministic"
  "FACTORY_MVP_ALLOW_PROVIDER_FALLBACK=false"
  "FACTORY_MVP_NETWORK_MEDIA_PROVIDER_CALLS=false"
  "FACTORY_MVP_PAID_PROVIDER_CALLS=false"
)

sha_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

extract_stable_codes() {
  python3 - "$1" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
codes = set(re.findall(r"(?:FAILURE_CODE|POLICY_ERROR|VALIDATION_ERROR|MANIFEST_ERROR|REPORT_ERROR|PACKAGE_ERROR|BLOCKER_CODE)=([A-Za-z0-9_.:-]+)", text))
try:
    payload = json.loads(text)
except Exception:
    payload = None

def walk(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"code", "error_code", "blocker_code"} and isinstance(child, str) and re.fullmatch(r"[A-Za-z0-9_.:-]+", child):
                codes.add(child)
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(payload)
print("\n".join(sorted(codes)[:16]))
PY
}

record_result() {
  local step_id=$1
  local category=$2
  local command_id=$3
  local outcome=$4
  local command_exit=$5
  local evidence_sha=$6
  shift 6
  local args=(
    "$helper_path" record
    --work-root "$work_root"
    --step-id "$step_id"
    --category "$category"
    --command-id "$command_id"
    --outcome "$outcome"
    --exit-code "$command_exit"
    --evidence-sha256 "$evidence_sha"
  )
  local code
  for code in "$@"; do
    [[ -n "$code" ]] && args+=(--stable-code "$code")
  done
  python3 "${args[@]}" >/dev/null
  printf '%s\n' \
    "STEP_ID=$step_id" \
    "COMMAND_ID=$command_id" \
    "COMMAND_OUTCOME=$outcome" \
    "COMMAND_EXIT_CODE=$command_exit" \
    "COMMAND_EVIDENCE_SHA256=$evidence_sha"
}

record_missing() {
  local step_id=$1
  local category=$2
  local command_id=$3
  local code=$4
  local digest
  digest=$(sha_text "$step_id|$command_id|$code|BLOCKED")
  record_result "$step_id" "$category" "$command_id" BLOCKED 3 "$digest" "$code"
}

record_error() {
  local step_id=$1
  local category=$2
  local command_id=$3
  local code=$4
  local digest
  digest=$(sha_text "$step_id|$command_id|$code|ERROR")
  record_result "$step_id" "$category" "$command_id" ERROR 2 "$digest" "$code"
}

require_exact_checkout() {
  local step_id=$1
  if [[ ! -d "$private_checkout/.git" ]]; then
    record_error "$step_id" infrastructure "${step_id}_checkout" PRIVATE_CHECKOUT_MISSING
    return 1
  fi
  local observed
  observed=$(git -C "$private_checkout" rev-parse HEAD 2>/dev/null || true)
  if [[ "$observed" != "$PRIVATE_SHA" ]]; then
    record_error "$step_id" infrastructure "${step_id}_checkout" DETACHED_SHA_MISMATCH
    return 1
  fi
  return 0
}

run_private() {
  local step_id=$1
  local category=$2
  local command_id=$3
  local cwd=$4
  shift 4
  local extra_env=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra_env+=("$1")
    shift
  done
  [[ $# -gt 0 && "$1" == "--" ]] || policy_error "RUNNER_COMMAND_SEPARATOR_MISSING"
  shift
  [[ $# -gt 0 ]] || policy_error "RUNNER_COMMAND_MISSING"

  mkdir -p "$logs_root" "$work_root/tmp"
  local log_file="$logs_root/${command_id}.log"
  local command_timeout=600
  case "$category" in
    component|aggregate) command_timeout=1200 ;;
    pilot|canonical_v03) command_timeout=2400 ;;
  esac

  local command_exit=0
  if (
    cd "$cwd" || exit 2
    timeout --signal=TERM --kill-after=30s "$command_timeout" env -i "${base_env[@]}" "${extra_env[@]}" "$@" >"$log_file" 2>&1
  ); then
    command_exit=0
  else
    command_exit=$?
  fi

  local outcome=PASS
  if [[ $command_exit -eq 124 || $command_exit -eq 137 ]]; then
    outcome=ERROR
  elif [[ $command_exit -ne 0 ]]; then
    outcome=FAIL
  fi
  local log_sha
  log_sha=$(sha256sum "$log_file" | awk '{print $1}')
  local codes=()
  while IFS= read -r code; do
    [[ -n "$code" ]] && codes+=("$code")
  done < <(extract_stable_codes "$log_file" 2>/dev/null || true)
  record_result "$step_id" "$category" "$command_id" "$outcome" "$command_exit" "$log_sha" "${codes[@]}"
}

phase_initialize() {
  python3 "$helper_path" validate-contract --contract "$contract_path"
  [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$RUNNER_SHA" ]] || policy_error "PUBLIC_RUNNER_SHA_MISMATCH"
  mkdir -p "$logs_root" "$evidence_root" "$aggregate_root" "$work_root/tmp"
  python3 "$helper_path" init --work-root "$work_root" --gate-id "$GATE_ID" --private-sha "$PRIVATE_SHA" --runner-sha "$RUNNER_SHA"
  printf '%s\n' "RUNNER_SHA_MATCH=true" "INITIALIZATION=PASS"
}

phase_checkout_exact_sha() {
  if [[ ! -d "$private_checkout/.git" ]]; then
    record_error checkout_exact_sha infrastructure checkout_exact_sha PRIVATE_CHECKOUT_MISSING
    return 0
  fi
  local observed
  observed=$(git -C "$private_checkout" rev-parse HEAD 2>/dev/null || true)
  if [[ "$observed" != "$PRIVATE_SHA" ]]; then
    record_error checkout_exact_sha infrastructure checkout_exact_sha PRIVATE_MAIN_SHA_MISMATCH
    return 0
  fi
  git -C "$private_checkout" checkout --detach "$PRIVATE_SHA" >/dev/null 2>&1 || {
    record_error checkout_exact_sha infrastructure checkout_exact_sha PRIVATE_DETACH_FAILED
    return 0
  }
  if [[ "$(git -C "$private_checkout" rev-parse HEAD)" != "$PRIVATE_SHA" || -n "$(git -C "$private_checkout" status --porcelain)" ]]; then
    record_error checkout_exact_sha infrastructure checkout_exact_sha PRIVATE_DETACHED_STATE_INVALID
    return 0
  fi
  local digest
  digest=$(sha_text "$PRIVATE_REPO|$PRIVATE_BRANCH|$PRIVATE_SHA|detached-clean")
  record_result checkout_exact_sha infrastructure checkout_exact_sha PASS 0 "$digest"
  printf '%s\n' "PRIVATE_MAIN_SHA_MATCH=true" "DETACHED_PRIVATE_SHA_CHECKOUT=true"
}
