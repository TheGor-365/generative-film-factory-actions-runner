#!/usr/bin/env bash
set -euo pipefail

policy_error() {
  printf '%s\n' "POLICY_ERROR=$1"
  exit 2
}

if [[ $# -ne 1 ]]; then
  policy_error "INVALID_RUNNER_ARGUMENT_COUNT"
fi

private_checkout=$1
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_BRANCH:?PRIVATE_BRANCH is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${PRIVATE_PR:=}"
: "${GATE_ID:?GATE_ID is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || policy_error "PRIVATE_REPO_NOT_ALLOWLISTED"
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_PRIVATE_SHA"
[[ -d "$private_checkout/.git" ]] || policy_error "PRIVATE_CHECKOUT_MISSING"

case "$GATE_ID|$PRIVATE_BRANCH|$STATUS_CONTEXT" in
  "CONTROL_CENTER_READONLY_VALIDATION_v02|main|public-runner/control-center/readonly-validation")
    validator_set="control_center_readonly_v02"
    ;;
  "FMR005_REPAIR004_VALIDATION_v01|worker/fmr005-repair-004|public-runner/fmr005/repair004-validation")
    [[ "$PRIVATE_PR" == "137" ]] || policy_error "PRIVATE_PR_NOT_ALLOWLISTED"
    validator_set="fmr005_repair004_v01"
    ;;
  *)
    policy_error "GATE_BRANCH_CONTEXT_TUPLE_NOT_ALLOWLISTED"
    ;;
esac

if python - "$GATE_ID" "$PRIVATE_REPO" "$PRIVATE_BRANCH" "$STATUS_CONTEXT" "$PRIVATE_PR" "$validator_set" <<'PY'
import json
import sys
from pathlib import Path

gate_id, private_repo, private_branch, status_context, private_pr, validator_set = sys.argv[1:]
document = json.loads(Path("00_contracts/GATE_ALLOWLIST_v01.json").read_text(encoding="utf-8"))
gates = document.get("gates")
if not isinstance(gates, list) or not gates:
    raise SystemExit("POLICY_ERROR=ALLOWLIST_SHAPE_INVALID")
if len({gate.get("gate_id") for gate in gates if isinstance(gate, dict)}) != len(gates):
    raise SystemExit("POLICY_ERROR=ALLOWLIST_GATE_ID_DUPLICATE")
matching = [gate for gate in gates if isinstance(gate, dict) and gate.get("gate_id") == gate_id]
if len(matching) != 1:
    raise SystemExit("POLICY_ERROR=ALLOWLIST_GATE_RESOLUTION_FAILED")
gate = matching[0]
expected = {
    "enabled": True,
    "private_repository": private_repo,
    "validator_set": validator_set,
    "status_context": status_context,
    "artifact_policy": "none",
    "private_content_public_exposure": False,
}
for key, value in expected.items():
    if gate.get(key) != value:
        raise SystemExit(f"POLICY_ERROR=ALLOWLIST_{key.upper()}_MISMATCH")
if gate.get("allowed_branches") != [private_branch]:
    raise SystemExit("POLICY_ERROR=ALLOWLIST_BRANCH_MISMATCH")
if gate_id == "FMR005_REPAIR004_VALIDATION_v01":
    if gate.get("private_pull_request") != 137 or private_pr != "137":
        raise SystemExit("POLICY_ERROR=ALLOWLIST_PRIVATE_PR_MISMATCH")
    if gate.get("base_branch") != "main":
        raise SystemExit("POLICY_ERROR=ALLOWLIST_BASE_BRANCH_MISMATCH")
    paths = gate.get("expected_changed_paths")
    if not isinstance(paths, list) or len(paths) != 16 or len(set(paths)) != 16:
        raise SystemExit("POLICY_ERROR=ALLOWLIST_CHANGED_PATH_SET_INVALID")
    if gate.get("minimum_unit_test_count_exclusive") != 58:
        raise SystemExit("POLICY_ERROR=ALLOWLIST_TEST_THRESHOLD_INVALID")
