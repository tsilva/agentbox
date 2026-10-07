# Embedded by render-cli.sh; this module owns launch state and host preferences.

configure_session_paths() {
  SESSION_DIR="$1"
  SANDBOX_CLAUDE_DIR="$SESSION_DIR/claude-config"
  SANDBOX_DOTCONFIG_DIR="$SESSION_DIR/claude-dotconfig"
  SANDBOX_PLUGINS_DIR="$SESSION_DIR/plugins"
  SANDBOX_CLAUDE_STATE_FILE="$SESSION_DIR/.claude.json"
  SANDBOX_CREDENTIALS_FILE="$SANDBOX_CLAUDE_DIR/.credentials.json"
  SANDBOX_CODEX_DIR="$SESSION_DIR/codex-config"
  SANDBOX_CODEX_AUTH_FILE="$SANDBOX_CODEX_DIR/auth.json"
  AUTHLESS_STATE_DIR="$SESSION_DIR/authless"
  AUTHLESS_DOTCONFIG_DIR="$AUTHLESS_STATE_DIR/claude-dotconfig"
  AUTHLESS_CLAUDE_DIR="$AUTHLESS_STATE_DIR/claude-config"
  AUTHLESS_PLUGINS_DIR="$AUTHLESS_STATE_DIR/plugins"
  AUTHLESS_CLAUDE_STATE_FILE="$AUTHLESS_STATE_DIR/.claude.json"
  AUTHLESS_CODEX_DIR="$AUTHLESS_STATE_DIR/codex-config"
  EMPTY_RUNTIME_STATE_DIR="$SESSION_DIR/empty"
  EMPTY_DOTCONFIG_DIR="$EMPTY_RUNTIME_STATE_DIR/claude-dotconfig"
  EMPTY_CLAUDE_DIR="$EMPTY_RUNTIME_STATE_DIR/claude-config"
  EMPTY_PLUGINS_DIR="$EMPTY_RUNTIME_STATE_DIR/plugins"
  EMPTY_CLAUDE_STATE_FILE="$EMPTY_RUNTIME_STATE_DIR/.claude.json"
  EMPTY_CODEX_DIR="$EMPTY_RUNTIME_STATE_DIR/codex-config"
  ACTIVE_SANDBOX_DOTCONFIG_DIR="$SANDBOX_DOTCONFIG_DIR"
  ACTIVE_SANDBOX_CLAUDE_DIR="$SANDBOX_CLAUDE_DIR"
  ACTIVE_SANDBOX_CREDENTIALS_FILE="$SANDBOX_CREDENTIALS_FILE"
  ACTIVE_SANDBOX_PLUGINS_DIR="$SANDBOX_PLUGINS_DIR"
  ACTIVE_SANDBOX_CLAUDE_STATE_FILE="$SANDBOX_CLAUDE_STATE_FILE"
  ACTIVE_SANDBOX_CODEX_DIR="$SANDBOX_CODEX_DIR"
  ACTIVE_SANDBOX_CODEX_AUTH_FILE="$SANDBOX_CODEX_AUTH_FILE"
}

read_preferred_runtime() {
  local value="claude" file="$AGENTBOX_STATE_DIR/default-runtime"
  if [ -L "$AGENTBOX_STATE_DIR" ] || [ -L "$file" ]; then
    error "Refusing symlinked agentbox preferences"; exit 1
  fi
  [ ! -f "$file" ] || value=$(cat "$file")
  [[ "$value" =~ ^(claude|codex)$ ]] || { error "Invalid preferred runtime; run agentbox setup --claude or --codex"; exit 1; }
  printf '%s' "$value"
}

