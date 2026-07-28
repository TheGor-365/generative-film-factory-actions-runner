#!/usr/bin/env bash
set -uo pipefail

phase_ruby_toolchain_preflight() {
  local step_id=ruby_toolchain_preflight
  local log_file="$logs_root/RUBY_TOOLCHAIN_PREFLIGHT.log"
  mkdir -p "$logs_root"
  : > "$log_file"
  local missing=()
  local tool
  for tool in git ruby python3 ffmpeg ffprobe zip unzip sha256sum timeout; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "TOOL_${tool^^}=PRESENT" >> "$log_file"
    else
      printf '%s\n' "TOOL_${tool^^}=MISSING" >> "$log_file"
      missing+=("TOOLCHAIN_${tool^^}_MISSING")
    fi
  done
  local ruby_major
  ruby_major=$(ruby -e 'print RUBY_VERSION.split(".").first' 2>/dev/null || true)
  if [[ "$ruby_major" != "3" ]]; then
    missing+=("RUBY_3_REQUIRED")
    printf '%s\n' "RUBY_3_REQUIRED=false" >> "$log_file"
  else
    printf '%s\n' "RUBY_3_REQUIRED=true" >> "$log_file"
  fi
  if ruby -rwebrick -e 'exit 0' >/dev/null 2>&1; then
    printf '%s\n' "WEBRICK_REQUIRED=true" >> "$log_file"
  else
    missing+=("WEBRICK_REQUIRED")
    printf '%s\n' "WEBRICK_REQUIRED=false" >> "$log_file"
  fi
  local digest
  digest=$(sha256sum "$log_file" | awk '{print $1}')
  if [[ ${#missing[@]} -eq 0 ]]; then
    record_result "$step_id" infrastructure ruby_toolchain_preflight PASS 0 "$digest"
    printf '%s\n' "RUBY_TOOLCHAIN_PREFLIGHT=PASS"
  else
    record_result "$step_id" infrastructure ruby_toolchain_preflight ERROR 2 "$digest" "${missing[@]}"
    printf '%s\n' "RUBY_TOOLCHAIN_PREFLIGHT=ERROR" "TOOLCHAIN_ERROR_COUNT=${#missing[@]}"
  fi
}

run_discovered_component() {
  local component=$1
  local step_id=$2
  local include_regex=$3
  local exclude_regex=$4
  local load_path=$5
  shift 5
  local roots=("$@")

  require_exact_checkout "$step_id" || return 0
  if ! command -v ruby >/dev/null 2>&1; then
    record_error "$step_id" component "${component}_runtime" RUBY_TOOLCHAIN_MISSING
    return 0
  fi

  local files=()
  local root file rel
  for root in "${roots[@]}"; do
    if [[ -d "$private_checkout/$root" ]]; then
      while IFS= read -r -d '' file; do
        files+=("$file")
      done < <(find "$private_checkout/$root" -type f \( -name '*_test.rb' -o -name '*_smoke.rb' \) -print0)
    fi
  done

  local selected=()
  for file in "${files[@]}"; do
    rel=${file#"$private_checkout/"}
    [[ "$rel" =~ $include_regex ]] || continue
    if [[ -n "$exclude_regex" && "$rel" =~ $exclude_regex ]]; then
      continue
    fi
    selected+=("$rel")
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    record_missing "$step_id" component "${component}_suite" "${component^^}_OFFICIAL_SUITE_MISSING"
    return 0
  fi

  mapfile -t selected < <(printf '%s\n' "${selected[@]}" | LC_ALL=C sort -u)
  printf '%s\n' "${component^^}_DISCOVERED_COUNT=${#selected[@]}"
  local index=0
  local command_id per_command_root
  for rel in "${selected[@]}"; do
    index=$((index + 1))
    command_id="${component}_$(printf '%03d' "$index")"
    per_command_root="$work_root/components/$component/$index"
    mkdir -p "$per_command_root"
    local ruby_args=(ruby)
    [[ -n "$load_path" ]] && ruby_args+=("-I$load_path")
    ruby_args+=("$rel")
    run_private "$step_id" component "$command_id" "$private_checkout" \
      "GFF_SOURCE_SHA=$PRIVATE_SHA" \
      "FACTORY_MVP_RUNTIME_ROOT=$per_command_root/runtime" \
      "FACTORY_MVP_ARTIFACT_ROOT=$per_command_root/artifacts" \
      "FACTORY_MVP_REPORT_PATH=$per_command_root/report.json" \
      "FACTORY_MVP_MEDIA_120S_ROOT=$per_command_root/media-120s" \
      -- "${ruby_args[@]}"
  done
}

phase_core_component_matrix() {
  local step_id=core_component_matrix
  require_exact_checkout "$step_id" || return 0
  local entry="10_factory_mvp/app/core/bin/core_check.rb"
  if [[ ! -f "$private_checkout/$entry" ]]; then
    record_missing "$step_id" component core_official_check CORE_OFFICIAL_CHECK_MISSING
    return 0
  fi
  run_private "$step_id" component core_official_check "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$work_root/components/core/runtime" \
    "FACTORY_MVP_ARTIFACT_ROOT=$work_root/components/core/artifacts" \
    -- ruby "$entry"
}

phase_onboarding_web_component_matrix() {
  run_discovered_component onboarding_web onboarding_web_component_matrix \
    '^10_factory_mvp/(app/onboarding|web)/' '' \
    '10_factory_mvp/app/onboarding/lib:10_factory_mvp/app/core/lib' \
    '10_factory_mvp/app/onboarding' '10_factory_mvp/web'
}

phase_story_component_matrix() {
  run_discovered_component story story_component_matrix \
    '^10_factory_mvp/app/story/' '' \
    '10_factory_mvp/app/story/lib:10_factory_mvp/app/core/lib' \
    '10_factory_mvp/app/story'
}

phase_media_component_matrix() {
  run_discovered_component media media_component_matrix \
    '^10_factory_mvp/media/' 'media_story_handoff_smoke\.rb$' \
    '10_factory_mvp/media/lib:10_factory_mvp/app/core/lib:10_factory_mvp/app/story/lib' \
    '10_factory_mvp/media'
}

phase_ops_component_matrix() {
  run_discovered_component ops ops_component_matrix \
    '^10_factory_mvp/ops/' '' \
    '10_factory_mvp/ops/lib:10_factory_mvp/app/core/lib:10_factory_mvp/app/story/lib:10_factory_mvp/media/lib' \
    '10_factory_mvp/ops'
}
