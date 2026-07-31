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

  local run_a_binding="$run_a_root/report-binding.json"
  local run_b_binding="$run_b_root/report-binding.json"
  local two_run_binding="$aggregate_root/two-run-binding.json"
  if [[ -f "$run_a_binding" && -f "$run_b_binding" && -f "$two_run_binding" ]]; then
    python3 "$report_binding_helper" augment-runtime-seed \
      --seed "$seed_path" \
      --binding-a "$run_a_binding" \
      --binding-b "$run_b_binding" \
      --two-run-binding "$two_run_binding" \
      --expected-report-a "$run_a_root/pilot-report.json" \
      --expected-report-b "$run_b_root/pilot-report.json" \
      --expected-runtime-root-a "$run_a_root/runtime" \
      --expected-artifact-root-a "$run_a_root/artifacts" \
      --expected-runtime-root-b "$run_b_root/runtime" \
      --expected-artifact-root-b "$run_b_root/artifacts" \
      > "$evidence_root/runtime-report-binding-output.log"
    cat "$evidence_root/runtime-report-binding-output.log"
  else
    printf '%s\n' "RUNTIME_SEED_REPORT_BINDINGS=NOT_AVAILABLE" "NO_FAKE_GREEN=true"
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
