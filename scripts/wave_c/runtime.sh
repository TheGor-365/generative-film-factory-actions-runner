#!/usr/bin/env bash
set -uo pipefail

factory_bin="10_factory_mvp/ops/bin/factory"
CHAT5_EXECUTOR_COMMIT="$(python3 - "$contract_path" <<'PY2'
import json
import re
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload.get("canonical_v03_executor", {}).get("source_commit")
print(value if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) else "")
PY2
)"
CHAT5_EXECUTOR_COMMAND="$(python3 - "$contract_path" <<'PY2'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload.get("canonical_v03_executor", {}).get("command")
print(value if isinstance(value, str) else "")
PY2
)"

factory_available() {
  local step_id=$1
  require_exact_checkout "$step_id" || return 1
  if [[ ! -f "$private_checkout/$factory_bin" ]]; then
    record_missing "$step_id" runtime "${step_id}_factory_entrypoint" FACTORY_ENTRYPOINT_MISSING
    return 1
  fi
  return 0
}

phase_validate_source() {
  factory_available validate_source || return 0
  run_private validate_source validator validate_source "$private_checkout" -- ruby "$factory_bin" validate-source
}

phase_doctor() {
  factory_available doctor || return 0
  run_private doctor doctor doctor "$private_checkout" -- ruby "$factory_bin" doctor
  if [[ -s "$logs_root/doctor.log" ]]; then
    cp "$logs_root/doctor.log" "$doctor_path"
  fi
}

run_pilot_phase() {
  local step_id=$1
  local run_root=$2
  factory_available "$step_id" || return 0
  rm -rf -- "$run_root"
  mkdir -p "$run_root"
  local runtime_root="$run_root/runtime"
  local artifact_root="$run_root/artifacts"
  local report_path="$run_root/pilot-report.json"
  run_private "$step_id" pilot "$step_id" "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$runtime_root" \
    "FACTORY_MVP_ARTIFACT_ROOT=$artifact_root" \
    "FACTORY_MVP_REPORT_PATH=$report_path" \
    -- ruby "$factory_bin" pilot --mode deterministic
  if [[ ! -f "$report_path" ]]; then
    record_missing "$step_id" pilot "${step_id}_report" "${step_id^^}_REPORT_MISSING"
  fi
}

phase_pilot_a() { run_pilot_phase pilot_a "$run_a_root"; }
phase_pilot_b() { run_pilot_phase pilot_b "$run_b_root"; }

json_string_field() {
  local path=$1
  shift
  python3 - "$path" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
keys = sys.argv[2:]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
for key in keys:
    value = payload.get(key)
    if isinstance(value, str) and value:
        print(value)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

run_verify_phase() {
  local step_id=$1
  local run_root=$2
  factory_available "$step_id" || return 0
  local report_path="$run_root/pilot-report.json"
  if [[ ! -f "$report_path" ]]; then
    record_missing "$step_id" verify "${step_id}_report" "${step_id^^}_REPORT_MISSING"
    return 0
  fi
  local manifest_path
  manifest_path=$(json_string_field "$report_path" manifest_path 2>/dev/null || true)
  if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
    record_missing "$step_id" verify "${step_id}_manifest" "${step_id^^}_MANIFEST_PATH_MISSING"
    return 0
  fi
  run_private "$step_id" verify "$step_id" "$private_checkout" -- ruby "$factory_bin" verify "$manifest_path"
  cp "$logs_root/${step_id}.log" "$run_root/verify.json"
}

phase_verify_a() { run_verify_phase verify_a "$run_a_root"; }
phase_verify_b() { run_verify_phase verify_b "$run_b_root"; }

phase_aggregate_release_check() {
  python3 "$helper_path" generate-components --work-root "$work_root"
  factory_available aggregate_release_check || return 0
  local run_a_report="$run_a_root/pilot-report.json"
  local run_b_report="$run_b_root/pilot-report.json"
  if [[ ! -f "$run_a_report" || ! -f "$run_b_report" || ! -f "$doctor_path" || ! -f "$component_summary_path" ]]; then
    record_missing aggregate_release_check aggregate aggregate_release_check AGGREGATE_INPUTS_MISSING
    return 0
  fi
  run_private aggregate_release_check aggregate aggregate_release_check "$private_checkout" \
    "FACTORY_MVP_COMPONENT_TEST_SUMMARY_PATH=$component_summary_path" \
    "FACTORY_MVP_DOCTOR_REPORT_PATH=$doctor_path" \
    "FACTORY_MVP_EVIDENCE_ROOT=$aggregate_root" \
    -- ruby "$factory_bin" release-check --run-1 "$run_a_report" --run-2 "$run_b_report"
  cp "$logs_root/aggregate_release_check.log" "$evidence_root/release-check.json"
}

phase_canonical_v03_executor() {
  local step_id=canonical_v03_executor
  factory_available "$step_id" || return 0

  if [[ ! "$CHAT5_EXECUTOR_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    record_missing "$step_id" canonical_v03 canonical_v03_executor CHAT5_EXECUTOR_COMMIT_NOT_BOUND
    return 0
  fi
  if ! git -C "$private_checkout" merge-base --is-ancestor "$CHAT5_EXECUTOR_COMMIT" "$PRIVATE_SHA" >/dev/null 2>&1; then
    record_missing "$step_id" canonical_v03 canonical_v03_executor CHAT5_EXECUTOR_COMMIT_NOT_IN_FROZEN_SHA
    return 0
  fi
  local cli_path="$private_checkout/10_factory_mvp/ops/lib/factory_mvp/ops_cli.rb"
  if [[ ! -f "$cli_path" ]] || ! grep -Fq 'when "wave-c-v03-cycle"' "$cli_path"; then
    record_missing "$step_id" canonical_v03 canonical_v03_executor CANONICAL_V03_EXECUTOR_COMMAND_MISSING
    return 0
  fi

  rm -rf -- "$v03_root"
  mkdir -p "$v03_root/runtime" "$v03_root/artifacts" "$v03_root/reports"
  run_private "$step_id" canonical_v03 CANONICAL_V03_EXECUTOR "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$v03_root/runtime" \
    "FACTORY_MVP_ARTIFACT_ROOT=$v03_root/artifacts" \
    "FACTORY_MVP_WAVE_C_REPORT_ROOT=$v03_root/reports" \
    -- ruby "$factory_bin" "$CHAT5_EXECUTOR_COMMAND" --source-sha "$PRIVATE_SHA"
}