show_help() {
  cat <<'HELP'
Usage: agentbox [--claude|--codex] [review|edit|offline] [agent arguments]
       agentbox init [--claude|--codex] [--profile name]
       agentbox setup --claude|--codex
       agentbox doctor | inspect | trust | untrust | update
       agentbox plugins refresh

Modes: edit (default), review (read-only host mounts), offline (no network/auth).
--direct       Use host login/API key and normal networking; overrides saved broker access
--broker       API-key-only provider access; no networking in the agent container
--plugins      Use the explicitly refreshed, read-only Claude plugin snapshot
--staged       Edit a private Git-tracked snapshot; use agentbox apply <session>
--dry-run      Print the launch command without reading auth or writing state
--profile/-P   Select a project profile; -- ends agentbox option parsing
HELP
}

select_installed_image() {
  local file="$AGENTBOX_STATE_DIR/images/$agent_runtime" image
  [ ! -d "$AGENTBOX_STATE_DIR/images" ] || IMAGE_NAME="agentbox-$agent_runtime"
  if [ -f "$file" ]; then
    [ ! -L "$file" ] || { error "Refusing symlinked image selection"; exit 1; }
    image=$(cat "$file")
    [[ "$image" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || { error "Invalid installed image"; exit 1; }
    IMAGE_NAME="$image"
  fi
}

inspect_plan() {
  local credentials=none
  if [ "$broker_mode" = true ]; then credentials=broker-only
  elif [ "$auth_state_required" = true ]; then credentials=selected-runtime; fi
  [ -z "$profile_name" ] || printf 'Profile: %s\n' "$profile_name"
  [ ${#extra_ports[@]} -eq 0 ] || printf 'Ports: %s\n' "${extra_ports[*]}"
  printf 'Runtime: %s\nMode: %s\nImage: %s\n' "$agent_runtime" "$launch_mode" "$run_image"
  printf 'Workspace: %s (%s)\n' "$workdir" "$([ "$readonly_mode" = true ] && echo read-only || echo read-write)"
  printf 'Network: %s\nCredentials: %s\nPlugins: %s\n' "${network_mode:-bridge}" \
    "$credentials" "$plugins_enabled"
  printf 'CPU: %s\nMemory: %s\nProcesses: %s\n' "${profile_cpu:-unlimited}" "${profile_memory:-unlimited}" "${profile_pids_limit:-$DEFAULT_PIDS_LIMIT}"
  [ -z "$extra_mounts_info" ] || printf 'Extra mounts:\n%s' "$extra_mounts_info"
  printf 'Security: non-root, read-only root, dropped capabilities, seccomp, no-new-privileges\n'
}

doctor() {
  local failed=0
  for tool in docker git perl curl; do
    if command -v "$tool" >/dev/null 2>&1; then printf 'OK: %s\n' "$tool"; else printf 'MISSING: %s\n' "$tool"; failed=1; fi
  done
  if docker info >/dev/null 2>&1; then
    printf 'OK: Docker daemon\n'
    if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then printf 'OK: image %s\n' "$IMAGE_NAME"; else printf 'MISSING: image %s; run install.sh\n' "$IMAGE_NAME"; failed=1; fi
  else printf 'MISSING: Docker daemon; start your Docker runtime\n'; failed=1; fi
  if [ -f .agentbox.json ] && ! command -v jq >/dev/null; then printf 'MISSING: jq for project profiles\n'; failed=1; fi
  [ -f "$SECCOMP_PROFILE" ] || { printf 'MISSING: seccomp profile; reinstall agentbox\n'; failed=1; }
  # Diagnostics intentionally never request Keychain access or print secrets.
  if [ "$agent_runtime" = codex ]; then
    codex_auth_available && printf 'OK: Codex auth source\n' || printf 'ACTION: codex login or export OPENAI_API_KEY\n'
  else
    { [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -s "$HOST_CREDENTIALS_FILE" ]; } && printf 'OK: Claude auth file\n' || printf 'INFO: Claude login may be stored in Keychain; launch will check it\n'
  fi
  return "$failed"
}

refresh_plugins() {
  local snapshot content metadata_file
  ensure_state_root
  ensure_private_dir "$AGENTBOX_STATE_DIR/plugin-snapshots"
  snapshot=$(mktemp -d "$AGENTBOX_STATE_DIR/plugin-snapshots/snapshot.XXXXXXXX")
  sync_directory "$HOST_CLAUDE_DIR/plugins/marketplaces" "$snapshot/marketplaces"
  sync_directory "$HOST_CLAUDE_DIR/plugins/cache" "$snapshot/cache"
  for metadata_file in known_marketplaces.json installed_plugins.json; do
    if [ -f "$HOST_CLAUDE_DIR/plugins/$metadata_file" ]; then
      content=$(cat "$HOST_CLAUDE_DIR/plugins/$metadata_file")
      write_private_file_content "$snapshot/$metadata_file" "${content//$HOME//home/claude}"
    fi
  done
  write_private_file_content "$AGENTBOX_STATE_DIR/plugin-snapshot" "${snapshot##*/}"
  success "Plugin snapshot refreshed; enable it with --claude --plugins"
}

select_plugin_snapshot() {
  local snapshot
  [ "$plugins_enabled" = true ] || return 0
  [ "$agent_runtime" = claude ] || { error "--plugins is supported only with Claude"; exit 1; }
  [ "${network_mode:-bridge}" != none ] || { error "Offline mode does not load host plugins"; exit 1; }
  [ -f "$AGENTBOX_STATE_DIR/plugin-snapshot" ] || { error "Run agentbox plugins refresh before --plugins"; exit 1; }
  snapshot=$(cat "$AGENTBOX_STATE_DIR/plugin-snapshot")
  [[ "$snapshot" =~ ^snapshot\.[a-zA-Z0-9]+$ ]] || { error "Invalid plugin snapshot"; exit 1; }
  PLUGIN_SNAPSHOT="$AGENTBOX_STATE_DIR/plugin-snapshots/$snapshot"
  [ -d "$PLUGIN_SNAPSHOT" ] && [ ! -L "$PLUGIN_SNAPSHOT" ] || { error "Missing plugin snapshot; refresh it"; exit 1; }
}

# Invoked through the EXIT-trap cleanup function.
# shellcheck disable=SC2329
remove_session_path() {
  local path="$1" attempt
  # Docker Desktop can briefly reject removal while nested binds detach.
  for attempt in 1 2 3; do
    if rm -rf -- "$path" 2>/dev/null; then return 0; fi
    [ "$attempt" -ge 3 ] || sleep 1
  done
  error "Could not remove private session state: $path. Remove it after confirming the session has stopped."
  return 1
}

# shellcheck disable=SC2329
cleanup_session() {
  local status=$?
  trap - EXIT INT TERM
  if [ -n "${container_name:-}" ]; then docker rm -f "$container_name" >/dev/null 2>&1 || true; fi
  if [ -n "${broker_container:-}" ]; then docker rm -f "$broker_container" >/dev/null 2>&1 || true; fi
  if [ -n "${broker_socket_volume:-}" ]; then docker volume rm "$broker_socket_volume" >/dev/null 2>&1 || true; fi
  if [ -n "${SESSION_DIR:-}" ] && [ "$dry_run" != true ]; then
    if [ "${staged_mode:-false}" = true ] && [ -d "$SESSION_DIR/workspace" ] && [ -f "$SESSION_DIR/baseline" ]; then
      # Retain only the staged files and baseline; remove all credentials/state.
      local path
      for path in "$SESSION_DIR"/* "$SESSION_DIR"/.[!.]*; do
        case "${path##*/}" in
          workspace|baseline|source|source-digest) ;;
          *) remove_session_path "$path" || { [ "$status" -ne 0 ] || status=1; } ;;
        esac
      done
      printf 'Staged edits: %s\nApply after review: agentbox apply %s\n' "$SESSION_DIR/workspace" "${SESSION_DIR##*/}" >&2
    else remove_session_path "$SESSION_DIR" || { [ "$status" -ne 0 ] || status=1; }; fi
  fi
  exit "$status"
}

workspace_helper() {
  command -v python3 >/dev/null || { error "Staged editing requires Python 3 on the host"; exit 1; }
  WORKSPACE_HELPER="$SCRIPT_DIR/workspace.py"
  [ -f "$WORKSPACE_HELPER" ] || { error "Workspace helper missing; reinstall agentbox"; exit 1; }
}

stage_workspace() {
  [ "$readonly_mode" = false ] || { error "--staged cannot be combined with review/--readonly"; exit 1; }
  [ ${#extra_mounts[@]} -le 2 ] || { error "--staged cannot expose additional host mounts"; exit 1; }
  workspace_helper
  python3 "$WORKSPACE_HELPER" stage "$workdir" "$SESSION_DIR"
  workdir="$SESSION_DIR/workspace"
  if [ -n "$git_dir" ]; then extra_mounts=(-v "$git_dir:$workdir/.git:ro"); fi
}

apply_staged_session() {
  local name="$1" source path
  [[ "$name" =~ ^session\.[a-zA-Z0-9]+$ ]] || { error "Usage: agentbox apply session.<id>"; exit 1; }
  path="$AGENTBOX_STATE_DIR/sessions/$name"
  [ ! -L "$path" ] && [ -f "$path/source" ] || { error "Unknown staged session"; exit 1; }
  source=$(cat "$path/source")
  validate_strict_host_path "Apply destination" "$source" || exit 1
  workspace_helper
  python3 "$WORKSPACE_HELPER" apply "$path"
}

start_broker() {
  local key token broker_image="agentbox-broker" file="$AGENTBOX_STATE_DIR/images/broker"
  [ ! -f "$file" ] || broker_image=$(cat "$file")
  [[ "$broker_image" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || { error "Invalid broker image"; exit 1; }
  if [ "$agent_runtime" = claude ]; then key="${ANTHROPIC_API_KEY:-}"; else key="${OPENAI_API_KEY:-}"; fi
  [ -n "$key" ] || { error "--broker requires an API key for the selected runtime; subscription login is not supported"; exit 1; }
  [[ ! "$key" =~ [[:cntrl:]] ]] || { error "API keys cannot contain control characters"; exit 1; }
  token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
  ensure_private_dir "$SESSION_DIR/broker-private"
  # JSON serialization never puts provider credentials in argv or Docker metadata.
  printf '%s\n%s\n%s\n' "$agent_runtime" "$key" "$token" | perl -MJSON::PP -e \
    'chomp(my @v=<STDIN>); print encode_json({runtime=>$v[0],key=>$v[1],token=>$v[2]})' > "$SESSION_DIR/broker-private/credentials.json"
  chmod 600 "$SESSION_DIR/broker-private/credentials.json"
  AGENTBOX_BROKER_TOKEN="$token"
  export AGENTBOX_BROKER_TOKEN
  broker_container="agentbox-broker-${SESSION_DIR##*/}"
  broker_socket_volume="agentbox-socket-${SESSION_DIR##*/}"
  # Keep Unix sockets on Linux-owned storage, including with Docker Desktop.
  docker volume create --label agentbox.managed=true --driver local \
    --opt type=tmpfs --opt device=tmpfs \
    --opt "o=uid=$CONTAINER_UID,gid=$CONTAINER_GID,mode=0700,size=1m" \
    "$broker_socket_volume" >/dev/null
  docker run -d --name "$broker_container" --label agentbox.managed=true \
    --user "$CONTAINER_UID:$CONTAINER_GID" --read-only --cap-drop=ALL \
    --security-opt=no-new-privileges --security-opt "seccomp=$SECCOMP_PROFILE" \
    --pids-limit 64 --memory 128m --cpus 1 \
    -v "$SESSION_DIR/broker-private:/credentials:ro" \
    -v "$broker_socket_volume:/socket" "$broker_image" \
    broker /socket/api.sock /credentials/credentials.json >/dev/null
  for _ in {1..50}; do
    if docker exec "$broker_container" /opt/agentbox/agentbox-broker probe-unix /socket/api.sock >/dev/null 2>&1; then return 0; fi
    sleep 0.1
  done
  error "Broker did not start; credentials will not be passed to the agent"; exit 1
}
