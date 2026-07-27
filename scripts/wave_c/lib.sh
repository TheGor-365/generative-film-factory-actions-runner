#!/usr/bin/env bash
set -uo pipefail

policy_error() {
  printf '%s\n' "POLICY_ERROR=$1" "RESULT=ERROR" "EXIT_CODE=2" "NO_FAKE_GREEN=true"
  exit 2
}

if [[ $# -ne 1 ]]; then
  policy_error "INVALID_RUNNER_ARGUMENT_COUNT"
fi

private_checkout=$1
: "${GATE_ID:?GATE_ID is required}"
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_BRANCH:?PRIVATE_BRANCH is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"
: "${GFF_WAVE_C_WORK_ROOT:?GFF_WAVE_C_WORK_ROOT is required}"

[[ "$GATE_ID" == "GFF_WAVE_C_G1_V03_VALIDATION_v01" ]] || policy_error "GATE_ID_NOT_ALLOWLISTED"
[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || policy_error "PRIVATE_REPO_NOT_ALLOWLISTED"
[[ "$PRIVATE_BRANCH" == "main" ]] || policy_error "PRIVATE_BRANCH_NOT_ALLOWLISTED"
[[ "$STATUS_CONTEXT" == "public-runner/gff/wave-c-validation" ]] || policy_error "STATUS_CONTEXT_NOT_ALLOWLISTED"
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_PRIVATE_SHA"
[[ -d "$private_checkout/.git" ]] || policy_error "PRIVATE_CHECKOUT_MISSING"
[[ "$(git -C "$private_checkout" rev-parse HEAD 2>/dev/null)" == "$PRIVATE_SHA" ]] || policy_error "DETACHED_SHA_MISMATCH"

contract_path="contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json"
[[ -f "$contract_path" ]] || policy_error "GATE_CONTRACT_MISSING"

work_root=$GFF_WAVE_C_WORK_ROOT
logs_root="$work_root/logs"
evidence_root="$work_root/evidence"
records_path="$evidence_root/command_records.ndjson"
component_summary_path="$evidence_root/component_test_summary.json"
doctor_path="$evidence_root/doctor.json"
run_a_root="$work_root/run-a"
run_b_root="$work_root/run-b"
aggregate_root="$evidence_root/aggregate"
mkdir -p "$logs_root" "$evidence_root" "$aggregate_root" "$work_root/tmp" "$work_root/cache"
: > "$records_path"

result="PASS"
exit_code=0
blocked_codes=()
failed_codes=()
error_codes=()

mark_error() {
  local code=$1
  error_codes+=("$code")
  result="ERROR"
  exit_code=2
}

mark_fail() {
  local code=$1
  failed_codes+=("$code")
  if [[ "$result" != "ERROR" ]]; then
    result="FAIL"
    exit_code=1
  fi
}

mark_blocked() {
  local code=$1
  blocked_codes+=("$code")
  if [[ "$result" == "PASS" ]]; then
    result="BLOCKED"
    exit_code=3
  fi
}

append_record() {
  local command_id=$1
  local category=$2
  local command_exit=$3
  local log_sha=$4
  local stable_codes=$5
  if ! COMMAND_ID="$command_id" CATEGORY="$category" COMMAND_EXIT="$command_exit" LOG_SHA="$log_sha" STABLE_CODES="$stable_codes" \
    timeout --signal=TERM --kill-after=5s 30s python3 - "$records_path" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
record = {
    "command": os.environ["COMMAND_ID"],
    "category": os.environ["CATEGORY"],
    "exit_code": int(os.environ["COMMAND_EXIT"]),
    "status": "passed" if os.environ["COMMAND_EXIT"] == "0" else "failed",
    "log_sha256": os.environ["LOG_SHA"],
    "stable_codes": [item for item in os.environ.get("STABLE_CODES", "").split(",") if item],
}
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
PY
  then
    policy_error "COMMAND_RECORD_APPEND_FAILED"
  fi
}

extract_stable_codes() {
  timeout --signal=TERM --kill-after=5s 30s python3 - "$1" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
codes = set(re.findall(r"(?:FAILURE_CODE|POLICY_ERROR|VALIDATION_ERROR|MANIFEST_ERROR|REPORT_ERROR|PACKAGE_ERROR)=([A-Za-z0-9_.:-]+)", text))
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
print(",".join(sorted(codes)[:12]))
PY
}

base_env=(
  "HOME=$HOME"
  "PATH=$PATH"
  "LANG=C.UTF-8"
  "LC_ALL=C.UTF-8"
  "TMPDIR=$work_root/tmp"
  "XDG_CACHE_HOME=$work_root/cache"
  "FACTORY_MVP_SOURCE_HEAD=$PRIVATE_SHA"
  "FACTORY_MVP_MODE=deterministic"
  "FACTORY_MVP_MEDIA_MODE=deterministic"
  "FACTORY_MVP_ALLOW_PROVIDER_FALLBACK=false"
  "FACTORY_MVP_NETWORK_MEDIA_PROVIDER_CALLS=false"
  "FACTORY_MVP_PAID_PROVIDER_CALLS=false"
)

run_private() {
  local command_id=$1
  local category=$2
  local cwd=$3
  shift 3
  local extra_env=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    extra_env+=("$1")
    shift
  done
  [[ $# -gt 0 && "$1" == "--" ]] || policy_error "RUNNER_COMMAND_SEPARATOR_MISSING"
  shift
  [[ $# -gt 0 ]] || policy_error "RUNNER_COMMAND_MISSING"

  local log_file="$logs_root/${command_id}.log"
  local command_exit
  local command_timeout
  case "$category" in
    pilot) command_timeout=2400 ;;
    component|aggregate) command_timeout=1200 ;;
    validator|doctor|verify|stage) command_timeout=600 ;;
    *) command_timeout=600 ;;
  esac
  if (
    cd "$cwd" || exit 2
    timeout --signal=TERM --kill-after=30s "$command_timeout" env -i "${base_env[@]}" "${extra_env[@]}" "$@" >"$log_file" 2>&1
  ); then
    command_exit=0
  else
    command_exit=$?
  fi
  local log_sha
  log_sha="$(sha256sum "$log_file" | awk '{print $1}')"
  local stable_codes
  stable_codes="$(extract_stable_codes "$log_file" 2>/dev/null || true)"
  append_record "$command_id" "$category" "$command_exit" "$log_sha" "$stable_codes"
  printf '%s\n' \
    "COMMAND_ID=$command_id" \
    "COMMAND_EXIT_CODE=$command_exit" \
    "COMMAND_LOG_SHA256=$log_sha" \
    "COMMAND_STABLE_CODES=${stable_codes:-none}"
  if [[ $command_exit -ne 0 ]]; then
    mark_fail "${command_id}_FAILED"
  fi
  return "$command_exit"
}

require_tool() {
  local tool=$1
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s\n' "TOOL_${tool^^}=PRESENT"
  else
    printf '%s\n' "TOOL_${tool^^}=MISSING"
    mark_error "TOOLCHAIN_${tool^^}_MISSING"
  fi
}
