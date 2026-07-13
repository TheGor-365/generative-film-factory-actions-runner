#!/usr/bin/env bash
set -euo pipefail

: "${PRIVATE_REPO_API_TOKEN:?PRIVATE_REPO_API_TOKEN is required}"
: "${PRIVATE_REPO:?PRIVATE_REPO is required}"
: "${PRIVATE_SHA:?PRIVATE_SHA is required}"
: "${STATUS_CONTEXT:?STATUS_CONTEXT is required}"
: "${RESULT:?RESULT is required}"
: "${EXIT_CODE:?EXIT_CODE is required}"
: "${PUBLIC_RUN_ID:?PUBLIC_RUN_ID is required}"
: "${PUBLIC_RUN_URL:?PUBLIC_RUN_URL is required}"

[[ "$PRIVATE_REPO" == "TheGor-365/generative-film-factory-control-center" ]]
[[ "$PRIVATE_SHA" =~ ^[0-9a-f]{40}$ ]]
[[ "$STATUS_CONTEXT" == "public-runner/control-center/readonly-validation" ]]
[[ "$EXIT_CODE" =~ ^[0-9]+$ ]]
[[ "$PUBLIC_RUN_ID" =~ ^[0-9]+$ ]]

case "$RESULT" in
  PASS) state=success ;;
  FAIL) state=failure ;;
  ERROR) state=error ;;
  *) printf '%s\n' "POLICY_ERROR=INVALID_RESULT"; exit 2 ;;
esac

payload=$(python - "$state" "$STATUS_CONTEXT" "$RESULT" "$EXIT_CODE" "$PUBLIC_RUN_URL" <<'PY'
import json
import sys

state, context, result, exit_code, target_url = sys.argv[1:]
print(json.dumps({
    "state": state,
    "context": context,
    "description": f"public runner {result}; exit={exit_code}; artifacts=0",
    "target_url": target_url,
}, separators=(",", ":")))
PY
)

curl --fail-with-body --silent --show-error \
  --request POST \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${PRIVATE_REPO_API_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  --data "$payload" \
  "https://api.github.com/repos/${PRIVATE_REPO}/statuses/${PRIVATE_SHA}" \
  >/dev/null

printf '%s\n' "COMMIT_STATUS_WRITEBACK=PASS" "PRIVATE_CONTENT_PUBLIC_EXPOSURE=false"