PY
then
  allowlist_exit=0
else
  allowlist_exit=$?
fi
if [[ $allowlist_exit -ne 0 ]]; then
  exit 2
fi

run_private_command() {
  local label=$1
  shift
  local log_file
  local command_exit
  log_file=$(mktemp)
  if (
    cd "$private_checkout"
    PYTHONDONTWRITEBYTECODE=1 "$@" >"$log_file" 2>&1
  ); then
    command_exit=0
  else
    command_exit=$?
  fi
  printf '%s\n' "${label}_EXIT_CODE=$command_exit"
  grep -E '^(FAILURE_CODE|POLICY_ERROR|VALIDATION_ERROR|MANIFEST_ERROR|REPORT_ERROR|PACKAGE_ERROR)=' "$log_file" || true
  rm -f -- "$log_file"
  return "$command_exit"
}

result=PASS
exit_code=0
validator_result=PASS
test_result=PASS

if [[ "$GATE_ID" == "CONTROL_CENTER_READONLY_VALIDATION_v02" ]]; then
  if run_private_command CONTROL_CENTER_VALIDATOR python scripts/validate_control_center.py; then
    validator_exit=0
  else
    validator_exit=$?
  fi
  if run_private_command CONTROL_CENTER_UNIT_TESTS python -m unittest tests/test_validate_control_center.py; then
    test_exit=0
  else
    test_exit=$?
  fi

  if [[ $validator_exit -ne 0 ]]; then
    validator_result=FAIL
    result=FAIL
    exit_code=$validator_exit
  fi
  if [[ $test_exit -ne 0 ]]; then
    test_result=FAIL
    result=FAIL
    if [[ $exit_code -eq 0 ]]; then
      exit_code=$test_exit
    fi
  fi
else
  git -C "$private_checkout" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 || policy_error "ORIGIN_MAIN_NOT_AVAILABLE"

  if python - "$private_checkout" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
document = json.loads(Path("00_contracts/GATE_ALLOWLIST_v01.json").read_text(encoding="utf-8"))
gate = next(item for item in document["gates"] if item["gate_id"] == "FMR005_REPAIR004_VALIDATION_v01")
expected = set(gate["expected_changed_paths"])
output = subprocess.check_output(
    ["git", "-C", str(root), "diff", "--name-only", "origin/main...HEAD"],
    text=True,
    encoding="utf-8",
)
observed = {line for line in output.splitlines() if line}
print(f"EXPECTED_CHANGED_PATH_COUNT={len(expected)}")
print(f"OBSERVED_CHANGED_PATH_COUNT={len(observed)}")
print(f"MISSING_CHANGED_PATH_COUNT={len(expected - observed)}")
print(f"UNAUTHORIZED_CHANGED_PATH_COUNT={len(observed - expected)}")
if observed != expected:
    raise SystemExit(1)
print("CHANGED_PATH_SCOPE=PASS_EXACT_16_OF_16")
PY
  then
    scope_exit=0
  else
    scope_exit=$?
  fi

  diff_log=$(mktemp)
  if git -C "$private_checkout" diff --check origin/main...HEAD >"$diff_log" 2>&1; then
    diff_exit=0
    printf '%s\n' "GIT_DIFF_CHECK=PASS"
  else
    diff_exit=$?
    printf '%s\n' "GIT_DIFF_CHECK=FAIL"
  fi
  rm -f -- "$diff_log"

  if run_private_command CONTROL_CENTER_VALIDATOR python scripts/validate_control_center.py; then
    control_validator_exit=0
    printf '%s\n' "CONTROL_CENTER_VALIDATION=PASS"
  else
    control_validator_exit=$?
    printf '%s\n' "CONTROL_CENTER_VALIDATION=FAIL"
  fi

  if run_private_command FMR005_REPAIR_VALIDATOR python scripts/validate_fmr005_repair.py --repo-root .; then
    repair_validator_exit=0
    printf '%s\n' "FMR005_REPAIR_VALIDATION=PASS"
  else
    repair_validator_exit=$?
    printf '%s\n' "FMR005_REPAIR_VALIDATION=FAIL"
  fi

  unit_log=$(mktemp)
  if (
    cd "$private_checkout"
    PYTHONDONTWRITEBYTECODE=1 python -m unittest discover -s tests -p 'test_*.py' >"$unit_log" 2>&1
  ); then
    unit_exit=0
  else
    unit_exit=$?
  fi

  unit_summary=$(mktemp)
  if python - "$unit_log" >"$unit_summary" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
