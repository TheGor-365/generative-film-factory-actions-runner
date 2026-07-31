#!/usr/bin/env bash
set -uo pipefail

factory_bin="10_factory_mvp/ops/bin/factory"
report_binding_helper="scripts/wave_c/report_discovery.py"
[[ -f "$report_binding_helper" ]] || policy_error "REPORT_BINDING_HELPER_MISSING"
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

record_report_helper_result() {
  local step_id=$1
  local category=$2
  local command_id=$3
  local log_file=$4
  local command_exit=$5
  local outcome=PASS
  [[ $command_exit -eq 0 ]] || outcome=FAIL
  local digest
  digest=$(sha256sum "$log_file" | awk '{print $1}')
  local codes=()
  local code
  while IFS= read -r code; do
    [[ -n "$code" ]] && codes+=("$code")
  done < <(extract_stable_codes "$log_file" 2>/dev/null || true)
  record_result "$step_id" "$category" "$command_id" "$outcome" "$command_exit" "$digest" "${codes[@]}"
}

run_pilot_phase() {
  local step_id=$1
  local run_root=$2
  factory_available "$step_id" || return 0
  rm -rf -- "$run_root"
  mkdir -p "$run_root"
  local runtime_root="$run_root/runtime"
  local artifact_root="$run_root/artifacts"
  local normalized_report="$run_root/pilot-report.json"
  local binding_path="$run_root/report-binding.json"
  local started_marker="$run_root/pilot-started.marker"
  : > "$started_marker"
  run_private "$step_id" pilot "$step_id" "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$runtime_root" \
    "FACTORY_MVP_ARTIFACT_ROOT=$artifact_root" \
    "FACTORY_MVP_REPORT_PATH=$normalized_report" \
    -- ruby "$factory_bin" pilot --mode deterministic

  local binding_log="$logs_root/${step_id}_report_binding.log"
  local binding_exit=0
  if python3 "$report_binding_helper" bind-pilot \
    --cli-log "$logs_root/${step_id}.log" \
    --expected-runtime-root "$runtime_root" \
    --expected-artifact-root "$artifact_root" \
    --expected-source-sha "$PRIVATE_SHA" \
    --expected-mode deterministic \
    --not-before-file "$started_marker" \
    --normalized-report "$normalized_report" \
    --binding-output "$binding_path" >"$binding_log" 2>&1; then
    binding_exit=0
  else
    binding_exit=$?
  fi
  cat "$binding_log"
  record_report_helper_result "$step_id" pilot "${step_id}_report_binding" "$binding_log" "$binding_exit"
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

select_original_release_reports() {
  local run_a_binding=$1
  local run_b_binding=$2
  local run_a_report=$3
  local run_b_report=$4
  local run_a_runtime_root=$5
  local run_a_artifact_root=$6
  local run_b_runtime_root=$7
  local run_b_artifact_root=$8

  python3 - "$report_binding_helper" \
    "$run_a_binding" "$run_b_binding" \
    "$run_a_report" "$run_b_report" \
    "$run_a_runtime_root" "$run_a_artifact_root" \
    "$run_b_runtime_root" "$run_b_artifact_root" <<'PY'
import importlib.util
import json
import stat
import sys
from pathlib import Path

helper_path = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("report_discovery_release_selector", helper_path)
helper = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(helper)


def fail(code: str, detail: str = "") -> None:
    print(f"REPORT_ERROR={code}", file=sys.stderr)
    if detail:
        print(f"REPORT_ERROR_DETAIL={detail}", file=sys.stderr)
    print("NO_FAKE_GREEN=true", file=sys.stderr)
    raise SystemExit(1)


def exact_string(payload: dict, key: str, code: str) -> str:
    value = payload.get(key)
    if type(value) is not str or not value:
        fail(code, key)
    return value


def select_one(
    binding_path: Path,
    normalized_path: Path,
    runtime_root: Path,
    artifact_root: Path,
    label: str,
) -> tuple[dict, Path]:
    try:
        binding = helper.load_binding(binding_path)
        helper.validate_binding(
            binding,
            expected_report=normalized_path,
            expected_runtime_root=runtime_root,
            expected_artifact_root=artifact_root,
        )
    except helper.EvidenceError as error:
        fail(error.code, error.detail)

    original_raw = exact_string(binding, "report_original_path", f"{label}_ORIGINAL_REPORT_PATH_INVALID")
    original = Path(original_raw)
    if not original.is_absolute():
        fail(f"{label}_ORIGINAL_REPORT_PATH_NOT_ABSOLUTE")
    try:
        original_lstat = original.lstat()
        original_resolved = original.resolve(strict=True)
        runtime_resolved = runtime_root.resolve(strict=True)
    except OSError as error:
        fail(f"{label}_ORIGINAL_REPORT_PATH_INVALID", str(error))
    if stat.S_ISLNK(original_lstat.st_mode) or not stat.S_ISREG(original_lstat.st_mode):
        fail(f"{label}_ORIGINAL_REPORT_NOT_REGULAR_NON_SYMLINK")
    if original_raw != str(original_resolved):
        fail(f"{label}_ORIGINAL_REPORT_PATH_NOT_CANONICAL")
    try:
        original_resolved.relative_to(runtime_resolved)
    except ValueError:
        fail(f"{label}_ORIGINAL_REPORT_OUTSIDE_RUNTIME_ROOT")

    run_id = exact_string(binding, "run_id", f"{label}_RUN_ID_INVALID")
    expected_original = runtime_resolved / "pilot-runs" / run_id / "pilot_report.json"
    if original_resolved != expected_original:
        fail(f"{label}_ORIGINAL_REPORT_BINDING_MISMATCH")

    digest = exact_string(binding, "report_sha256", f"{label}_ORIGINAL_REPORT_SHA256_INVALID")
    if helper.sha256_file(original_resolved) != digest:
        fail(f"{label}_ORIGINAL_REPORT_SHA256_MISMATCH")

    normalized_raw = exact_string(binding, "report_normalized_path", f"{label}_NORMALIZED_REPORT_PATH_INVALID")
    normalized = Path(normalized_raw)
    try:
        normalized_lstat = normalized.lstat()
        normalized_resolved = normalized.resolve(strict=True)
    except OSError as error:
        fail(f"{label}_NORMALIZED_REPORT_PATH_INVALID", str(error))
    if stat.S_ISLNK(normalized_lstat.st_mode) or not stat.S_ISREG(normalized_lstat.st_mode):
        fail(f"{label}_NORMALIZED_REPORT_NOT_REGULAR_NON_SYMLINK")
    if normalized_raw != str(normalized_resolved):
        fail(f"{label}_NORMALIZED_REPORT_PATH_NOT_CANONICAL")
    if original_resolved.read_bytes() != normalized_resolved.read_bytes():
        fail(f"{label}_ORIGINAL_NORMALIZED_BYTES_MISMATCH")

    try:
        report = json.loads(original_resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label}_ORIGINAL_REPORT_JSON_INVALID", str(error))
    if type(report) is not dict or report.get("report_path") != original_raw:
        fail(f"{label}_ORIGINAL_REPORT_PATH_SEMANTIC_MISMATCH")
    return binding, original_resolved


binding_a, original_a = select_one(
    Path(sys.argv[2]), Path(sys.argv[4]), Path(sys.argv[6]), Path(sys.argv[7]), "RUN_A"
)
binding_b, original_b = select_one(
    Path(sys.argv[3]), Path(sys.argv[5]), Path(sys.argv[8]), Path(sys.argv[9]), "RUN_B"
)
if original_a == original_b:
    fail("TWO_RUN_ORIGINAL_REPORT_NOT_DISTINCT")
if binding_a.get("run_id") == binding_b.get("run_id"):
    fail("TWO_RUN_RUN_ID_NOT_DISTINCT")
if binding_a.get("runtime_root") == binding_b.get("runtime_root"):
    fail("TWO_RUN_RUNTIME_ROOT_NOT_DISTINCT")

print(json.dumps({"run_a": str(original_a), "run_b": str(original_b)}, sort_keys=True))
PY
}

run_verify_phase() {
  local step_id=$1
  local run_root=$2
  factory_available "$step_id" || return 0
  local report_path="$run_root/pilot-report.json"
  local binding_path="$run_root/report-binding.json"
  if [[ ! -f "$report_path" || ! -f "$binding_path" ]]; then
    record_missing "$step_id" verify "${step_id}_binding" "${step_id^^}_REPORT_BINDING_MISSING"
    return 0
  fi

  local validation_log="$logs_root/${step_id}_report_binding.log"
  local validation_exit=0
  if python3 "$report_binding_helper" validate-binding \
    --binding "$binding_path" \
    --expected-report "$report_path" \
    --expected-runtime-root "$run_root/runtime" \
    --expected-artifact-root "$run_root/artifacts" >"$validation_log" 2>&1; then
    validation_exit=0
  else
    validation_exit=$?
  fi
  if [[ $validation_exit -ne 0 ]]; then
    cat "$validation_log"
    record_report_helper_result "$step_id" verify "${step_id}_report_binding" "$validation_log" "$validation_exit"
    return 0
  fi
  record_report_helper_result "$step_id" verify "${step_id}_report_binding" "$validation_log" 0

  local manifest_path
  manifest_path=$(json_string_field "$binding_path" manifest_path 2>/dev/null || true)
  if [[ -z "$manifest_path" ]]; then
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
  local run_a_binding="$run_a_root/report-binding.json"
  local run_b_binding="$run_b_root/report-binding.json"
  local two_run_binding="$aggregate_root/two-run-binding.json"
  if [[ ! -f "$run_a_report" || ! -f "$run_b_report" || ! -f "$run_a_binding" || ! -f "$run_b_binding" || ! -f "$doctor_path" || ! -f "$component_summary_path" ]]; then
    record_missing aggregate_release_check aggregate aggregate_release_check AGGREGATE_INPUTS_MISSING
    return 0
  fi

  local binding_log="$logs_root/aggregate_two_run_binding.log"
  local binding_exit=0
  if python3 "$report_binding_helper" validate-two-run \
    --binding-a "$run_a_binding" \
    --binding-b "$run_b_binding" \
    --expected-report-a "$run_a_report" \
    --expected-report-b "$run_b_report" \
    --expected-runtime-root-a "$run_a_root/runtime" \
    --expected-artifact-root-a "$run_a_root/artifacts" \
    --expected-runtime-root-b "$run_b_root/runtime" \
    --expected-artifact-root-b "$run_b_root/artifacts" \
    --output "$two_run_binding" >"$binding_log" 2>&1; then
    binding_exit=0
  else
    binding_exit=$?
  fi
  cat "$binding_log"
  record_report_helper_result aggregate_release_check aggregate aggregate_two_run_binding "$binding_log" "$binding_exit"
  [[ $binding_exit -eq 0 ]] || return 0

  local selection_log="$logs_root/aggregate_original_report_selection.log"
  local selection_exit=0
  if select_original_release_reports \
    "$run_a_binding" "$run_b_binding" \
    "$run_a_report" "$run_b_report" \
    "$run_a_root/runtime" "$run_a_root/artifacts" \
    "$run_b_root/runtime" "$run_b_root/artifacts" >"$selection_log" 2>&1; then
    selection_exit=0
  else
    selection_exit=$?
  fi
  cat "$selection_log"
  record_report_helper_result aggregate_release_check aggregate aggregate_original_report_selection "$selection_log" "$selection_exit"
  [[ $selection_exit -eq 0 ]] || return 0

  local run_a_original_report
  local run_b_original_report
  run_a_original_report=$(json_string_field "$selection_log" run_a 2>/dev/null || true)
  run_b_original_report=$(json_string_field "$selection_log" run_b 2>/dev/null || true)
  if [[ -z "$run_a_original_report" || -z "$run_b_original_report" || "$run_a_original_report" == "$run_b_original_report" ]]; then
    record_missing aggregate_release_check aggregate aggregate_original_report_selection ORIGINAL_REPORT_SELECTION_INVALID
    return 0
  fi
  printf '%s\n' \
    "ORIGINAL_RELEASE_REPORT_SELECTION=PASS" \
    "RUN_A_RELEASE_REPORT_ORIGINAL_PATH=$run_a_original_report" \
    "RUN_B_RELEASE_REPORT_ORIGINAL_PATH=$run_b_original_report" \
    "NORMALIZED_REPORTS_RETAINED_FOR_EVIDENCE=true"

  run_private aggregate_release_check aggregate aggregate_release_check "$private_checkout" \
    "FACTORY_MVP_COMPONENT_TEST_SUMMARY_PATH=$component_summary_path" \
    "FACTORY_MVP_DOCTOR_REPORT_PATH=$doctor_path" \
    "FACTORY_MVP_EVIDENCE_ROOT=$aggregate_root" \
    -- ruby "$factory_bin" release-check --run-1 "$run_a_original_report" --run-2 "$run_b_original_report"
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
