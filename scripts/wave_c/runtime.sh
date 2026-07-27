factory_bin="10_factory_mvp/ops/bin/factory"
if [[ ! -f "$private_checkout/$factory_bin" ]]; then
  mark_blocked "FACTORY_ENTRYPOINT_MISSING"
else
  run_private "FACTORY_VALIDATE_SOURCE" validator "$private_checkout" -- ruby "$factory_bin" validate-source || true
  run_private "FACTORY_DOCTOR" doctor "$private_checkout" -- ruby "$factory_bin" doctor || true
  doctor_log="$logs_root/FACTORY_DOCTOR.log"
  if [[ -s "$doctor_log" ]]; then
    cp "$doctor_log" "$doctor_path"
  fi
fi

run_pilot() {
  local run_label=$1
  local run_root=$2
  local command_id="${run_label}_PILOT"
  rm -rf -- "$run_root"
  mkdir -p "$run_root"
  local runtime_root="$run_root/runtime"
  local artifact_root="$run_root/artifacts"
  local report_path="$run_root/pilot-report.json"
  local command_output="$run_root/pilot-command.json"
  run_private "$command_id" pilot "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$runtime_root" \
    "FACTORY_MVP_ARTIFACT_ROOT=$artifact_root" \
    "FACTORY_MVP_REPORT_PATH=$report_path" \
    -- ruby "$factory_bin" pilot --mode deterministic || true
  cp "$logs_root/${command_id}.log" "$command_output"
  if [[ ! -f "$report_path" ]]; then
    mark_blocked "${run_label}_REPORT_MISSING"
  fi
}

if [[ -f "$private_checkout/$factory_bin" ]]; then
  run_pilot "RUN_A" "$run_a_root"
fi

json_field() {
  local path=$1
  local field=$2
  python3 - "$path" "$field" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
value = payload.get(field)
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

run_verify() {
  local run_label=$1
  local run_root=$2
  local report_path="$run_root/pilot-report.json"
  local manifest_path=""
  manifest_path="$(json_field "$report_path" manifest_path 2>/dev/null || true)"
  if [[ -z "$manifest_path" || ! -f "$manifest_path" ]]; then
    mark_blocked "${run_label}_MANIFEST_PATH_MISSING"
    return 0
  fi
  run_private "${run_label}_VERIFY" verify "$private_checkout" -- ruby "$factory_bin" verify "$manifest_path" || true
  cp "$logs_root/${run_label}_VERIFY.log" "$run_root/verify.json"
}

if [[ -f "$run_a_root/pilot-report.json" ]]; then
  run_verify "RUN_A" "$run_a_root"
fi

run_media_handoff_smoke() {
  local smoke="$private_checkout/10_factory_mvp/media/bin/media_story_handoff_smoke.rb"
  [[ -f "$smoke" ]] || { mark_blocked "MEDIA_STORY_HANDOFF_SMOKE_MISSING"; return 0; }
  local report="$run_a_root/pilot-report.json"
  local core_db=""
  local handoff=""
  core_db="$(json_field "$report" core_db_path 2>/dev/null || true)"
  handoff="$(python3 - "$report" <<'PY'
import json
import sys
from pathlib import Path
try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
for key in ("story_media_handoff_path", "story_handoff_path", "persisted_story_media_handoff_path"):
    value = payload.get(key)
    if isinstance(value, str) and value:
        print(value)
        break
else:
    raise SystemExit(1)
PY
  2>/dev/null || true)"
  if [[ -z "$core_db" || ! -f "$core_db" || -z "$handoff" || ! -f "$handoff" ]]; then
    printf '%s\n' "BLOCKER_CODE=MEDIA_STORY_HANDOFF_INPUT_UNAVAILABLE"
    mark_blocked "MEDIA_STORY_HANDOFF_INPUT_UNAVAILABLE"
    return 0
  fi
  local handoff_root="$work_root/components/media-story-handoff"
  mkdir -p "$handoff_root"
  run_private "MEDIA_STORY_HANDOFF_SMOKE" component "$private_checkout" \
    "FACTORY_MVP_CORE_DB=$core_db" \
    "FACTORY_MVP_STORY_HANDOFF_PATH=$handoff" \
    "FACTORY_MVP_ARTIFACT_ROOT=$handoff_root/artifacts" \
    "FACTORY_MVP_FRAME_RATE=24" \
    -- ruby 10_factory_mvp/media/bin/media_story_handoff_smoke.rb || true
}

if [[ -f "$run_a_root/pilot-report.json" ]]; then
  run_media_handoff_smoke
fi

if [[ -f "$private_checkout/$factory_bin" ]]; then
  run_pilot "RUN_B" "$run_b_root"
fi
if [[ -f "$run_b_root/pilot-report.json" ]]; then
  run_verify "RUN_B" "$run_b_root"
fi