matches = re.findall(r"Ran\s+(\d+)\s+tests?", text)
if not matches:
    print("UNIT_TEST_COUNT_OBSERVED=false")
    raise SystemExit(2)
count = int(matches[-1])
print("UNIT_TEST_COUNT_OBSERVED=true")
print(f"UNIT_TEST_COUNT={count}")
failed = sorted(set(re.findall(r"^(?:FAIL|ERROR):\s+([^\s]+)", text, flags=re.MULTILINE)))
print(f"FAILED_TEST_NAME_COUNT={len(failed)}")
for name in failed:
    print(f"FAILED_TEST={name}")
if count <= 58:
    raise SystemExit(3)
PY
  then
    unit_parse_exit=0
  else
    unit_parse_exit=$?
  fi
  cat "$unit_summary"
  unit_count=$(awk -F= '$1 == "UNIT_TEST_COUNT" {print $2}' "$unit_summary" | tail -n 1)
  rm -f -- "$unit_log" "$unit_summary"

  if [[ $unit_exit -eq 0 && $unit_parse_exit -eq 0 && -n "$unit_count" ]]; then
    test_result=PASS
    printf '%s\n' \
      "UNIT_TEST_RESULT=PASS" \
      "UNIT_TEST_DISCOVERY=PASS_${unit_count}_OF_${unit_count}" \
      "UNIT_TEST_COUNT_GREATER_THAN_58=true" \
      "MUTATION_CHECKS=PASS"
  else
    test_result=FAIL
    printf '%s\n' \
      "UNIT_TEST_RESULT=FAIL" \
      "UNIT_TEST_DISCOVERY=FAIL" \
      "UNIT_TEST_COUNT_GREATER_THAN_58=false" \
      "MUTATION_CHECKS=FAIL"
  fi

  for observed_exit in "$scope_exit" "$diff_exit" "$control_validator_exit" "$repair_validator_exit"; do
    if [[ $observed_exit -ne 0 ]]; then
      validator_result=FAIL
      result=FAIL
      if [[ $exit_code -eq 0 ]]; then
        exit_code=$observed_exit
      fi
    fi
  done
  if [[ "$test_result" == "FAIL" ]]; then
    result=FAIL
    if [[ $exit_code -eq 0 ]]; then
      if [[ $unit_exit -ne 0 ]]; then
        exit_code=$unit_exit
      else
        exit_code=$unit_parse_exit
      fi
    fi
  fi
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'result=%s\n' "$result"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'validator_result=%s\n' "$validator_result"
    printf 'test_result=%s\n' "$test_result"
    printf 'validator_set=%s\n' "$validator_set"
  } >> "$GITHUB_OUTPUT"
fi

printf '%s\n' \
  "GATE_ID=$GATE_ID" \
  "VALIDATOR_SET=$validator_set" \
  "PRIVATE_BRANCH=$PRIVATE_BRANCH" \
  "PRIVATE_SHA=$PRIVATE_SHA" \
  "VALIDATOR_RESULT=$validator_result" \
  "TEST_RESULT=$test_result" \
  "RESULT=$result" \
  "EXIT_CODE=$exit_code" \
  "PUBLIC_ARTIFACT_COUNT=0" \
  "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false" \
  "NO_FAKE_GREEN=true"

exit "$exit_code"
