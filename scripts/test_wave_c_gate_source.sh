#!/usr/bin/env bash
set -euo pipefail

python3 -m json.tool contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json >/dev/null
printf '%s\n' "JSON_PARSE=PASS"

ruby -e 'require "yaml"; value = YAML.safe_load(File.read(".github/workflows/run-wave-c-exact-evidence.yml"), aliases: true); raise "workflow_not_object" unless value.is_a?(Hash)'
printf '%s\n' "YAML_PARSE=PASS"

while IFS= read -r path; do
  bash -n "$path"
done < <(find scripts -type f -name '*.sh' | LC_ALL=C sort)
printf '%s\n' "BASH_SYNTAX=PASS"

python3 - <<'PY'
import ast
from pathlib import Path
paths = sorted(Path("scripts").rglob("*.py"))
for path in paths:
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print(f"PYTHON_SYNTAX=PASS_{len(paths)}_FILES")
PY

PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_git_topology.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_source_sha_propagation.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_gate_contract.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_report_discovery.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_binding_semantics.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/wave_c/test_r0e_pr_trigger.py
workflow=.github/workflows/run-wave-c-exact-evidence.yml
contract=contracts/GFF_WAVE_C_G1_V03_VALIDATION_v01.json
frozen_sha=be76c8be95fa61d175c4c99ea16b4bf670510560
[[ $(grep -F "$frozen_sha" "$workflow" | wc -l) -eq 1 ]]
[[ $(grep -F "$frozen_sha" "$contract" | wc -l) -eq 1 ]]
[[ $(grep -F "$frozen_sha" scripts/wave_c/lib.sh | wc -l) -eq 1 ]]
printf '%s\n' "FROZEN_SHA_STATIC_BINDINGS=PASS_3_OF_3"

! grep -R -Fq 'actions/upload-artifact' .github scripts contracts
! grep -R -Fq 'actions/cache' .github scripts contracts
! grep -Fq 'inputs:' "$workflow"
! grep -Fq '${{ inputs.' "$workflow"
production_sources=(
  scripts/run_wave_c_exact_gate.sh
  scripts/wave_c/lib.sh
  scripts/wave_c/components.sh
  scripts/wave_c/runtime.sh
  scripts/wave_c/evidence.sh
  scripts/wave_c/git_topology.sh
  scripts/wave_c/evidence_contract.py
  scripts/wave_c/report_discovery.py
  scripts/wave_c/report_discovery_contract.py
  scripts/wave_c/emit_failure_diagnostics.sh
)
! grep -Fq 'PRIVATE_MAIN_SHA_MISMATCH' "${production_sources[@]}"
! grep -Fq 'PRIVATE_MAIN_SHA_MATCH' "${production_sources[@]}"
printf '%s\n' \
  "PUBLIC_ARTIFACT_UPLOAD=false" \
  "CACHE=false" \
  "NETWORK_MEDIA_PROVIDER_CALLS=false" \
  "PAID_PROVIDER_CALLS=false" \
  "WORKFLOW_INPUTS=0" \
  "OLD_EQUALITY_ASSERTION_PRESENT=false" \
  "PRIVATE_REPO_WRITES=0" \
  "WORKFLOW_DISPATCHED=false" \
  "OFFICIAL_ACTIONS_PASS=false" \
  "NO_FAKE_GREEN=true"
