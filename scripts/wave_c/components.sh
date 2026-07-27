for tool in git ruby python3 ffmpeg ffprobe zip unzip sha256sum timeout; do
  require_tool "$tool"
done

ruby_major="$(ruby -e 'print RUBY_VERSION.split(".").first' 2>/dev/null || true)"
if [[ "$ruby_major" != "3" ]]; then
  mark_error "RUBY_3_REQUIRED"
fi
if ! ruby -rwebrick -e 'exit 0' >/dev/null 2>&1; then
  mark_error "WEBRICK_REQUIRED"
fi
if [[ "$result" == "ERROR" ]]; then
  printf '%s\n' \
    "TOOLCHAIN_PREFLIGHT_RESULT=ERROR" \
    "ERROR_CHECK_COUNT=${#error_codes[@]}" \
    "ERROR_CHECK_CODES=$(IFS=,; echo "${error_codes[*]}")" \
    "RESULT=ERROR" \
    "EXIT_CODE=2" \
    "NO_FAKE_GREEN=true"
  exit 2
fi
printf '%s\n' "TOOLCHAIN_PREFLIGHT_RESULT=PASS"

run_discovered_suite() {
  local component=$1
  local cwd=$2
  local include_regex=$3
  local exclude_regex=$4
  local load_path=$5
  shift 5
  local roots=("$@")
  local files=()
  local root
  for root in "${roots[@]}"; do
    if [[ -d "$private_checkout/$root" ]]; then
      while IFS= read -r -d '' file; do
        files+=("$file")
      done < <(find "$private_checkout/$root" -type f \( -name '*_test.rb' -o -name '*_smoke.rb' \) -print0)
    fi
  done

  local selected=()
  local file rel
  for file in "${files[@]}"; do
    rel=${file#"$private_checkout/"}
    [[ "$rel" =~ $include_regex ]] || continue
    if [[ -n "$exclude_regex" && "$rel" =~ $exclude_regex ]]; then
      continue
    fi
    selected+=("$rel")
  done
  if [[ ${#selected[@]} -eq 0 ]]; then
    printf '%s\n' "${component}_DISCOVERED_COUNT=0" "BLOCKER_CODE=${component}_OFFICIAL_SUITE_MISSING"
    mark_blocked "${component}_OFFICIAL_SUITE_MISSING"
    return 0
  fi

  mapfile -t selected < <(printf '%s\n' "${selected[@]}" | LC_ALL=C sort -u)
  printf '%s\n' "${component}_DISCOVERED_COUNT=${#selected[@]}"
  local index=0
  for rel in "${selected[@]}"; do
    index=$((index + 1))
    local command_id
    command_id="${component}_$(printf '%03d' "$index")"
    local per_command_root="$work_root/components/${component,,}/$index"
    mkdir -p "$per_command_root"
    local ruby_args=(ruby)
    if [[ -n "$load_path" ]]; then
      ruby_args+=("-I$load_path")
    fi
    ruby_args+=("$rel")
    run_private "$command_id" component "$cwd" \
      "FACTORY_MVP_RUNTIME_ROOT=$per_command_root/runtime" \
      "FACTORY_MVP_ARTIFACT_ROOT=$per_command_root/artifacts" \
      "FACTORY_MVP_REPORT_PATH=$per_command_root/report.json" \
      "FACTORY_MVP_MEDIA_120S_ROOT=$per_command_root/media-120s" \
      -- "${ruby_args[@]}" || true
  done
}

if [[ -f "$private_checkout/10_factory_mvp/app/core/bin/core_check.rb" ]]; then
  run_private "CORE_OFFICIAL_CHECK" component "$private_checkout" \
    "FACTORY_MVP_RUNTIME_ROOT=$work_root/components/core/runtime" \
    "FACTORY_MVP_ARTIFACT_ROOT=$work_root/components/core/artifacts" \
    -- ruby 10_factory_mvp/app/core/bin/core_check.rb || true
else
  mark_blocked "CORE_OFFICIAL_CHECK_MISSING"
fi

run_discovered_suite \
  "ONBOARDING_WEB" \
  "$private_checkout" \
  '^10_factory_mvp/(app/onboarding|web)/' \
  '' \
  '10_factory_mvp/app/onboarding/lib:10_factory_mvp/app/core/lib' \
  '10_factory_mvp/app/onboarding' '10_factory_mvp/web'

run_discovered_suite \
  "STORY" \
  "$private_checkout" \
  '^10_factory_mvp/app/story/' \
  '' \
  '10_factory_mvp/app/story/lib:10_factory_mvp/app/core/lib' \
  '10_factory_mvp/app/story'

run_discovered_suite \
  "MEDIA" \
  "$private_checkout" \
  '^10_factory_mvp/media/' \
  'media_story_handoff_smoke\.rb$' \
  '10_factory_mvp/media/lib:10_factory_mvp/app/core/lib:10_factory_mvp/app/story/lib' \
  '10_factory_mvp/media'

run_discovered_suite \
  "OPS" \
  "$private_checkout" \
  '^10_factory_mvp/ops/' \
  '' \
  '10_factory_mvp/ops/lib:10_factory_mvp/app/core/lib:10_factory_mvp/app/story/lib:10_factory_mvp/media/lib' \
  '10_factory_mvp/ops'
