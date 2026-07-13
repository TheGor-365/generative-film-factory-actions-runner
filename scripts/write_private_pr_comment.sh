#!/usr/bin/env bash
set -euo pipefail

policy_error() {
  printf '%s\n' "POLICY_ERROR=$1" "NO_WRITE=true" "STABLE_POLICY_ERROR=true"
  exit 2
}

: "${PRIVATE_REPO_API_TOKEN:?PRIVATE_REPO_API_TOKEN is required}"
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_BRANCH:?PRIVATE_BRANCH is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${PRIVATE_PR:?PRIVATE_PR is required}"
: "${GATE_ID:?GATE_ID is required}"
: "${VALIDATOR_SET:?VALIDATOR_SET is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"
: "${RESULT:?RESULT is required}"
: "${EXIT_CODE:?EXIT_CODE is required}"
: "${PUBLIC_RUN_ID:?PUBLIC_RUN_ID is required}"
: "${PUBLIC_JOB_ID:?PUBLIC_JOB_ID is required}"
: "${PUBLIC_RUN_URL:?PUBLIC_RUN_URL is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || policy_error "PRIVATE_REPO_NOT_ALLOWLISTED"
[[ "$PRIVATE_BRANCH" == "main" ]] || policy_error "PRIVATE_BRANCH_NOT_ALLOWLISTED"
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_PRIVATE_SHA"
[[ "$PRIVATE_PR" =~ ^[1-9][0-9]*$ ]] || policy_error "INVALID_PRIVATE_PR"
[[ "$GATE_ID" == "CONTROL_CENTER_READONLY_VALIDATION_v02" ]] || policy_error "GATE_NOT_ALLOWLISTED"
[[ "$VALIDATOR_SET" == "control_center_readonly_v02" ]] || policy_error "VALIDATOR_SET_NOT_ALLOWLISTED"
[[ "$STATUS_CONTEXT" == "public-runner/control-center/readonly-validation" ]] || policy_error "STATUS_CONTEXT_NOT_ALLOWLISTED"
[[ "$EXIT_CODE" =~ ^[0-9]+$ ]] || policy_error "INVALID_EXIT_CODE"
[[ "$PUBLIC_RUN_ID" =~ ^[0-9]+$ ]] || policy_error "INVALID_PUBLIC_RUN_ID"
[[ "$PUBLIC_JOB_ID" == "validate-private-sha" ]] || policy_error "INVALID_PUBLIC_JOB_ID"

case "$RESULT" in
  PASS|FAIL|ERROR|BLOCKED) ;;
  *) policy_error "INVALID_RESULT" ;;
esac

pr_response_file="$(mktemp)"
trap 'rm -f -- "$pr_response_file"' EXIT

if curl --fail --silent --show-error \
  --request GET \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${PRIVATE_REPO_API_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --output "$pr_response_file" \
  "https://api.github.com/repos/${PRIVATE_REPO}/pulls/${PRIVATE_PR}"
then
  pr_lookup_exit=0
else
  pr_lookup_exit=$?
fi
if [[ $pr_lookup_exit -ne 0 ]]; then
  policy_error "PRIVATE_PR_LOOKUP_FAILED"
fi

if python - "$pr_response_file" "$PRIVATE_PR" "$PRIVATE_SHA" <<'PY'
import json
import sys
from pathlib import Path

response_path, expected_number, expected_sha = sys.argv[1:]
try:
    pull_request = json.loads(Path(response_path).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    print("POLICY_ERROR=INVALID_PRIVATE_PR_RESPONSE")
    print("NO_WRITE=true")
    print("STABLE_POLICY_ERROR=true")
    raise SystemExit(2)

head = pull_request.get("head") if isinstance(pull_request, dict) else None
if (
    not isinstance(pull_request, dict)
    or pull_request.get("number") != int(expected_number)
    or not isinstance(head, dict)
    or not isinstance(head.get("sha"), str)
):
    print("POLICY_ERROR=INVALID_PRIVATE_PR_RESPONSE")
    print("NO_WRITE=true")
    print("STABLE_POLICY_ERROR=true")
    raise SystemExit(2)

if head["sha"] != expected_sha:
    print("POLICY_ERROR=PRIVATE_PR_HEAD_SHA_MISMATCH")
    print("NO_WRITE=true")
    print("STABLE_POLICY_ERROR=true")
    raise SystemExit(2)
PY
then
  pr_binding_exit=0
else
  pr_binding_exit=$?
fi
if [[ $pr_binding_exit -ne 0 ]]; then
  exit "$pr_binding_exit"
fi

payload=$(python - \
  "$PRIVATE_REPO" "$PRIVATE_BRANCH" "$PRIVATE_SHA" "$GATE_ID" "$VALIDATOR_SET" \
  "$RESULT" "$EXIT_CODE" "$STATUS_CONTEXT" "$PUBLIC_RUN_ID" "$PUBLIC_JOB_ID" \
  "$PUBLIC_RUN_URL" <<'PY'
import json
import sys

(
    private_repo,
    private_branch,
    private_sha,
    gate_id,
    validator_set,
    result,
    exit_code,
    status_context,
    public_run_id,
    public_job_id,
    public_run_url,
) = sys.argv[1:]
body = "\n".join([
    "PUBLIC_RUNNER_EVIDENCE=true",
    "PUBLIC_RUNNER_REPO=TheGor-365/generative-film-factory-actions-runner",
    f"PUBLIC_RUN_ID={public_run_id}",
    f"PUBLIC_JOB_ID={public_job_id}",
    f"PRIVATE_REPO={private_repo}",
    f"PRIVATE_BRANCH={private_branch}",
    f"PRIVATE_SHA={private_sha}",
    f"GATE_ID={gate_id}",
    f"VALIDATOR_SET={validator_set}",
    f"RESULT={result}",
    f"EXIT_CODE={exit_code}",
    f"STATUS_CONTEXT={status_context}",
    "PUBLIC_ARTIFACT_COUNT=0",
    "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false",
    "NO_FAKE_GREEN=true",
    f"PUBLIC_RUN_URL={public_run_url}",
])
print(json.dumps({"body": body}, separators=(",", ":")))
PY
)

curl --fail --silent --show-error \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${PRIVATE_REPO_API_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "$payload" \
  "https://api.github.com/repos/${PRIVATE_REPO}/issues/${PRIVATE_PR}/comments" \
  >/dev/null

printf '%s\n' \
  "PR_COMMENT_WRITEBACK=PASS" \
  "PUBLIC_RUN_ID=$PUBLIC_RUN_ID" \
  "PUBLIC_JOB_ID=$PUBLIC_JOB_ID" \
  "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false"
