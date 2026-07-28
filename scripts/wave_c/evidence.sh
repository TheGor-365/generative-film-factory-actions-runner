#!/usr/bin/env bash
set -uo pipefail

phase_emit_runtime_evidence() {
  python3 "$helper_path" runtime-seed \
    --work-root "$work_root" \
    --private-repository "$PRIVATE_REPO" \
    --runner-repository "$RUNNER_REPO" \
    --executor-commit "$CHAT5_EXECUTOR_COMMIT" \
    --executor-command "$CHAT5_EXECUTOR_COMMAND" \
    > "$evidence_root/runtime-seed-output.log"

  local seed_path="$evidence_root/actions_runtime_seed.json"
  if [[ ! -f "$seed_path" ]]; then
    policy_error "RUNTIME_SEED_MISSING"
  fi
  local result seed_sha
  result=$(python3 - "$seed_path" <<'PY'
import json
import sys
from pathlib import Path
payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["result"])
PY
)
  seed_sha=$(sha256sum "$seed_path" | awk '{print $1}')
  printf '%s\n' \
    "ACTIONS_RUNTIME_SEED_SCHEMA=factory_actions_evidence_runtime_seed_v01" \
    "ACTIONS_RUNTIME_SEED_SHA256=$seed_sha" \
    "GATE_RESULT=$result" \
    "CHAT5_EXECUTOR_COMMIT=${CHAT5_EXECUTOR_COMMIT:-NOT_BOUND}" \
    "CHAT5_EXECUTOR_COMMAND=$CHAT5_EXECUTOR_COMMAND" \
    "PUBLIC_ARTIFACT_COUNT=0" \
    "CACHE_ACTION_COUNT=0" \
    "NO_FAKE_GREEN=true"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'result=%s\nseed_sha256=%s\n' "$result" "$seed_sha" >> "$GITHUB_OUTPUT"
  fi
}
