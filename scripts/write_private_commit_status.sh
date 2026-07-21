#!/usr/bin/env bash
set -euo pipefail

policy_error() {
  printf '%s\n' "POLICY_ERROR=$1" "NO_WRITE=true" "STABLE_POLICY_ERROR=true"
  exit 2
}

: "${PRIVATE_REPO_API_TOKEN:?PRIVATE_REPO_API_TOKEN is required}"
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"
: "${RESULT:?RESULT is required}"
: "${EXIT_CODE:?EXIT_CODE is required}"
: "${PUBLIC_RUN_ID:?PUBLIC_RUN_ID is required}"
: "${PUBLIC_JOB_ID:?PUBLIC_JOB_ID is required}"
: "${PUBLIC_RUN_URL:?PUBLIC_RUN_URL is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]] || policy_error "PRIVATE_REPO_NOT_ALLOWLISTED"
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]] || policy_error "INVALID_PRIVATE_SHA"
case "$STATUS_CONTEXT" in
  "public-runner/control-center/readonly-validation"|"public-runner/fmr005/repair004-validation") ;;
  *) policy_error "STATUS_CONTEXT_NOT_ALLOWLISTED" ;;
esac
[[ "$EXIT_CODE" =~ ^[0-9]+$ ]] || policy_error "INVALID_EXIT_CODE"
[[ "$PUBLIC_RUN_ID" =~ ^[0-9]+$ ]] || policy_error "INVALID_PUBLIC_RUN_ID"
[[ "$PUBLIC_JOB_ID" == "validate-private-sha" ]] || policy_error "INVALID_PUBLIC_JOB_ID"

case "$RESULT" in
  PASS) state=success ;;
  FAIL) state=failure ;;
  ERROR) state=error ;;
  BLOCKED) state=error ;;
  *) policy_error "INVALID_RESULT" ;;
esac

payload=$(python - \
  "$state" "$STATUS_CONTEXT" "$RESULT" "$EXIT_CODE" "$PUBLIC_RUN_ID" \
  "$PUBLIC_JOB_ID" "$PUBLIC_RUN_URL" <<'PY'
import json
import sys

state, context, result, exit_code, run_id, job_id, target_url = sys.argv[1:]
print(json.dumps({
    "state": state,
    "context": context,
    "description": f"runner {result}; job={job_id}; run={run_id}; exit={exit_code}; artifacts=0",
    "target_url": target_url,
}, separators=(",", ":")))
PY
)

curl --fail --silent --show-error \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${PRIVATE_REPO_API_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "$payload" \
  "https://api.github.com/repos/${PRIVATE_REPO}/statuses/${PRIVATE_SHA}" \
  >/dev/null

printf '%s\n' \
  "COMMIT_STATUS_WRITEBACK=PASS" \
  "PUBLIC_RUN_ID=$PUBLIC_RUN_ID" \
  "PUBLIC_JOB_ID=$PUBLIC_JOB_ID" \
  "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false"
