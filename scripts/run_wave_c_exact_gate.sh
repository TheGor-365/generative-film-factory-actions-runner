#!/usr/bin/env bash
set -euo pipefail
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_root/wave_c/lib.sh" "$@"
source "$script_root/wave_c/components.sh"
source "$script_root/wave_c/runtime.sh"
source "$script_root/wave_c/evidence.sh"

phase_initialize_one_click() {
  python3 - "$contract_path" "$PRIVATE_SHA" <<'PY'
import json
import sys
from pathlib import Path

contract = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
private_sha = sys.argv[2]
expected = {
    "gate_id": "GFF_WAVE_C_G1_V03_VALIDATION_v01",
    "private_repository": "TheGor-365/generative-film-factory-control-center",
    "allowed_branch": "main",
    "status_context": "public-runner/gff/wave-c-validation",
    "workflow_inputs": [],
    "pinned_private_sha": private_sha,
    "private_sha_source": "source_controlled_fixed_value",
    "arbitrary_shell_allowed": False,
    "public_artifact_upload": False,
    "cache": False,
    "paid_provider_calls": False,
    "network_media_provider_calls": False,
    "no_fake_green": True,
}
for key, value in expected.items():
    if contract.get(key) != value:
        raise SystemExit(f"POLICY_ERROR=CONTRACT_{key.upper()}_MISMATCH")
print("FIXED_ONE_CLICK_DISPATCH_POLICY=PASS")
PY
  [[ "$(git rev-parse HEAD 2>/dev/null || true)" == "$RUNNER_SHA" ]] || policy_error "PUBLIC_RUNNER_SHA_MISMATCH"
  mkdir -p "$logs_root" "$evidence_root" "$aggregate_root" "$work_root/tmp"
  python3 "$helper_path" init --work-root "$work_root" --gate-id "$GATE_ID" --private-sha "$PRIVATE_SHA" --runner-sha "$RUNNER_SHA"
  printf '%s\n' "RUNNER_SHA_MATCH=true" "INITIALIZATION=PASS"
}

case "$phase" in
  initialize) phase_initialize_one_click ;;
  checkout_exact_sha) phase_checkout_exact_sha ;;
  ruby_toolchain_preflight) phase_ruby_toolchain_preflight ;;
  core_component_matrix) phase_core_component_matrix ;;
  onboarding_web_component_matrix) phase_onboarding_web_component_matrix ;;
  story_component_matrix) phase_story_component_matrix ;;
  media_component_matrix) phase_media_component_matrix ;;
  ops_component_matrix) phase_ops_component_matrix ;;
  validate_source) phase_validate_source ;;
  doctor) phase_doctor ;;
  pilot_a) phase_pilot_a ;;
  verify_a) phase_verify_a ;;
  pilot_b) phase_pilot_b ;;
  verify_b) phase_verify_b ;;
  aggregate_release_check) phase_aggregate_release_check ;;
  canonical_v03_executor) phase_canonical_v03_executor ;;
  emit_runtime_evidence) phase_emit_runtime_evidence ;;
  *) policy_error "UNKNOWN_FIXED_PHASE" ;;
esac
