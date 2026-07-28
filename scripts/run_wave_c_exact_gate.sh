#!/usr/bin/env bash
set -euo pipefail
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_root/wave_c/lib.sh" "$@"
source "$script_root/wave_c/components.sh"
source "$script_root/wave_c/runtime.sh"
source "$script_root/wave_c/evidence.sh"

case "$phase" in
  initialize) phase_initialize ;;
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
