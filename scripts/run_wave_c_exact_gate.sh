#!/usr/bin/env bash
set -uo pipefail
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_root/wave_c/lib.sh"
source "$script_root/wave_c/components.sh"
source "$script_root/wave_c/runtime.sh"
source "$script_root/wave_c/evidence.sh"
