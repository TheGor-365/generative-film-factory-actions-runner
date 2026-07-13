#!/usr/bin/env bash
set -euo pipefail

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
: "${PUBLIC_RUN_URL:?PUBLIC_RUN_URL is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]]
[[ "$PRIVATE_BRANCH" == "main" ]]
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$PRIVATE_PR" =~ ^[1-9][0-9]*$ ]]
[[ "$GATE_ID" == "CONTROL_CENTER_READONLY_VALIDATION_v02" ]]
[[ "$VALIDATOR_SET" == "control_center_readonly_v02" ]]
[[ "$STATUS_CONTEXT" == "public-runner/control-center/readonly-validation" ]]
[[ "$RESULT" =~ ^(PASS|FAIL|ERROR)$ ]]
[[ "$EXIT_CODE" =~ ^[0-9]+$ ]]
[[ "$PUBLIC_RUN_ID" =~ ^[0-9]+$ ]]

payload=$(python - \
  "$PRIVATE_REPO" "$PRIVATE_BRANCH" "$PRIVATE_SHA" "$GATE_ID" "$VALIDATOR_SET" \
  "$RESULT" "$EXIT_CODE" "$STATUS_CONTEXT" "$PUBLIC_RUN_ID" "$PUBLIC_RUN_URL" <<'PY'
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
    public_run_url,
) = sys.argv[1:]
body = "\n".join([
    "PUBLIC_RUNNER_EVIDENCE=true",
    "PUBLIC_RUNNER_REPO=TheGor-365/generative-film-factory-actions-runner",
    f"PUBLIC_RUN_ID={public_run_id}",
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

curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${PRIVATE_REPO_API_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "$payload" \
  "https://api.github.com/repos/${PRIVATE_REPO}/issues/${PRIVATE_PR}/comments" \
  >/dev/null

printf '%s\n' "PR_COMMENT_WRITEBACK=PASS" "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false"
