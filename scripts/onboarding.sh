# Embedded into the installed CLI. Project configuration is data, never code.

project_config_jq() { printf '%s' "$project_profiles" | jq "$@"; }

validate_project_config() {
  local document="$1"
  printf '%s' "$document" | jq -e -s 'length == 1' >/dev/null 2>&1 || {
    error 'Invalid .agentbox.json: expected one JSON document'; exit 1;
  }
  if ! printf '%s' "$document" | jq -e '
    def optional(k; t): (has(k) | not) or (.[k] | type == t);
    def profile:
      type == "object" and
      ((keys - ["mode","access","mounts","ports","network","audit_log","cpu","memory","pids_limit","ulimit_nofile","ulimit_fsize"]) | length == 0) and
      optional("mode"; "string") and optional("access"; "string") and
      ((.mode // "edit") | IN("edit", "review", "offline")) and
      ((.access // "direct") | IN("direct", "broker")) and
      optional("mounts"; "array") and optional("ports"; "array") and
      optional("network"; "string") and optional("audit_log"; "boolean") and
      optional("cpu"; "string") and optional("memory"; "string") and
      optional("pids_limit"; "number") and optional("ulimit_nofile"; "string") and optional("ulimit_fsize"; "number") and
      all((.mounts // [])[]; type == "object" and ((keys - ["path","readonly"]) | length == 0) and (.path | type == "string") and optional("readonly"; "boolean")) and
      all((.ports // [])[]; type == "object" and ((keys - ["host","container"]) | length == 0) and (.host | type == "number") and (.container | type == "number"));
    def names: all(keys[]; length > 0 and all(explode[]; . >= 32 and . != 127));
    type == "object" and
    if has("version") and (.version | type != "object") then
      .version == 1 and
      ((keys - ["version","runtime","default_profile","profiles"]) | length == 0) and
      (.runtime | IN("claude", "codex")) and
      (.default_profile | type == "string" and length > 0) and
      (.profiles | type == "object" and length > 0 and names) and
      (.default_profile as $p | .profiles | has($p)) and
      all(.profiles[]; profile)
    else names and all(.[]; profile) end
  ' >/dev/null 2>&1; then
    error 'Invalid .agentbox.json profile schema (unknown field, version, or incorrect type)'; exit 1
  fi
}

load_project_config() {
  project_document=""
  project_original=""
  project_profiles='{}'
  project_versioned=false
  project_runtime=""
  project_default_profile=""
  if [ -L .agentbox.json ]; then error 'Refusing symlinked .agentbox.json'; exit 1; fi
  if [ -e .agentbox.json ]; then
    [ -f .agentbox.json ] || { error '.agentbox.json must be a regular file'; exit 1; }
    command -v jq >/dev/null || { error 'jq is required to parse .agentbox.json; install jq and retry'; exit 1; }
    project_original=$(cat .agentbox.json)
    project_document="$project_original"
    validate_project_config "$project_document"
    if printf '%s' "$project_document" | jq -e '.version == 1' >/dev/null; then
      project_versioned=true
      project_profiles=$(printf '%s' "$project_document" | jq -c '.profiles')
      project_runtime=$(printf '%s' "$project_document" | jq -r '.runtime')
      project_default_profile=$(printf '%s' "$project_document" | jq -r '.default_profile')
    else project_profiles="$project_document"; fi
  fi
}

assert_project_config_unchanged() {
  if [ -L .agentbox.json ] || [ "$(cat .agentbox.json 2>/dev/null || true)" != "$project_original" ]; then
    error '.agentbox.json changed during setup or launch; retry'; exit 1
  fi
}

prompt_value() {
  local label="$1" default="$2" reply
  printf '%s [%s]: ' "$label" "$default" >&2
  if ! IFS= read -r reply < /dev/tty; then error 'Setup cancelled'; exit 1; fi
  printf '%s' "${reply:-$default}"
}

prompt_enum() {
  local label="$1" default="$2" allowed="$3" reply
  while true; do
    reply=$(prompt_value "$label ($allowed)" "$default")
    case "|$allowed|" in *"|$reply|"*) printf '%s' "$reply"; return ;; esac
    error "Choose one of: $allowed"
  done
}

confirm_access() {
  local reply
  printf '%s [y/N]: ' "$1" >&2
  if ! IFS= read -r reply < /dev/tty; then return 1; fi
  [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

prepare_project_init() {
  local profile cpu memory pids mounts ports path ro
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    error 'agentbox init requires an interactive terminal'; exit 1
  fi
  if [ ${#cmd_args[@]} -ne 1 ] || [ "$dry_run" != false ] || [ "$staged_mode" != false ] ||
    [ "$plugins_enabled" != false ] || [ "$allow_project_dockerfile" != false ] || [ "$readonly_mode" != false ]; then
    error 'Usage: agentbox init [--claude|--codex] [--profile name] [--direct|--broker]'; exit 1
  fi
  command -v jq >/dev/null || { error 'Install jq before running agentbox init'; exit 1; }
  section 'Project setup'
  [ "$runtime_explicit" = true ] || agent_runtime=$(prompt_enum 'Agent' "$agent_runtime" 'claude|codex')
  select_installed_image
  doctor || exit 1
  if [ -z "$profile_name" ]; then
    profile_name="$project_default_profile"
    if [ -z "$profile_name" ]; then
      if [ "$(project_config_jq 'length')" -gt 1 ]; then
        local names=() name
        while IFS= read -r name; do names+=("$name"); done < <(project_config_jq -r 'keys[]')
        profile_name=$(choose 'Profile to configure:' "${names[@]}")
      else profile_name=$(project_config_jq -r 'keys[0] // "default"'); fi
    fi
  fi
  profile=$(project_config_jq -c --arg p "$profile_name" '.[$p] // {}')
  [ "$mode_explicit" = true ] || launch_mode=$(prompt_enum 'Files' "$(printf '%s' "$profile" | jq -r '.mode // "edit"')" 'edit|review|offline')
  if [ "$launch_mode" != offline ]; then
    local access
    access=$(printf '%s' "$profile" | jq -r '.access // "direct"')
    if [ "$access_explicit" = true ]; then
      [ "$broker_mode" != true ] || access=broker
      [ "$broker_mode" != false ] || access=direct
    else access=$(prompt_enum 'Access: direct uses host login; broker requires an API key' "$access" 'direct|broker'); fi
    broker_mode=false
    [ "$access" != broker ] || broker_mode=true
  else broker_mode=false; fi
  cpu=$(prompt_value 'CPU limit; none = unlimited' "$(printf '%s' "$profile" | jq -r '.cpu // "none"')")
  memory=$(prompt_value 'Memory limit; none = unlimited' "$(printf '%s' "$profile" | jq -r '.memory // "none"')")
  pids=$(prompt_value 'Process limit' "$(printf '%s' "$profile" | jq -r '.pids_limit // 256')")
  [[ "$pids" =~ ^[1-9][0-9]*$ ]] || { error 'Process limit must be a positive integer'; exit 1; }
  mounts=$(printf '%s' "$profile" | jq -c '.mounts // []')
  ports=$(printf '%s' "$profile" | jq -c '.ports // []')
  if [ "$mounts" != '[]' ]; then
    printf 'Existing extra mounts: %s\n' "$mounts" >&2
    confirm_access 'Keep these mounts?' || mounts='[]'
  fi
  while true; do
    path=$(prompt_value 'Extra mount: canonical absolute path; blank = done' '')
    [ -n "$path" ] || break
    ro=$(prompt_enum 'Mount permissions' 'read-only' 'read-only|read-write')
    mounts=$(printf '%s' "$mounts" | jq -c --arg path "$path" --arg ro "$ro" '. + [{path:$path,readonly:($ro == "read-only")}]')
  done
  if [ "$ports" != '[]' ]; then
    printf 'Existing published ports: %s\n' "$ports" >&2
    confirm_access 'Keep these ports?' || ports='[]'
  fi
  project_profiles=$(project_config_jq --arg p "$profile_name" --arg mode "$launch_mode" \
    --arg access "$([ "$broker_mode" = true ] && echo broker || echo direct)" \
    --arg cpu "$cpu" --arg memory "$memory" --argjson pids "$pids" --argjson mounts "$mounts" --argjson ports "$ports" '
    .[$p] = ((.[$p] // {}) + {mode:$mode,access:$access,pids_limit:$pids,mounts:$mounts,ports:$ports}) |
    if $cpu == "none" then del(.[$p].cpu) else .[$p].cpu = $cpu end |
    if $memory == "none" then del(.[$p].memory) else .[$p].memory = $memory end |
    .[$p].network = (if $mode == "offline" then "none" else "bridge" end)')
  project_document=$(project_config_jq --arg runtime "$agent_runtime" --arg p "$profile_name" \
    '{version:1,runtime:$runtime,default_profile:$p,profiles:.}')
  validate_project_config "$project_document"
  project_versioned=true
  mode_explicit=true
  access_explicit=true
}

launch_grants() {
  printf 'runtime=%s\nimage=%s\nmode=%s\nreadonly=%s\nnetwork=%s\nstaged=%s\nplugins=%s\nproject_image=%s\n' \
    "$agent_runtime" "$run_image" "$launch_mode" "$readonly_mode" "${network_mode:-bridge}" \
    "$staged_mode" "$PLUGIN_SNAPSHOT" "$allow_project_dockerfile"
  printf 'mount=%s\n' ${extra_mounts[@]+"${extra_mounts[@]}"}
  printf 'port=%s\n' ${extra_ports[@]+"${extra_ports[@]}"}
  printf 'resource=%s\n' ${resource_args[@]+"${resource_args[@]}"}
}

grant_record_path() {
  local digest
  digest=$(launch_grants | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')
  printf '%s/project-grants/%s/%s' "$AGENTBOX_STATE_DIR" "$(trusted_project_key)" "$digest"
}

approve_launch() {
  local identity
  identity=$(project_identity)
  assert_project_config_unchanged
  trust_project "$identity"
  if [ "$project_versioned" = true ]; then
    write_private_file_content "$(grant_record_path)" "$identity"$'\n'"$(launch_grants)"
  fi
}

launch_is_approved() {
  is_project_trusted || return 1
  [ "$project_versioned" = true ] || return 0
  local record
  record=$(grant_record_path)
  [ -f "$record" ] && [ ! -L "$record" ] && [ "$(cat "$record")" = "$(project_identity; launch_grants)" ]
}

finish_project_init() {
  local tmp
  inspect_plan
  [ ! -f .agentbox.Dockerfile ] || note 'Project Dockerfile requires --allow-project-dockerfile on each launch'
  confirm_access 'Save this configuration and approve these permissions on this machine?' || { info 'Setup cancelled; configuration unchanged'; exit 0; }
  assert_project_config_unchanged
  tmp=$(mktemp "$workdir/.agentbox.json.tmp.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$project_document" > "$tmp"
  chmod 644 "$tmp"
  # rename replaces the destination entry; mv could follow a raced directory symlink.
  perl -e 'rename $ARGV[0], $ARGV[1] or die "Cannot save project config: $!\n"' "$tmp" "$workdir/.agentbox.json"
  trap - EXIT
  project_original=$(cat .agentbox.json)
  approve_launch
  success 'Saved .agentbox.json and local permission approval.'
  if [ "${network_mode:-bridge}" = broker ]; then
    if [ "$agent_runtime" = codex ]; then
      if [ -n "${OPENAI_API_KEY:-}" ]; then success 'Authentication source found'; else info 'Export OPENAI_API_KEY before launching; broker mode requires API billing.'; fi
    else
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then success 'Authentication source found'; else info 'Export ANTHROPIC_API_KEY before launching; broker mode requires API billing.'; fi
    fi
  elif [ "${network_mode:-bridge}" != none ]; then
    if [ "$agent_runtime" = codex ]; then
      if codex_auth_available; then success 'Authentication source found'; else info "Run 'codex login' on the host, or export OPENAI_API_KEY before launching."; fi
    else
      if host_auth_available; then success 'Authentication source found'; else info "Run 'claude' on the host and complete /login, or export ANTHROPIC_API_KEY before launching."; fi
    fi
  fi
  info 'Run agentbox to start. Commit .agentbox.json to share project preferences.'
}
