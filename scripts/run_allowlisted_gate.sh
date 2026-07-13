#!/usr/bin/env bash
set -uo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' "POLICY_ERROR=INVALID_RUNNER_ARGUMENT_COUNT"
  exit 2
fi

private_checkout=$1
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_BRANCH:?PRIVATE_BRANCH is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${GATE_ID:?GATE_ID is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || exit 2
[[ "$PRIVATE_BRANCH" == "main" ]] || exit 2
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$GATE_ID" == "CONTROL_CENTER_READONLY_VALIDATION_v02" ]] || exit 2
[[ "$STATUS_CONTEXT" == "public-runner/control-center/readonly-validation" ]] || exit 2
[[ -d "$private_checkout/.git" ]] || exit 2

python - "$GATE_ID" "$PRIVATE_REPO" "$PRIVATE_BRANCH" "$STATUS_CONTEXT" <<'PY'
import json
import sys
from pathlib import Path

gate_id, private_repo, private_branch, status_context = sys.argv[1:]
document = json.loads(Path("00_contracts/GATE_ALLOWLIST_v01.json").read_text(encoding="utf-8"))
gates = document.get("gates")
if not isinstance(gates, list) or len(gates) != 1:
    raise SystemExit("POLICY_ERROR=ALLOWLIST_SHAPE_INVALID")
gate = gates[0]
expected = {
    "gate_id": gate_id,
    "private_repository": private_repo,
    "validator_set": "control_center_readonly_v02",
    "status_context": status_context,
    "artifact_policy": "none",
}
for key, value in expected.items():
    if gate.get(key) != value:
        raise SystemExit(f"POLICY_ERROR=ALLOWLIST_{key.upper()}_MISMATCH")
if gate.get("allowed_branches") != [private_branch]:
    raise SystemExit("POLICY_ERROR=ALLOWLIST_BRANCH_MISMATCH")
if gate.get("private_content_public_exposure") is not False:
    raise SystemExit("POLICY_ERROR=PRIVATE_CONTENT_POLICY_INVALID")
PY
allowlist_exit=$?
if [[ $allowlist_exit -ne 0 ]]; then
  exit 2
fi

validator_exit=0
test_exit=0

(
  cd "$private_checkout" || exit 2
  PYTHONDONTWRITEBYTECODE=1 python scripts/validate_control_center.py
) || validator_exit=$?

(
  cd "$private_checkout" || exit 2
  PYTHONDONTWRITEBYTECODE=1 python -m unittest tests/test_validate_control_center.py
) || test_exit=$?

validator_result=PASS
test_result=PASS
result=PASS
exit_code=0

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

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'result=%s\n' "$result"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'validator_result=%s\n' "$validator_result"
    printf 'test_result=%s\n' "$test_result"
    printf 'validator_set=%s\n' "control_center_readonly_v02"
  } >> "$GITHUB_OUTPUT"
fi

printf '%s\n' \
  "GATE_ID=CONTROL_CENTER_READONLY_VALIDATION_v02" \
  "VALIDATOR_SET=control_center_readonly_v02" \
  "PRIVATE_SHA=$PRIVATE_SHA" \
  "VALIDATOR_RESULT=$validator_result" \
  "TEST_RESULT=$test_result" \
  "RESULT=$result" \
  "EXIT_CODE=$exit_code" \
  "PUBLIC_ARTIFACT_COUNT=0" \
  "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false" \
  "NO_FAKE_GREEN=true"

exit "$exit_code"
