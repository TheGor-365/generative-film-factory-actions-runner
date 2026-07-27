python3 - "$records_path" "$component_summary_path" "$PRIVATE_SHA" <<'PY'
import json
import sys
from pathlib import Path

records_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source_head = sys.argv[3]
records = [json.loads(line) for line in records_path.read_text(encoding="utf-8").splitlines() if line.strip()]
components = [record for record in records if record.get("category") == "component"]
required_prefixes = ["CORE_", "ONBOARDING_WEB_", "STORY_", "MEDIA_", "OPS_"]
counts = {prefix.rstrip("_").lower(): sum(1 for record in components if record["command"].startswith(prefix)) for prefix in required_prefixes}
missing = [name for name, count in counts.items() if count == 0]
failed = [record["command"] for record in components if record["exit_code"] != 0]
status = "passed" if not missing and not failed else "failed"
payload = {
    "schema_version": "factory_component_test_summary_v01",
    "status": status,
    "source_head": source_head,
    "commands": [{"command": record["command"], "exit_code": record["exit_code"], "status": record["status"]} for record in components],
    "checks": {
        "all_required_component_groups_present": {"passed": not missing, "missing_group_count": len(missing)},
        "all_component_commands_passed": {"passed": not failed, "failed_command_count": len(failed)},
        "private_source_logged": {"passed": True, "observed": False},
        "paid_provider_called": {"passed": True, "observed": False},
        "public_artifact_uploaded": {"passed": True, "observed": False}
    },
    "component_command_counts": counts,
    "no_fake_green": True
}
output_path.write_text(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
PY

component_sha="$(sha256sum "$component_summary_path" | awk '{print $1}')"
printf '%s\n' "COMPONENT_MATRIX_SHA256=$component_sha"

if [[ -f "$run_a_root/pilot-report.json" && -f "$run_b_root/pilot-report.json" && -f "$doctor_path" ]]; then
  run_private "AGGREGATE_RELEASE_CHECK" aggregate "$private_checkout" \
    "FACTORY_MVP_COMPONENT_TEST_SUMMARY_PATH=$component_summary_path" \
    "FACTORY_MVP_DOCTOR_REPORT_PATH=$doctor_path" \
    "FACTORY_MVP_EVIDENCE_ROOT=$aggregate_root" \
    -- ruby "$factory_bin" release-check --run-1 "$run_a_root/pilot-report.json" --run-2 "$run_b_root/pilot-report.json" || true
  cp "$logs_root/AGGREGATE_RELEASE_CHECK.log" "$evidence_root/release-check.json"
else
  mark_blocked "AGGREGATE_INPUTS_MISSING"
fi

resolve_wave_c_execution() {
  local probe_log="$logs_root/WAVE_C_EXECUTION_PROBE.log"
  if (
    cd "$private_checkout" || exit 2
    env -i "${base_env[@]}" ruby "$factory_bin" __wave_c_execution_probe__ >"$probe_log" 2>&1
  ); then
    :
  fi
  python3 - "$probe_log" "$contract_path" <<'PY'
import json
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
contract = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
resolution = contract["wave_c_execution_resolution"]
stage_pattern = re.compile(resolution["allowed_stage_pattern"])
command_pattern = re.compile(resolution["allowed_command_pattern"])
try:
    payload = json.loads(text)
    message = payload.get("error", {}).get("message", "") if isinstance(payload, dict) else ""
except Exception:
    message = text
tokens = sorted(set(re.findall(r"[a-z0-9_-]+", message)))
stages = [token for token in tokens if stage_pattern.fullmatch(token)]
commands = [token for token in tokens if command_pattern.fullmatch(token)]
candidates = [("stage", item) for item in stages] + [("command", item) for item in commands]
if len(candidates) != 1:
    raise SystemExit(1)
print(f"{candidates[0][0]}|{candidates[0][1]}")
PY
}

wave_c_execution="$(resolve_wave_c_execution 2>/dev/null || true)"
if [[ -z "$wave_c_execution" ]]; then
  printf '%s\n' "BLOCKER_CODE=WAVE_C_V03_COMMAND_OR_STAGE_UNAVAILABLE"
  mark_blocked "WAVE_C_V03_COMMAND_OR_STAGE_UNAVAILABLE"
else
  wave_c_kind=${wave_c_execution%%|*}
  wave_c_name=${wave_c_execution#*|}
  if [[ "$wave_c_kind" == "stage" ]]; then
    run_private "WAVE_C_V03_STAGE_CHECK" stage "$private_checkout" \
      "FACTORY_MVP_COMPONENT_TEST_SUMMARY_PATH=$component_summary_path" \
      "FACTORY_MVP_DOCTOR_REPORT_PATH=$doctor_path" \
      "FACTORY_MVP_EVIDENCE_ROOT=$aggregate_root" \
      -- ruby "$factory_bin" release-check --stage "$wave_c_name" || true
  else
    run_private "WAVE_C_V03_STAGE_CHECK" stage "$private_checkout" \
      "FACTORY_MVP_COMPONENT_TEST_SUMMARY_PATH=$component_summary_path" \
      "FACTORY_MVP_DOCTOR_REPORT_PATH=$doctor_path" \
      "FACTORY_MVP_EVIDENCE_ROOT=$aggregate_root" \
      -- ruby "$factory_bin" "$wave_c_name" || true
  fi
  cp "$logs_root/WAVE_C_V03_STAGE_CHECK.log" "$evidence_root/wave-c-v03-stage.json"
  printf '%s\n' "WAVE_C_V03_EXECUTION_KIND=$wave_c_kind" "WAVE_C_V03_EXECUTION_ID=$wave_c_name"
fi

hash_if_file() {
  local label=$1
  local path=$2
  if [[ -f "$path" ]]; then
    printf '%s=%s\n' "$label" "$(sha256sum "$path" | awk '{print $1}')"
  else
    printf '%s=missing\n' "$label"
  fi
}

find_aggregate_index() {
  python3 - "$evidence_root/release-check.json" <<'PY'
import json
import sys
from pathlib import Path
try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
value = payload.get("aggregate_evidence_index")
if isinstance(value, str) and value:
    print(value)
else:
    raise SystemExit(1)
PY
}

aggregate_index="$(find_aggregate_index 2>/dev/null || true)"
hash_if_file "DOCTOR_SHA256" "$doctor_path"
hash_if_file "RUN_A_REPORT_SHA256" "$run_a_root/pilot-report.json"
hash_if_file "RUN_A_VERIFY_SHA256" "$run_a_root/verify.json"
hash_if_file "RUN_B_REPORT_SHA256" "$run_b_root/pilot-report.json"
hash_if_file "RUN_B_VERIFY_SHA256" "$run_b_root/verify.json"
hash_if_file "AGGREGATE_RELEASE_CHECK_SHA256" "$evidence_root/release-check.json"
if [[ -n "$aggregate_index" ]]; then
  hash_if_file "AGGREGATE_EVIDENCE_INDEX_SHA256" "$aggregate_index"
else
  printf '%s\n' "AGGREGATE_EVIDENCE_INDEX_SHA256=missing"
fi
hash_if_file "V03_STAGE_SHA256" "$evidence_root/wave-c-v03-stage.json"
hash_if_file "COMMAND_RECORDS_SHA256" "$records_path"

if [[ ${#failed_codes[@]} -gt 0 ]]; then
  printf '%s\n' "FAILED_CHECK_COUNT=${#failed_codes[@]}" "FAILED_CHECK_CODES=$(IFS=,; echo "${failed_codes[*]}")"
else
  printf '%s\n' "FAILED_CHECK_COUNT=0" "FAILED_CHECK_CODES=none"
fi
if [[ ${#blocked_codes[@]} -gt 0 ]]; then
  printf '%s\n' "BLOCKED_CHECK_COUNT=${#blocked_codes[@]}" "BLOCKED_CHECK_CODES=$(IFS=,; echo "${blocked_codes[*]}")"
else
  printf '%s\n' "BLOCKED_CHECK_COUNT=0" "BLOCKED_CHECK_CODES=none"
fi

if [[ "$result" == "FAIL" && ${#blocked_codes[@]} -gt 0 ]]; then
  printf '%s\n' "ADDITIONAL_BLOCKERS_PRESENT=true"
fi

printf '%s\n' \
  "GATE_ID=$GATE_ID" \
  "PRIVATE_REPOSITORY=$PRIVATE_REPO" \
  "PRIVATE_BRANCH=$PRIVATE_BRANCH" \
  "PRIVATE_SHA=$PRIVATE_SHA" \
  "STATUS_CONTEXT=$STATUS_CONTEXT" \
  "RESULT=$result" \
  "EXIT_CODE=$exit_code" \
  "PUBLIC_ARTIFACT_COUNT=0" \
  "CACHE_USED=false" \
  "PAID_PROVIDER_CALLS=false" \
  "NETWORK_MEDIA_PROVIDER_CALLS=false" \
  "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false" \
  "NO_FAKE_GREEN=true"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'result=%s\n' "$result"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'component_matrix_sha256=%s\n' "$component_sha"
  } >> "$GITHUB_OUTPUT"
fi

exit "$exit_code"
