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

python3 scripts/wave_c/test_gate_contract.py
