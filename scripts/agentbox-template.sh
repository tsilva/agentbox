#!/bin/bash
# =============================================================================
# agentbox-template.sh - Standalone script template
#
# This template is processed by do_install() which replaces
# PLACEHOLDER_IMAGE_NAME with the real value. The resulting script is installed to
# ~/.agentbox/bin/ and becomes the user-facing CLI.
# =============================================================================

# Abort on any error
set -euo pipefail

# Source terminal styling library (graceful fallback to plain echo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=style.sh
if [ -f "$SCRIPT_DIR/style.sh" ]; then
  source "$SCRIPT_DIR/style.sh"
fi

# Fallback to plain-text output if the styling helper is unavailable.
if ! declare -F warn >/dev/null; then
  section() { printf '\n== %s ==\n\n' "$1" >&2; }
  success() { printf '  ✓ %s\n' "$1" >&2; }
  error() { printf '  ✗ %s\n' "$1" >&2; }
  warn() { printf '  ! %s\n' "$1" >&2; }
  info() { printf '  • %s\n' "$1" >&2; }
  step() { printf '  -> %s\n' "$1" >&2; }
  note() { printf '  Note: %s\n' "$1" >&2; }
  error_block() {
    local line
    for line in "$@"; do
      printf '  %s\n' "$line" >&2
    done
  }
  list_item() { printf '  %s: %s\n' "$1" "$2" >&2; }
  choose() {
    local hdr="$1"
    shift
    local total="$#"
    local choice
    local idx=1
    local opt

    printf '  %s\n' "$hdr" >&2
    for opt in "$@"; do
      printf '  %s) %s\n' "$idx" "$opt" >&2
      idx=$((idx + 1))
    done

    while true; do
      printf '  [1-%s]: ' "$total" >&2
      read -r choice < /dev/tty
      if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
        break
      fi
      printf '  Invalid choice\n' >&2
    done

    idx=1
    for opt in "$@"; do
      if [ "$idx" -eq "$choice" ]; then
        printf '%s\n' "$opt"
        return 0
      fi
      idx=$((idx + 1))
    done
  }
fi

# Docker image name (replaced at install time by do_install)
IMAGE_NAME="PLACEHOLDER_IMAGE_NAME"

# Resource defaults (overridable via environment)
: "${TMPFS_TMP_SIZE:=1g}"
: "${TMPFS_CACHE_SIZE:=1g}"
: "${TMPFS_NPM_SIZE:=256m}"
: "${TMPFS_LOCAL_SIZE:=512m}"

# Default process limit to prevent fork bombs
DEFAULT_PIDS_LIMIT=256

host_id() {
  local flag="$1"

  if command -v id >/dev/null 2>&1; then
    id "$flag"
  elif [ -x /usr/bin/id ]; then
    /usr/bin/id "$flag"
  else
    return 1
  fi
}

CONTAINER_UID="${AGENTBOX_CONTAINER_UID:-${UID:-$(host_id -u)}}"
CONTAINER_GID="${AGENTBOX_CONTAINER_GID:-$(host_id -g)}"
if [ "$CONTAINER_UID" = "0" ]; then
  error_block "Refusing to run agentbox container as root." \
    "Run agentbox as a regular host user so private bind mounts can stay user-owned."
  exit 1
fi

# Seccomp profile path (for syscall filtering)
SECCOMP_PROFILE="$HOME/.agentbox/seccomp.json"

# Host Claude state is the source of truth for auth/account data. agentbox keeps
# isolated writable mirrors under ~/.agentbox/ and refreshes them before launch.
HOST_CLAUDE_DIR="$HOME/.claude"
HOST_CLAUDE_STATE_FILE="$HOME/.claude.json"
HOST_CREDENTIALS_FILE="$HOST_CLAUDE_DIR/.credentials.json"
HOST_KEYCHAIN_SERVICE="Claude Code-credentials"
HOST_CODEX_DIR="$HOME/.codex"
HOST_CODEX_AUTH_FILE="$HOST_CODEX_DIR/auth.json"
HOST_CODEX_CONFIG_FILE="$HOST_CODEX_DIR/config.toml"
AGENTBOX_STATE_DIR="$HOME/.agentbox"
TRUSTED_PROJECTS_DIR="$AGENTBOX_STATE_DIR/trusted-projects"
TRUSTED_ENTRYPOINT_FILE="$AGENTBOX_STATE_DIR/entrypoint.sh"
SANDBOX_CLAUDE_DIR="$AGENTBOX_STATE_DIR/claude-config"
SANDBOX_DOTCONFIG_DIR="$AGENTBOX_STATE_DIR/claude-dotconfig"
SANDBOX_PLUGINS_DIR="$AGENTBOX_STATE_DIR/plugins"
SANDBOX_CLAUDE_STATE_FILE="$AGENTBOX_STATE_DIR/.claude.json"
SANDBOX_CREDENTIALS_FILE="$SANDBOX_CLAUDE_DIR/.credentials.json"
SANDBOX_CODEX_DIR="$AGENTBOX_STATE_DIR/codex-config"
SANDBOX_CODEX_AUTH_FILE="$SANDBOX_CODEX_DIR/auth.json"
AUTHLESS_STATE_DIR="$AGENTBOX_STATE_DIR/authless-runtime"
AUTHLESS_DOTCONFIG_DIR="$AUTHLESS_STATE_DIR/claude-dotconfig"
AUTHLESS_CLAUDE_DIR="$AUTHLESS_STATE_DIR/claude-config"
AUTHLESS_PLUGINS_DIR="$AUTHLESS_STATE_DIR/plugins"
AUTHLESS_CLAUDE_STATE_FILE="$AUTHLESS_STATE_DIR/.claude.json"
AUTHLESS_CODEX_DIR="$AUTHLESS_STATE_DIR/codex-config"
EMPTY_RUNTIME_STATE_DIR="$AGENTBOX_STATE_DIR/empty-runtime"
EMPTY_DOTCONFIG_DIR="$EMPTY_RUNTIME_STATE_DIR/claude-dotconfig"
EMPTY_CLAUDE_DIR="$EMPTY_RUNTIME_STATE_DIR/claude-config"
EMPTY_PLUGINS_DIR="$EMPTY_RUNTIME_STATE_DIR/plugins"
EMPTY_CLAUDE_STATE_FILE="$EMPTY_RUNTIME_STATE_DIR/.claude.json"
EMPTY_CODEX_DIR="$EMPTY_RUNTIME_STATE_DIR/codex-config"
KEYCHAIN_AUTH_ERROR=""
HOST_KEYCHAIN_CREDENTIALS_JSON=""
ACTIVE_SANDBOX_DOTCONFIG_DIR="$SANDBOX_DOTCONFIG_DIR"
ACTIVE_SANDBOX_CLAUDE_DIR="$SANDBOX_CLAUDE_DIR"
ACTIVE_SANDBOX_CREDENTIALS_FILE="$SANDBOX_CREDENTIALS_FILE"
ACTIVE_SANDBOX_PLUGINS_DIR="$SANDBOX_PLUGINS_DIR"
ACTIVE_SANDBOX_CLAUDE_STATE_FILE="$SANDBOX_CLAUDE_STATE_FILE"
ACTIVE_SANDBOX_CODEX_DIR="$SANDBOX_CODEX_DIR"
ACTIVE_SANDBOX_CODEX_AUTH_FILE="$SANDBOX_CODEX_AUTH_FILE"
MOUNT_SANDBOX_DOTCONFIG_DIR="$SANDBOX_DOTCONFIG_DIR"
MOUNT_SANDBOX_CLAUDE_DIR="$SANDBOX_CLAUDE_DIR"
MOUNT_SANDBOX_PLUGINS_DIR="$SANDBOX_PLUGINS_DIR"
MOUNT_SANDBOX_CLAUDE_STATE_FILE="$SANDBOX_CLAUDE_STATE_FILE"
MOUNT_SANDBOX_CODEX_DIR="$SANDBOX_CODEX_DIR"

ensure_state_root() {
  if [ -L "$AGENTBOX_STATE_DIR" ]; then
    error "Refusing to use symlinked agentbox state directory: $AGENTBOX_STATE_DIR"
    exit 1
  fi

  mkdir -p "$AGENTBOX_STATE_DIR"
  chmod 700 "$AGENTBOX_STATE_DIR" 2>/dev/null || true
}

require_state_path() {
  local path="$1"

  case "$path" in
    "$AGENTBOX_STATE_DIR"|"$AGENTBOX_STATE_DIR"/*)
      return 0
      ;;
    *)
      error "Refusing to write outside agentbox state directory: $path"
      exit 1
      ;;
  esac
}

ensure_private_dir() {
  local dir="$1"

  require_state_path "$dir"
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
}

reset_private_dir() {
  local dir="$1"

  require_state_path "$dir"
  if [ "$dir" = "$AGENTBOX_STATE_DIR" ]; then
    error "Refusing to reset agentbox state root"
    exit 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
}

remove_private_path() {
  local path="$1"

  require_state_path "$path"
  rm -rf "$path" 2>/dev/null || true
}

sanitize_private_file_path() {
  local path="$1"

  require_state_path "$path"
  if [ -L "$path" ] || [ -d "$path" ]; then
    rm -rf "$path" 2>/dev/null || true
  fi
}

write_private_file_from_file() {
  local src="$1"
  local dest="$2"
  local parent tmp

  require_state_path "$dest"
  parent=$(dirname "$dest")
  ensure_private_dir "$parent"
  tmp=$(mktemp "$parent/.agentbox-write.XXXXXX")
  cp "$src" "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  rm -rf "$dest" 2>/dev/null || true
  mv "$tmp" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
}

write_private_file_content() {
  local dest="$1"
  local content="$2"
  local parent tmp

  require_state_path "$dest"
  parent=$(dirname "$dest")
  ensure_private_dir "$parent"
  tmp=$(mktemp "$parent/.agentbox-write.XXXXXX")
  printf '%s' "$content" > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  rm -rf "$dest" 2>/dev/null || true
  mv "$tmp" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
}

ensure_sandbox_state_dirs() {
  ensure_state_root
  ensure_private_dir "$SANDBOX_CLAUDE_DIR"
  ensure_private_dir "$SANDBOX_DOTCONFIG_DIR"
  ensure_private_dir "$SANDBOX_PLUGINS_DIR"
  ensure_private_dir "$SANDBOX_CLAUDE_DIR/plugins"
  ensure_private_dir "$SANDBOX_CLAUDE_DIR/plans"
  ensure_private_dir "$SANDBOX_CLAUDE_DIR/runtime"
  ensure_private_dir "$SANDBOX_CODEX_DIR"
  ensure_private_dir "$SANDBOX_CODEX_DIR/runtime"
  ensure_private_dir "$SANDBOX_CODEX_DIR/sessions"
  ensure_private_dir "$SANDBOX_CODEX_DIR/log"
  ensure_private_dir "$SANDBOX_CODEX_DIR/tmp"
}

# @launch-common
# @onboarding

sync_directory() {
  local src="$1"
  local dest="$2"

  reset_private_dir "$dest"
  if [ -d "$src" ]; then
    if command -v rsync &>/dev/null; then
      rsync -a --delete "$src"/ "$dest"/
    else
      cp -R "$src"/. "$dest"/
    fi
    chmod 700 "$dest" 2>/dev/null || true
  fi
}

json_input_has_auth_value() {
  perl -MJSON::PP -e '
    use strict;
    use warnings;

    local $/;
    my $content = <STDIN>;
    my $data = eval { decode_json($content) };
    exit 1 if $@ || ref($data) ne "HASH";

    my $oauth = $data->{claudeAiOauth};
    exit(
      ref($oauth) eq "HASH"
      && defined($oauth->{refreshToken})
      && $oauth->{refreshToken} ne ""
        ? 0
        : 1
    );
  ' >/dev/null 2>&1
}

json_file_has_auth_value() {
  local file="$1"

  [ -f "$file" ] || return 1
  json_input_has_auth_value < "$file"
}

json_string_has_auth_value() {
  local content="${1:-}"

  [ -n "$content" ] || return 1
  printf '%s' "$content" | json_input_has_auth_value
}

host_keychain_account() {
  if [ -n "${USER:-}" ]; then
    printf '%s\n' "$USER"
    return 0
  fi

  id -un 2>/dev/null || true
}

read_host_keychain_credentials() {
  local account keychain_output

  KEYCHAIN_AUTH_ERROR=""
  HOST_KEYCHAIN_CREDENTIALS_JSON=""
  account="$(host_keychain_account)"
  [ -n "$account" ] || return 1
  command -v security >/dev/null 2>&1 || return 1

  if keychain_output="$(security find-generic-password -a "$account" -s "$HOST_KEYCHAIN_SERVICE" -w 2>&1)"; then
    HOST_KEYCHAIN_CREDENTIALS_JSON="$keychain_output"
    return 0
  fi

  KEYCHAIN_AUTH_ERROR="$keychain_output"
  return 1
}

keychain_auth_available() {
  if read_host_keychain_credentials; then
    json_string_has_auth_value "$HOST_KEYCHAIN_CREDENTIALS_JSON"
  else
    return 1
  fi
}

keychain_auth_denied() {
  [ -n "$KEYCHAIN_AUTH_ERROR" ] || return 1

  case "$KEYCHAIN_AUTH_ERROR" in
    *"The specified item could not be found in the keychain."*)
      return 1
      ;;
  esac

  return 0
}

host_auth_available() {
  [ -n "${ANTHROPIC_API_KEY:-}" ] || json_file_has_auth_value "$HOST_CREDENTIALS_FILE" || keychain_auth_available
}

require_host_auth() {
  host_auth_available && return 0

  if keychain_auth_denied; then
    error_block "Host Claude login could not be read from macOS Keychain." \
      "Approve read access to '$HOST_KEYCHAIN_SERVICE' for the current user and retry." \
      "agentbox only reads that specific keychain item when ~/.claude/.credentials.json is absent."
    exit 1
  fi

  error_block "No host Claude login detected." \
    "Run 'claude' on the host and complete /login before starting agentbox."
  exit 1
}

codex_auth_available() {
  [ -s "$HOST_CODEX_AUTH_FILE" ] || [ -n "${OPENAI_API_KEY:-}" ]
}

require_codex_auth() {
  codex_auth_available && return 0

  error_block "No host Codex login detected." \
    "Run 'codex login' on the host, or export OPENAI_API_KEY before starting agentbox with --codex."
  exit 1
}

require_runtime_auth() {
  case "$agent_runtime" in
    claude)
      require_host_auth
      ;;
    codex)
      require_codex_auth
      ;;
    *)
      error "Unsupported runtime '$agent_runtime' (allowed: claude, codex)"
      exit 1
      ;;
  esac
}

sync_host_auth_state() {
  sanitize_private_file_path "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE"
  sanitize_private_file_path "$ACTIVE_SANDBOX_CREDENTIALS_FILE"

  # Host ~/.claude.json carries the current account and auth metadata. Copy it
  # into the sandbox mirror so each container launch starts from fresh host state.
  if [ -s "$HOST_CLAUDE_STATE_FILE" ]; then
    write_private_file_from_file "$HOST_CLAUDE_STATE_FILE" "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE"
  elif [ ! -s "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" ]; then
    write_private_file_content "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" "{}" 2>/dev/null || true
  fi

  # Claude Code may still use ~/.claude/.credentials.json on some installs. If
  # the host no longer has this file, remove any stale sandbox copy.
  if json_file_has_auth_value "$HOST_CREDENTIALS_FILE"; then
    write_private_file_from_file "$HOST_CREDENTIALS_FILE" "$ACTIVE_SANDBOX_CREDENTIALS_FILE"
  elif json_string_has_auth_value "$HOST_KEYCHAIN_CREDENTIALS_JSON"; then
    write_private_file_content "$ACTIVE_SANDBOX_CREDENTIALS_FILE" "$HOST_KEYCHAIN_CREDENTIALS_JSON" 2>/dev/null || true
  else
    remove_private_path "$ACTIVE_SANDBOX_CREDENTIALS_FILE"
  fi
}

sync_host_codex_state() {
  sanitize_private_file_path "$ACTIVE_SANDBOX_CODEX_AUTH_FILE"
  sanitize_private_file_path "$ACTIVE_SANDBOX_CODEX_DIR/config.toml"

  if [ -s "$HOST_CODEX_AUTH_FILE" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
    write_private_file_from_file "$HOST_CODEX_AUTH_FILE" "$ACTIVE_SANDBOX_CODEX_AUTH_FILE" 2>/dev/null || true
  else
    remove_private_path "$ACTIVE_SANDBOX_CODEX_AUTH_FILE"
  fi

  if [ -s "$HOST_CODEX_CONFIG_FILE" ]; then
    write_private_file_from_file "$HOST_CODEX_CONFIG_FILE" "$ACTIVE_SANDBOX_CODEX_DIR/config.toml"
  elif [ ! -e "$ACTIVE_SANDBOX_CODEX_DIR/config.toml" ]; then
    write_private_file_content "$ACTIVE_SANDBOX_CODEX_DIR/config.toml" "" 2>/dev/null || true
  fi
}

ensure_claude_md_link_for() {
  local claude_dir="$1"

  rm -rf "$claude_dir/CLAUDE.md"
  ln -s "runtime/CLAUDE.md" "$claude_dir/CLAUDE.md"
}

ensure_codex_agents_link_for() {
  local codex_dir="$1"

  rm -rf "$codex_dir/AGENTS.md"
  ln -s "runtime/AGENTS.md" "$codex_dir/AGENTS.md"
}

ensure_runtime_claude_md_link() {
  ensure_claude_md_link_for "$ACTIVE_SANDBOX_CLAUDE_DIR"
}

ensure_runtime_codex_agents_link() {
  ensure_codex_agents_link_for "$ACTIVE_SANDBOX_CODEX_DIR"
}

use_authless_sandbox_state() {
  ACTIVE_SANDBOX_DOTCONFIG_DIR="$AUTHLESS_DOTCONFIG_DIR"
  ACTIVE_SANDBOX_CLAUDE_DIR="$AUTHLESS_CLAUDE_DIR"
  ACTIVE_SANDBOX_CREDENTIALS_FILE="$AUTHLESS_CLAUDE_DIR/.credentials.json"
  ACTIVE_SANDBOX_PLUGINS_DIR="$AUTHLESS_PLUGINS_DIR"
  ACTIVE_SANDBOX_CLAUDE_STATE_FILE="$AUTHLESS_CLAUDE_STATE_FILE"
  ACTIVE_SANDBOX_CODEX_DIR="$AUTHLESS_CODEX_DIR"
  ACTIVE_SANDBOX_CODEX_AUTH_FILE="$AUTHLESS_CODEX_DIR/auth.json"

  reset_private_dir "$AUTHLESS_DOTCONFIG_DIR"
  reset_private_dir "$AUTHLESS_CLAUDE_DIR"
  ensure_private_dir "$AUTHLESS_CLAUDE_DIR/plugins"
  ensure_private_dir "$AUTHLESS_CLAUDE_DIR/plans"
  ensure_private_dir "$AUTHLESS_CLAUDE_DIR/runtime"
  reset_private_dir "$AUTHLESS_PLUGINS_DIR"
  reset_private_dir "$AUTHLESS_CODEX_DIR"
  ensure_private_dir "$AUTHLESS_CODEX_DIR/runtime"
  ensure_private_dir "$AUTHLESS_CODEX_DIR/sessions"
  ensure_private_dir "$AUTHLESS_CODEX_DIR/log"
  ensure_private_dir "$AUTHLESS_CODEX_DIR/tmp"
  write_private_file_content "$AUTHLESS_CLAUDE_STATE_FILE" "{}"
  write_private_file_content "$AUTHLESS_CODEX_DIR/config.toml" ""
}

prepare_sandbox_state() {
  case "$agent_runtime" in
    claude)
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        write_private_file_content "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" "{}"
      else sync_host_auth_state; fi
      ;;
    codex)
      sync_host_codex_state
      ;;
  esac
  prepare_sandbox_non_auth_state
}

prepare_sandbox_non_auth_state() {
  ensure_runtime_claude_md_link
  ensure_runtime_codex_agents_link
  # Extensions are host-managed snapshots, selected explicitly after preparation.
  # Claude Code expects valid JSON in the mirrored state file.
  sanitize_private_file_path "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE"
  if [ ! -s "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" ]; then
    write_private_file_content "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" "{}"
  fi
  chmod 600 "$ACTIVE_SANDBOX_CLAUDE_STATE_FILE" 2>/dev/null || true
}

prepare_empty_runtime_state() {
  reset_private_dir "$EMPTY_RUNTIME_STATE_DIR"
  ensure_private_dir "$EMPTY_DOTCONFIG_DIR"
  ensure_private_dir "$EMPTY_CLAUDE_DIR"
  ensure_private_dir "$EMPTY_CLAUDE_DIR/plugins"
  ensure_private_dir "$EMPTY_CLAUDE_DIR/plans"
  ensure_private_dir "$EMPTY_CLAUDE_DIR/runtime"
  ensure_private_dir "$EMPTY_PLUGINS_DIR"
  ensure_private_dir "$EMPTY_CODEX_DIR"
  ensure_private_dir "$EMPTY_CODEX_DIR/runtime"
  ensure_private_dir "$EMPTY_CODEX_DIR/sessions"
  ensure_private_dir "$EMPTY_CODEX_DIR/log"
  ensure_private_dir "$EMPTY_CODEX_DIR/tmp"
  write_private_file_content "$EMPTY_CLAUDE_STATE_FILE" "{}"
  write_private_file_content "$EMPTY_CODEX_DIR/config.toml" ""
  ensure_claude_md_link_for "$EMPTY_CLAUDE_DIR"
  ensure_codex_agents_link_for "$EMPTY_CODEX_DIR"
}

select_runtime_mounts() {
  MOUNT_SANDBOX_DOTCONFIG_DIR="$ACTIVE_SANDBOX_DOTCONFIG_DIR"
  MOUNT_SANDBOX_CLAUDE_DIR="$ACTIVE_SANDBOX_CLAUDE_DIR"
  MOUNT_SANDBOX_PLUGINS_DIR="${PLUGIN_SNAPSHOT:-$ACTIVE_SANDBOX_PLUGINS_DIR}"
  MOUNT_SANDBOX_CLAUDE_STATE_FILE="$ACTIVE_SANDBOX_CLAUDE_STATE_FILE"
  MOUNT_SANDBOX_CODEX_DIR="$ACTIVE_SANDBOX_CODEX_DIR"

  case "$agent_runtime" in
    claude)
      MOUNT_SANDBOX_CODEX_DIR="$EMPTY_CODEX_DIR"
      ;;
    codex)
      MOUNT_SANDBOX_DOTCONFIG_DIR="$EMPTY_DOTCONFIG_DIR"
      MOUNT_SANDBOX_CLAUDE_DIR="$EMPTY_CLAUDE_DIR"
      MOUNT_SANDBOX_PLUGINS_DIR="$EMPTY_PLUGINS_DIR"
      MOUNT_SANDBOX_CLAUDE_STATE_FILE="$EMPTY_CLAUDE_STATE_FILE"
      ;;
  esac
}

# --- Argument parsing ---
# Arrays and variables for building the docker run command
entrypoint_args=()     # Override entrypoint (used for "shell" command)
extra_mounts=()        # Additional -v mounts from profile config
extra_mounts_info=""   # Human-readable mount info for sandbox awareness
extra_ports=()         # Additional -p ports from profile config
workdir="$(pwd)"       # Mount the current directory as the working directory
requested_workdir="$workdir"
original_arg_count=$#
runtime_explicit=false
mode_explicit=false
access_explicit=false
init_mode=false
profile_extra_grants=false
profile_name=""        # Selected profile from .agentbox.json
agent_runtime=""       # Selected agent runtime: claude or codex
cmd_args=()            # Arguments forwarded to Claude Code inside the container
first_cmd=""           # First non-flag argument (used to detect "shell" command)
skip_next=false        # Flag to skip the next argument (used for --profile value)
runtime_skip_next=false # Flag to skip the next argument (used for --runtime value)
dry_run=false          # When true, print the docker command instead of running it
audit_log=false        # When true, keep named container and dump logs on exit
readonly_mode=false    # When true, mount all host paths as read-only
print_mode=false       # When true, the runtime is in non-interactive mode (no TTY needed)
allow_project_dockerfile=false  # When true, permit trusted per-project image builds
launch_mode="edit"
broker_mode=false
plugins_enabled=false
staged_mode=false
inspect_mode=false
parse_agent_args=false
SESSION_DIR=""
broker_container=""
broker_socket_volume=""
container_name=""
PLUGIN_SNAPSHOT=""

# Extract our flags (--profile, --dry-run), pass everything else to Claude
for arg in "$@"; do
  if [ "$parse_agent_args" = true ]; then
    [ -n "$first_cmd" ] || first_cmd="$arg"
    if [ "$arg" = -p ] || [ "$arg" = --print ]; then print_mode=true; fi
    cmd_args+=("$arg")
  elif [ "$arg" = "--" ]; then
    parse_agent_args=true
  elif [ "$skip_next" = true ]; then
    # This arg is the value for --profile/-P
    profile_name="$arg"
    skip_next=false
  elif [ "$runtime_skip_next" = true ]; then
    # This arg is the value for --runtime
    agent_runtime="$arg"
    runtime_skip_next=false
  elif [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
    show_help; exit 0
  elif [ "$arg" = "--broker" ]; then
    broker_mode=true
    access_explicit=true
  elif [ "$arg" = "--direct" ]; then
    broker_mode=false
    access_explicit=true
  elif [ "$arg" = "--plugins" ]; then
    plugins_enabled=true
  elif [ "$arg" = "--staged" ]; then
    staged_mode=true
  elif [ "$arg" = "--profile" ] || [ "$arg" = "-P" ]; then
    # Next arg will be the profile name
    skip_next=true
  elif [ "$arg" = "--runtime" ]; then
    # Next arg will be the runtime name
    runtime_skip_next=true
  elif [ "$arg" = "--codex" ]; then
    # Shortcut for --runtime codex
    agent_runtime="codex"
  elif [ "$arg" = "--claude" ]; then
    # Explicitly select the default Claude runtime
    agent_runtime="claude"
  elif [ "$arg" = "--dry-run" ]; then
    # Enable dry-run mode: print command without executing
    dry_run=true
  elif [ "$arg" = "--readonly" ]; then
    # Enable readonly mode: all host mounts become read-only
    readonly_mode=true
  elif [ "$arg" = "--allow-project-dockerfile" ]; then
    # Explicitly allow a repo-controlled Dockerfile to run build steps
    allow_project_dockerfile=true
  elif [ -z "$first_cmd" ] && [[ "$arg" =~ ^(review|edit|offline)$ ]]; then
    launch_mode="$arg"
    mode_explicit=true
  elif [ -z "$first_cmd" ] && [ "$arg" = "inspect" ]; then
    inspect_mode=true
    dry_run=true
  else
    # Track the first non-flag arg to detect the "shell" command
    [ -z "$first_cmd" ] && first_cmd="$arg"
    # Detect -p/--print for TTY allocation (print mode runs non-interactively)
    if [ "$arg" = "-p" ] || [ "$arg" = "--print" ]; then
      print_mode=true
    fi
    cmd_args+=("$arg")
  fi
done

if [ "$skip_next" = true ]; then
  error "--profile requires a value"
  exit 1
fi
if [ "$runtime_skip_next" = true ]; then
  error "--runtime requires a value"
  exit 1
fi
if [ -n "$agent_runtime" ] && [[ ! "$agent_runtime" =~ ^(claude|codex)$ ]]; then
  error "Unsupported runtime '$agent_runtime' (allowed: claude, codex)"
  exit 1
fi
[ -z "$agent_runtime" ] || runtime_explicit=true
[ "$first_cmd" != init ] || init_mode=true
project_document=""
project_original=""
project_profiles='{}'
project_versioned=false
project_runtime=""
project_default_profile=""
# Project setup and launches consistently use the checkout root, including from subdirectories.
case "$first_cmd" in setup|plugins|apply) ;;
  *)
    project_root=$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null || true)
    if [[ "$project_root" == /* ]] && [ -d "$project_root" ]; then workdir="$project_root"; cd "$workdir"; fi
    case "$first_cmd:${cmd_args[1]:-}" in untrust:*|trust:--list) ;; *) load_project_config ;; esac
    ;;
esac
if [ -z "$agent_runtime" ]; then agent_runtime="${project_runtime:-$(read_preferred_runtime)}"; fi
if [ -z "$profile_name" ]; then profile_name="$project_default_profile"; fi
select_installed_image
if [ "$first_cmd" = setup ]; then
  ensure_state_root
  write_private_file_content "$AGENTBOX_STATE_DIR/default-runtime" "$agent_runtime"
  success "Preferred runtime: $agent_runtime"; exit 0
elif [ "$first_cmd" = doctor ]; then
  doctor; exit $?
elif [ "$first_cmd" = plugins ]; then
  [ "${cmd_args[1]:-}" = refresh ] || { error "Usage: agentbox plugins refresh"; exit 1; }
  refresh_plugins; exit 0
fi
if [ "$original_arg_count" -eq 0 ] && [ -z "$project_document" ]; then
  error 'Project is not initialized. Run agentbox init.'; exit 1
fi

# Codex uses `codex exec` for non-interactive prompts. Preserve the familiar
# agentbox/Claude `-p "prompt"` shortcut when the Codex runtime is selected.
if [ "$agent_runtime" = "codex" ] && { [ "${cmd_args[0]:-}" = "-p" ] || [ "${cmd_args[0]:-}" = "--print" ]; }; then
  codex_prompt="${cmd_args[1]:-}"
  if [ -z "$codex_prompt" ]; then
    error "--codex -p requires a prompt"
    exit 1
  fi
  cmd_args=(exec "$codex_prompt" "${cmd_args[@]:2}")
  first_cmd="exec"
  print_mode=true
elif [ "$agent_runtime" = "codex" ] && { [ "$first_cmd" = "exec" ] || [ "$first_cmd" = "review" ]; }; then
  print_mode=true
fi

# Handle "shell" command: override entrypoint to bash for interactive inspection
if [ "$first_cmd" = "shell" ]; then
  entrypoint_args=(--entrypoint /bin/bash)
  # Remove "shell" from cmd_args so it isn't passed to bash
  cmd_args=("${cmd_args[@]:1}")
fi

# Handle "update" command: pull latest source and reinstall
if [ "$first_cmd" = "update" ]; then
  repo_path=""
  # Try curl-install clone dir first (a directory), then dev-install breadcrumb (a file with path inside)
  if [ -d "$HOME/.agentbox/repo" ]; then
    repo_path="$HOME/.agentbox/repo"
  elif [ -f "$HOME/.agentbox/.repo-path" ]; then
    repo_path=$(<"$HOME/.agentbox/.repo-path")
  fi
  if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
    error_block "Cannot find agentbox source directory" \
      "Reinstall agentbox from the repo to enable updates."
    exit 1
  fi
  step "Updating from $repo_path"

  # Capture HEAD before/after git pull to detect repo changes
  git_before=$(git -C "$repo_path" rev-parse HEAD)
  git -C "$repo_path" pull --ff-only
  git_after=$(git -C "$repo_path" rev-parse HEAD)

  # Check if upstream Claude Code version differs from installed
  installed_version=""
  latest_version=""
  version_file="$HOME/.agentbox/version"
  if [ -f "$version_file" ]; then
    installed_version=$(<"$version_file")
  fi
  latest_version=$(curl -fsSL --max-time 5 \
    "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest" 2>/dev/null) || true

  codex_installed=""
  [ ! -f "$HOME/.agentbox/version-codex" ] || codex_installed=$(cat "$HOME/.agentbox/version-codex")
  codex_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/openai/codex/releases/latest 2>/dev/null | perl -MJSON::PP -0777 -ne 'eval { print decode_json($_)->{tag_name} }') || true
  if [ "$agent_runtime" = codex ]; then
    installed_version="$codex_installed"
    latest_version="$codex_latest"
  fi
  # Compare the selected runtime with its own upstream release.
  if [ "$git_before" = "$git_after" ] && [ -n "$installed_version" ] && [ -n "$latest_version" ] && [ "$installed_version" = "$latest_version" ]; then
    info "Already up to date"
    exit 0
  fi

  rm -f "$HOME/.agentbox/.latest-version" "$HOME/.agentbox/.latest-version-codex"
  exec "$repo_path/install.sh" --update --runtime "$agent_runtime"
fi

# --- Version staleness check ---
# Warn the user if a newer Claude Code version is available upstream.
# Uses a 24h-cached check against the GCS latest endpoint.
check_version_staleness() {
  local installed_version latest_version cache_file cache_age now file_mtime
  local version_file="$HOME/.agentbox/version"
  cache_file="$HOME/.agentbox/.latest-version"
  if [ "$agent_runtime" = codex ]; then
    version_file="$HOME/.agentbox/version-codex"
    cache_file="$HOME/.agentbox/.latest-version-codex"
  fi

  command -v date >/dev/null 2>&1 || return 0

  # No version file means pre-version-tracking build — skip silently
  [ -f "$version_file" ] || return 0
  installed_version=$(<"$version_file")
  [ -n "$installed_version" ] || return 0

  # Check if cache is fresh (< 24h)
  if [ -f "$cache_file" ]; then
    now=$(date +%s)
    # macOS stat uses -f %m, Linux uses -c %Y
    if stat -f %m "$cache_file" >/dev/null 2>&1; then
      file_mtime=$(stat -f %m "$cache_file" 2>/dev/null)
    else
      file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    fi
    cache_age=$(( now - file_mtime ))
    if [ "$cache_age" -lt 86400 ]; then
      latest_version=$(<"$cache_file")
    fi
  fi

  # Fetch from upstream if cache is stale or missing
  if [ -z "${latest_version:-}" ]; then
    if [ "$agent_runtime" = codex ]; then
      latest_version=$(curl -fsSL --max-time 2 https://api.github.com/repos/openai/codex/releases/latest 2>/dev/null | perl -MJSON::PP -0777 -ne 'eval { print decode_json($_)->{tag_name} }') || true
    else
      latest_version=$(curl -fsSL --max-time 2 \
        "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest" 2>/dev/null) || true
    fi
    if [ -n "$latest_version" ]; then
      mkdir -p "$HOME/.agentbox"
      printf '%s' "$latest_version" > "$cache_file"
    else
      # Fetch failed — fall back to stale cache
      [ -f "$cache_file" ] && latest_version=$(<"$cache_file")
    fi
  fi

  # Compare versions
  [ -n "${latest_version:-}" ] || return 0
  if [ "$installed_version" != "$latest_version" ]; then
    warn "update available ($installed_version → $latest_version) — run: agentbox update"
  fi
}
[ "$print_mode" = false ] && [ "$dry_run" = false ] && [ "$init_mode" = false ] && [ "$first_cmd" != trust ] && [ "$first_cmd" != untrust ] && check_version_staleness

# --- Dangerous path blocklist ---
# These paths are blocked to prevent exposing sensitive host system data
BLOCKED_PATHS=(
  # Root filesystem
  "/"
  # System directories
  "/bin" "/boot" "/dev" "/etc" "/lib" "/lib32" "/lib64" "/libx32"
  "/opt" "/proc" "/root" "/run" "/sbin" "/srv" "/sys" "/usr" "/var"
  # Sensitive user directories (credentials/keys)
  "$HOME/.ssh" "$HOME/.gnupg" "$HOME/.aws" "$HOME/.azure" "$HOME/.gcloud"
  "$HOME/.config/gcloud" "$HOME/.kube" "$HOME/.docker" "$HOME/.npmrc"
  "$HOME/.netrc" "$HOME/.password-store" "$HOME/.local/share/keyrings"
  "$HOME/.config/gh" "$HOME/.git-credentials" "$HOME/.pypirc" "$HOME/.npm"
  "$HOME/.cargo/credentials" "$HOME/.cargo/credentials.toml" "$HOME/.gem/credentials"
  "$HOME/.m2/settings.xml" "$HOME/.gradle/gradle.properties"
  "$HOME/Library" "$HOME/.1password" "$HOME/.bitwarden" "$HOME/.config/Bitwarden"
  # Agent-specific state (already managed)
  "$HOME/.claude" "$HOME/.codex" "$HOME/.agentbox"
)

normalize_path() {
  local p="$1"
  local normalized="${p/#\~/$HOME}"
  while [[ "$normalized" == *"//"* ]]; do
    normalized="${normalized//\/\//\/}"
  done
  while [[ "$normalized" != "/" && "$normalized" == */ ]]; do
    normalized="${normalized%/}"
  done
  [ -n "$normalized" ] || normalized="/"
  echo "$normalized"
}

resolve_physical_path() {
  local normalized="$1"

  if [ -d "$normalized" ]; then
    (
      cd -P "$normalized" >/dev/null 2>&1 || exit 1
      pwd -P
    )
  elif [ -e "$normalized" ]; then
    local parent_dir base_name
    parent_dir=$(dirname "$normalized")
    base_name=$(basename "$normalized")
    (
      cd -P "$parent_dir" >/dev/null 2>&1 || exit 1
      printf '%s/%s\n' "$(pwd -P)" "$base_name"
    )
  else
    return 1
  fi
}

path_has_symlink_hop() {
  local normalized="$1"
  local prefix="/"
  local remainder component

  [[ "$normalized" == /* ]] || return 1
  remainder="${normalized#/}"
  [ -n "$remainder" ] || return 1

  while [ -n "$remainder" ]; do
    component="${remainder%%/*}"
    if [ "$component" = "$remainder" ]; then
      remainder=""
    else
      remainder="${remainder#*/}"
    fi
    [ -n "$component" ] || continue

    if [ "$prefix" = "/" ]; then
      prefix="/$component"
    else
      prefix="$prefix/$component"
    fi

    [ -L "$prefix" ] && return 0
  done

  return 1
}

BLOCKED_PATH_ALIASES=("${BLOCKED_PATHS[@]}")
for blocked_path in "${BLOCKED_PATHS[@]}"; do
  blocked_physical=$(resolve_physical_path "$blocked_path" 2>/dev/null || true)
  if [ -n "$blocked_physical" ] && [ "$blocked_physical" != "$blocked_path" ]; then
    BLOCKED_PATH_ALIASES+=("$blocked_physical")
  fi
done

is_same_or_descendant_path() {
  local candidate="$1"
  local parent="$2"

  [[ "$candidate" == "$parent" ]] && return 0
  # Treat "/" as exact-match only so normal absolute paths remain mountable.
  [ "$parent" = "/" ] && return 1
  [[ "$candidate" == "$parent"/* ]]
}

is_hidden_home_path() {
  local candidate="$1"
  local rel first_component

  [ "$candidate" = "$HOME" ] && return 1
  [[ "$candidate" == "$HOME"/* ]] || return 1

  rel="${candidate#"$HOME"/}"
  first_component="${rel%%/*}"
  [[ "$first_component" == .* ]]
}

is_path_blocked() {
  local normalized="$1"
  for blocked in "${BLOCKED_PATH_ALIASES[@]}"; do
    if is_same_or_descendant_path "$normalized" "$blocked" || \
      is_same_or_descendant_path "$blocked" "$normalized"; then
      return 0
    fi
  done
  if is_hidden_home_path "$normalized"; then
    return 0
  fi
  return 1
}

report_symlink_policy_error() {
  local label="$1"
  local path="$2"
  local note_msg="${3:-}"
  local normalized physical

  normalized=$(normalize_path "$path")
  physical=$(resolve_physical_path "$normalized" 2>/dev/null || true)

  if [ -n "$physical" ] && [ "$physical" != "$normalized" ]; then
    error "$label traverses a symlink (security policy): $path → $physical"
  else
    error "$label traverses a symlink (security policy): $path"
  fi

  [ -n "$note_msg" ] && note "$note_msg"
}

validate_strict_host_path() {
  local label="$1"
  local path="$2"
  local note_msg="${3:-}"
  local normalized physical

  normalized=$(normalize_path "$path")
  if [[ "$normalized" != /* ]]; then
    error "$label must be an absolute path: $path"
    [ -n "$note_msg" ] && note "$note_msg"
    return 1
  fi
  if [[ "$normalized" == *:* ]]; then
    error "$label contains ':' and cannot be used safely in a Docker bind mount: $path"
    [ -n "$note_msg" ] && note "$note_msg"
    return 1
  fi
  if [[ "$normalized" =~ [[:cntrl:]] ]]; then
    error "$label contains invalid control characters"
    [ -n "$note_msg" ] && note "$note_msg"
    return 1
  fi
  if is_path_blocked "$normalized"; then
    error "$label blocked (security policy): $path"
    [ -n "$note_msg" ] && note "$note_msg"
    return 1
  fi

  if path_has_symlink_hop "$normalized"; then
    report_symlink_policy_error "$label" "$path" "$note_msg"
    return 1
  fi

  physical=$(resolve_physical_path "$normalized" 2>/dev/null || true)
  if [ -n "$physical" ] && is_path_blocked "$physical"; then
    error "$label blocked after path resolution (security policy): $path → $physical"
    [ -n "$note_msg" ] && note "$note_msg"
    return 1
  fi

  return 0
}

if [ "$first_cmd" = apply ]; then
  apply_staged_session "${cmd_args[1]:-}"; exit 0
fi

# Validate both the invocation path and implicit workspace before building Docker args.
if ! validate_strict_host_path "Working directory" "$requested_workdir" \
  "Run agentbox from the canonical path directly"; then exit 1; fi
if ! validate_strict_host_path "Working directory" "$workdir" \
  "Run agentbox from the canonical path directly"; then
  exit 1
fi

trusted_project_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$workdir" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$workdir" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$workdir" | cksum | awk '{print $1 "-" $2}'
  fi
}

trusted_project_record() {
  printf '%s/%s\n' "$TRUSTED_PROJECTS_DIR" "$(trusted_project_key)"
}

path_identity() {
  local path="$1"
  local identity

  identity=$(stat -f '%d:%i' "$path" 2>/dev/null || true)
  if [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$identity"
    return 0
  fi

  stat -c '%d:%i' "$path"
}

file_digest() {
  local path="$1"

  if [ ! -f "$path" ]; then
    printf 'absent'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    cksum "$path" | awk '{print $1 ":" $2}'
  fi
}

project_identity() {
  local git_top_level git_dir git_origin

  printf 'version=2\n'
  printf 'path=%s\n' "$workdir"
  printf 'workdir_id=%s\n' "$(path_identity "$workdir")"

  if git -C "$workdir" rev-parse --show-toplevel >/dev/null 2>&1; then
    git_top_level="$(cd "$workdir" && git rev-parse --show-toplevel)"
    git_dir="$(cd "$workdir" && git rev-parse --absolute-git-dir)"
    git_origin="$(git -C "$workdir" config --get remote.origin.url 2>/dev/null || true)"

    printf 'git_present=true\n'
    printf 'git_top_level=%s\n' "$git_top_level"
    printf 'git_top_level_id=%s\n' "$(path_identity "$git_top_level")"
    printf 'git_dir=%s\n' "$git_dir"
    printf 'git_dir_id=%s\n' "$(path_identity "$git_dir")"
    printf 'git_origin=%s\n' "$git_origin"
  else
    printf 'git_present=false\n'
  fi

  printf 'agentbox_json_sha256=%s\n' "$(file_digest "$workdir/.agentbox.json")"
  printf 'agentbox_dockerfile_sha256=%s\n' "$(file_digest "$workdir/.agentbox.Dockerfile")"
}

record_project_path() {
  local record="$1"

  if grep -q '^path=' "$record" 2>/dev/null; then
    sed -n 's/^path=//p' "$record" | head -n 1
  else
    cat "$record"
  fi
}

is_project_trusted() {
  local record expected actual
  record="$(trusted_project_record)"
  [ -f "$record" ] || return 1

  expected="$(project_identity)"
  actual="$(cat "$record")"
  [ "$actual" = "$expected" ]
}

trust_project() {
  local record identity="${1:-$(project_identity)}"
  ensure_private_dir "$TRUSTED_PROJECTS_DIR"
  record="$(trusted_project_record)"
  write_private_file_content "$record" "$identity"
  success "Trusted project: $workdir"
}

untrust_project() {
  local record
  record="$(trusted_project_record)"
  if [ -f "$record" ]; then
    rm -f "$record"
    remove_private_path "$AGENTBOX_STATE_DIR/project-grants/$(trusted_project_key)"
    success "Untrusted project: $workdir"
  else
    info "Project was not trusted: $workdir"
  fi
}

list_trusted_projects() {
  local record records

  if [ ! -d "$TRUSTED_PROJECTS_DIR" ]; then
    info "No trusted projects"
    return 0
  fi

  records=""
  for record in "$TRUSTED_PROJECTS_DIR"/*; do
    [ -f "$record" ] || continue
    records+=$(record_project_path "$record")
    records+=$'\n'
  done

  if [ -n "$records" ]; then
    printf '%s' "$records" | LC_ALL=C sort
  else
    info "No trusted projects"
  fi

}

if [ "$first_cmd" = trust ] && [ "${cmd_args[1]:-}" = --list ]; then
  list_trusted_projects; exit 0
elif [ "$first_cmd" = untrust ]; then
  untrust_project; exit 0
fi
if [ "$init_mode" = true ]; then prepare_project_init; fi

# --- Per-project configuration (.agentbox.json) ---
if [ -n "$project_document" ]; then
    # Count available profiles (root-level keys in the JSON object)
    profile_count=$(project_config_jq 'keys | length')

    # If no profile was specified via flag, auto-select or prompt interactively
    if [ -z "$profile_name" ] && [ "$profile_count" -eq 1 ]; then
      profile_name=$(project_config_jq -r 'keys[0]')
    elif [ -z "$profile_name" ] && [ "$profile_count" -gt 1 ]; then
      # Read profile names into an array for the selection menu (compatible with Bash 3)
      profile_array=()
      while IFS= read -r _p; do profile_array+=("$_p"); done < <(project_config_jq -r 'keys[]')
      [ -t 0 ] && [ -t 1 ] && [ "$print_mode" = false ] && [ "$dry_run" = false ] || {
        error 'Multiple profiles require --profile in unattended or preview mode'; exit 1;
      }
      profile_name=$(choose "Select profile:" "${profile_array[@]}")
    fi

    # Validate the selected profile exists in the config
    if [ -n "$profile_name" ]; then
      if ! project_config_jq -e --arg p "$profile_name" 'has($p)' &>/dev/null; then
        error "Profile '$profile_name' not found"
        note "Available: $(project_config_jq -r 'keys | join(", ")')"
        exit 1
      fi

      if [ "$project_versioned" != true ]; then info "Using profile: $profile_name"; fi
      if [ "$mode_explicit" = false ]; then launch_mode=$(project_config_jq -r --arg p "$profile_name" '.[$p].mode // "edit"'); fi
      if [ "$access_explicit" = false ] && [ "$launch_mode" != offline ]; then
        [ "$(project_config_jq -r --arg p "$profile_name" '.[$p].access // "direct"')" != broker ] || broker_mode=true
      fi

      # Extract all profile settings in a single jq call for efficiency.
      # Produces a normalized JSON object with mounts, ports, and scalar options.
      profile_config=$(project_config_jq -r --arg p "$profile_name" '
        .[($p)] | {
          mounts: [(.mounts // [])[] | {path: .path, readonly: (.readonly // false)}],
          ports: [(.ports // [])[] | (.host|tostring) + ":" + (.container|tostring)],
          network: (.network // "bridge"),
          audit_log: (.audit_log // false),
          cpu: (.cpu // null),
          memory: (.memory // null),
          pids_limit: (.pids_limit // null),
          ulimit_nofile: (.ulimit_nofile // null),
          ulimit_fsize: (.ulimit_fsize // null)
        }
      ')

      if [ -z "$profile_config" ]; then
        error "Failed to parse profile '$profile_name' from .agentbox.json"
        exit 1
      fi
      profile_extra_grants=$(printf '%s' "$profile_config" | jq -r '(.mounts | length) > 0 or (.ports | length) > 0')

      # Parse mount specifications and validate each one
      while IFS= read -r mount_json; do
        # Skip empty lines from jq output
        [ -z "$mount_json" ] && continue
        mount_path_type=$(printf '%s' "$mount_json" | jq -r '.path | type')
        if [ "$mount_path_type" != "string" ]; then
          error "Skipping mount with invalid path"; exit 1
        fi
        readonly_type=$(printf '%s' "$mount_json" | jq -r '.readonly | type')
        if [ "$readonly_type" != "boolean" ]; then
          error "Skipping mount with invalid readonly flag"; exit 1
        fi
        mount_path=$(printf '%s' "$mount_json" | jq -r '.path')
        mount_readonly=false
        if printf '%s' "$mount_json" | jq -e '.readonly == true' >/dev/null; then
          mount_readonly=true
        fi
        # Normalize path once for blocklist checks
        normalized_path=$(normalize_path "$mount_path")
        # Reject paths with colons (ambiguous Docker mount syntax)
        if [[ "$normalized_path" != /* ]]; then
          error "Skipping mount path that is not absolute: $mount_path"; exit 1
        elif [[ "$mount_path" == *:* ]]; then
          error "Skipping mount path containing ':': $mount_path"; exit 1
        # Reject paths with path traversal sequences (../)
        elif [[ "$mount_path" =~ (^|/)\.\.($|/) ]]; then
          error "Skipping mount with path traversal: $mount_path"; exit 1
        # Reject paths with control characters (potential injection)
        elif [[ "$mount_path" =~ [[:cntrl:]] ]]; then
          error "Skipping mount with invalid characters"; exit 1
        # Check against dangerous path blocklist
        elif is_path_blocked "$normalized_path"; then
          error "Skipping mount path blocked by security policy: $mount_path"
          exit 1
        # Reject any symlink hop in the source path
        elif path_has_symlink_hop "$normalized_path"; then
          report_symlink_policy_error "Skipping mount path" "$mount_path" \
            "Specify the canonical path directly"
          exit 1
        # Warn if the host path doesn't exist (Docker would create it as root)
        elif [ ! -e "$mount_path" ]; then
          error "Mount path does not exist: $mount_path"
          note "Create it with: mkdir -p $mount_path"
          exit 1
        else
          resolved_mount_path=$(resolve_physical_path "$normalized_path" 2>/dev/null || true)
          if [ -n "$resolved_mount_path" ] && is_path_blocked "$resolved_mount_path"; then
            error "Skipping mount path blocked after path resolution (security policy): $mount_path → $resolved_mount_path"
            exit 1
          fi

          validated_mount_spec="$normalized_path:$normalized_path"
          $mount_readonly && validated_mount_spec="${validated_mount_spec}:ro"
          # Valid mount — add to the docker run arguments
          extra_mounts+=(-v "$validated_mount_spec")
          # Build human-readable mount info for sandbox awareness
          if $mount_readonly; then
            extra_mounts_info+="- \`$normalized_path\` (read-only)"$'\n'
          else
            extra_mounts_info+="- \`$normalized_path\` (read-write)"$'\n'
          fi
        fi
      done < <(echo "$profile_config" | jq -c '.mounts[]')

      # Parse port specifications and validate ranges
      while IFS= read -r port_spec; do
        # Skip empty lines from jq output
        [ -z "$port_spec" ] && continue
        # Split host:container port pair
        host_port="${port_spec%%:*}"
        container_port="${port_spec##*:}"
        # Validate both ports are numeric
        if ! [[ "$host_port" =~ ^[0-9]+$ ]] || ! [[ "$container_port" =~ ^[0-9]+$ ]]; then
          error "Invalid port specification: $port_spec"; exit 1
        # Validate ports are in the valid TCP/UDP range
        elif [ "$host_port" -lt 1 ] || [ "$host_port" -gt 65535 ] || [ "$container_port" -lt 1 ] || [ "$container_port" -gt 65535 ]; then
          error "Port out of range (1-65535): $port_spec"; exit 1
        else
          # Bind to localhost only (127.0.0.1) to prevent external access
          extra_ports+=(-p "127.0.0.1:$port_spec")
        fi
      done < <(echo "$profile_config" | jq -r '.ports[]')



# Parse all scalar configuration values in a single jq call.
      # Use "_" as sentinel for null/false to prevent bash read from collapsing
      # consecutive tab delimiters (bash treats multiple IFS chars as one).
      IFS=$'\t' read -r network_mode audit_log profile_cpu profile_memory \
        profile_pids_limit profile_ulimit_nofile profile_ulimit_fsize \
        < <(echo "$profile_config" | jq -r '[.network, .audit_log, .cpu, .memory, .pids_limit, .ulimit_nofile, .ulimit_fsize] | map(if . == null then "_" elif . == false then "false" elif . == true then "true" else tostring end) | @tsv')
      # Convert sentinel values back to empty strings
      [[ "$network_mode" == "_" ]] && network_mode=""
      [[ "$audit_log" == "_" ]] && audit_log=""
      [[ "$profile_cpu" == "_" ]] && profile_cpu=""
      [[ "$profile_memory" == "_" ]] && profile_memory=""
      [[ "$profile_pids_limit" == "_" ]] && profile_pids_limit=""
      [[ "$profile_ulimit_nofile" == "_" ]] && profile_ulimit_nofile=""
      [[ "$profile_ulimit_fsize" == "_" ]] && profile_ulimit_fsize=""
    fi
else
  if [ -n "$profile_name" ]; then
    error "--profile '$profile_name' specified but no .agentbox.json found in $(pwd)"
    exit 1
  fi
fi

[ "$launch_mode" != review ] || readonly_mode=true

# --- Git read-only .git mount ---
# When inside a git repo, mount .git as read-only to prevent commits.
# Without SSH keys or git credentials in the container, pushes fail anyway.
git_dir=""
if git -C "$workdir" rev-parse --git-dir &>/dev/null; then
  git_dir="$(cd "$workdir" && git rev-parse --absolute-git-dir)"
  if ! validate_strict_host_path "Git directory" "$git_dir" \
    "Use the repository's canonical .git path directly"; then
    exit 1
  fi
  extra_mounts+=(-v "$git_dir:$git_dir:ro")
else
  warn "Not inside a git repository. Working directory will be writable."
fi

# --- Network mode ---
# Default is "bridge" (normal Docker networking); "none" disables all networking
network_args=()
[[ ! "${network_mode:-bridge}" =~ ^(bridge|none)$ ]] && { error "Unsupported network mode '$network_mode' (allowed: bridge, none)"; exit 1; }
[[ "${network_mode:-}" == "none" ]] && network_args=(--network none)

# --- Resource limit validation ---
if [[ "${profile_cpu:-}" =~ ^0+(\.0+)?$ ]] || [[ "${profile_memory:-}" =~ ^0+[bkmgBKMG]?$ ]] || [ "${profile_pids_limit:-1}" = 0 ]; then
  error "Resource limits must be greater than zero"; exit 1
fi
if [ -n "${profile_cpu:-}" ] && ! [[ "$profile_cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  error "Invalid cpu format '$profile_cpu' (expected: integer or decimal, e.g. '4' or '1.5')"; exit 1
fi
if [ -n "${profile_memory:-}" ] && ! [[ "$profile_memory" =~ ^[0-9]+[bkmgBKMG]?$ ]]; then
  error "Invalid memory format '$profile_memory' (expected: number with optional unit, e.g. '4g' or '512m')"; exit 1
fi
if [ -n "${profile_pids_limit:-}" ] && ! [[ "$profile_pids_limit" =~ ^[0-9]+$ ]]; then
  error "Invalid pids_limit format '$profile_pids_limit' (expected: integer, e.g. '256')"; exit 1
fi
if [ -n "${profile_ulimit_nofile:-}" ] && ! [[ "$profile_ulimit_nofile" =~ ^[0-9]+(:[0-9]+)?$ ]]; then
  error "Invalid ulimit_nofile format '$profile_ulimit_nofile' (expected: 'soft:hard' or 'value', e.g. '1024:2048')"; exit 1
fi
if [ -n "${profile_ulimit_fsize:-}" ] && ! [[ "$profile_ulimit_fsize" =~ ^[0-9]+$ ]]; then
  error "Invalid ulimit_fsize format '$profile_ulimit_fsize' (expected: integer bytes, e.g. '1073741824')"; exit 1
fi

# --- Resource limits ---
resource_args=()
[ -n "${profile_cpu:-}" ] && resource_args+=(--cpus "$profile_cpu")
[ -n "${profile_memory:-}" ] && resource_args+=(--memory "$profile_memory")
resource_args+=(--pids-limit "${profile_pids_limit:-$DEFAULT_PIDS_LIMIT}")
[ -n "${profile_ulimit_nofile:-}" ] && resource_args+=(--ulimit "nofile=$profile_ulimit_nofile")
[ -n "${profile_ulimit_fsize:-}" ] && resource_args+=(--ulimit "fsize=$profile_ulimit_fsize:$profile_ulimit_fsize")

# Complete the launch plan before creating state or accessing credentials.
[ "$launch_mode" != offline ] || network_mode=none
if [ "$broker_mode" = true ]; then
  [ "$launch_mode" != offline ] || { error "--broker cannot be combined with offline"; exit 1; }
  [ ${#extra_ports[@]} -eq 0 ] || { error "--broker does not publish ports"; exit 1; }
  network_mode=broker
fi
network_args=()
if [ "${network_mode:-bridge}" = none ] || [ "$broker_mode" = true ]; then network_args=(--network none); fi
if [ "$staged_mode" = true ]; then
  [ "$readonly_mode" = false ] || { error "--staged requires writable edit mode"; exit 1; }
  [ ${#extra_mounts[@]} -le 2 ] || { error "--staged cannot expose additional host mounts"; exit 1; }
fi
select_plugin_snapshot
# Offline and broker launches never mirror reusable host authentication.
auth_state_required=true
if [ "${network_mode:-bridge}" = none ] || [ "$broker_mode" = true ]; then auth_state_required=false; fi
configure_session_paths "$AGENTBOX_STATE_DIR/sessions/preview"

# --- Per-project Dockerfile ---
# If a project provides .agentbox.Dockerfile, use a custom image layered on top
# of the base image for project-specific dependencies. Actual builds happen only
# for real runs; --dry-run prints the command without executing repo-controlled
# Docker build steps.
run_image="$IMAGE_NAME"
project_image_note=""
project_runtime_args=()
if [ -f ".agentbox.Dockerfile" ] && [ "$init_mode" = false ]; then
  if [ "$allow_project_dockerfile" != true ]; then
    error_block "Refusing to build repo-controlled .agentbox.Dockerfile without explicit opt-in." \
      "Review it as full runtime trust: it can replace shells, libraries, and agent binaries." \
      "Retry with --allow-project-dockerfile only if you trust this project."
    exit 1
  fi
  if [ ! -f "$TRUSTED_ENTRYPOINT_FILE" ]; then
    error_block "Trusted entrypoint not found at $TRUSTED_ENTRYPOINT_FILE" \
      "Reinstall agentbox so project images can use the host-controlled entrypoint."
    exit 1
  fi
  run_image="agentbox-project-$agent_runtime-$(trusted_project_key)"
  project_runtime_args+=(
    -v "$TRUSTED_ENTRYPOINT_FILE:/home/claude/entrypoint.sh:ro"
  )
  if [ "$first_cmd" != "shell" ]; then
    # Invoke the bind-mounted trusted entrypoint through bash so it still works
    # when the host temp mount used by tests or CI does not allow direct exec.
    entrypoint_args=(--entrypoint /bin/bash)
    cmd_args=(/home/claude/entrypoint.sh ${cmd_args[@]+"${cmd_args[@]}"})
  fi
  if [ "$dry_run" = true ]; then
    project_image_note="Per-project image build allowed by --allow-project-dockerfile; dry-run skips the build. Treat $run_image as full runtime trust even though agentbox forces the host UID/GID and the host-controlled entrypoint."
  fi
fi

# --- Readonly mode ---
# When enabled, all host mounts get :ro suffix and extra profile mounts are forced read-only.
# A tmpfs overlay keeps the plans directory writable so Claude can still create plans.
ro_suffix=""
readonly_args=()
if [ "$readonly_mode" = true ]; then
  ro_suffix=":ro"
  readonly_args+=(--tmpfs "/home/claude/.claude/plans:rw,nosuid,size=64m,uid=$CONTAINER_UID,gid=$CONTAINER_GID")
  readonly_args+=(--tmpfs "/home/claude/.codex/sessions:rw,nosuid,size=64m,uid=$CONTAINER_UID,gid=$CONTAINER_GID")
  readonly_args+=(--tmpfs "/home/claude/.codex/log:rw,nosuid,size=64m,uid=$CONTAINER_UID,gid=$CONTAINER_GID")
  readonly_args+=(--tmpfs "/home/claude/.codex/tmp:rw,nosuid,size=64m,uid=$CONTAINER_UID,gid=$CONTAINER_GID")
  # Force all extra mounts to read-only regardless of profile config
  for i in "${!extra_mounts[@]}"; do
    [[ "${extra_mounts[$i]}" != "-v" && "${extra_mounts[$i]}" != *":ro" ]] && extra_mounts[i]+=":ro"
  done
fi

# --- Seccomp profile validation ---
# Ensure the seccomp profile exists before running the container
if [ ! -f "$SECCOMP_PROFILE" ]; then
  error_block "Seccomp profile not found at $SECCOMP_PROFILE" \
    "Please reinstall agentbox."
  exit 1
fi

if [ "$dry_run" = true ] && [ "$staged_mode" = true ]; then
  workdir="$SESSION_DIR/workspace"
  if [ -n "$git_dir" ]; then extra_mounts=(-v "$git_dir:$workdir/.git:ro"); fi
fi
if [ "$init_mode" = true ]; then finish_project_init; exit 0; fi
if [ "$inspect_mode" = true ]; then inspect_plan; exit 0; fi
if [ "$first_cmd" = trust ]; then inspect_plan; approve_launch; exit 0; fi
if [ "$dry_run" != true ]; then
  assert_project_config_unchanged
  if { [ "$project_versioned" = true ] || [ "$profile_extra_grants" = true ] || [ "${network_mode:-bridge}" != none ]; } && ! launch_is_approved; then
    if [ "$project_versioned" = true ] && [ "$print_mode" = false ] && [ -t 0 ] && [ -t 1 ]; then
      inspect_plan
      confirm_access 'Approve these project permissions on this machine?' || { info 'Launch cancelled'; exit 0; }
      approve_launch
    else
      error 'Project is not trusted. Review the current permissions, then run agentbox trust (or agentbox init).'; exit 1
    fi
  fi
  assert_project_config_unchanged
  if [ "$auth_state_required" = true ]; then require_runtime_auth; fi
  ensure_state_root
  ensure_private_dir "$AGENTBOX_STATE_DIR/sessions"
  old_umask=$(umask); umask 077
  session_path=$(mktemp -d "$AGENTBOX_STATE_DIR/sessions/session.XXXXXXXX")
  umask "$old_umask"
  configure_session_paths "$session_path"
  trap cleanup_session EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  ensure_sandbox_state_dirs
  if [ "$auth_state_required" = true ]; then prepare_sandbox_state
  else use_authless_sandbox_state; prepare_sandbox_non_auth_state; fi
  prepare_empty_runtime_state
  if [ "$broker_mode" = true ]; then
    start_broker
    if [ "$agent_runtime" = codex ]; then
      write_private_file_content "$ACTIVE_SANDBOX_CODEX_DIR/config.toml" \
        'model_provider = "agentbox"
[model_providers.agentbox]
name = "agentbox broker"
base_url = "http://127.0.0.1:18080/v1"
wire_api = "responses"'
    fi
  fi
  [ "$staged_mode" != true ] || stage_workspace
fi
select_runtime_mounts

# --- Build the docker run command ---
# Use --rm for ephemeral containers; use named containers when audit logging
# is enabled so we can dump logs after the session ends.
container_name="agentbox-${SESSION_DIR##*/}-$$"
container_args=(--name "$container_name" --label agentbox.managed=true)
if [ "$audit_log" = "true" ]; then
  # Name includes timestamp and PID for uniqueness across concurrent sessions
  : # Retain the named container until logs have been collected.
  # Ensure the logs directory exists for session log dumps
  [ "$dry_run" = true ] || ensure_private_dir "$AGENTBOX_STATE_DIR/logs"
else
  # Auto-remove container on exit for zero disk overhead
  container_args+=(--rm)
fi

# --- TTY allocation ---
# Use -it for interactive mode (default), -i only for print mode (no TTY needed).
# Print mode supports piping (cat file | claude -p "summarize") which works with -i.
if [ "$print_mode" = true ]; then
  if [ -t 0 ]; then
    # stdin is a terminal — no piped input, don't keep stdin open
    tty_flags=()
  else
    # stdin is a pipe — keep it open so piped content reaches Claude
    tty_flags=(-i)
  fi
else
  if [ -t 0 ] && [ -t 1 ]; then tty_flags=(-it); else tty_flags=(-i); fi
fi

runtime_env_args=(-e "AGENTBOX_RUNTIME=$agent_runtime")
if [ "$agent_runtime" = "codex" ] && [ "$auth_state_required" = true ] && [ -n "${OPENAI_API_KEY:-}" ]; then
  runtime_env_args+=(-e "OPENAI_API_KEY")
fi

if [ "$agent_runtime" = claude ] && [ "$auth_state_required" = true ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  runtime_env_args+=(-e ANTHROPIC_API_KEY)
fi
if [ "$broker_mode" = true ]; then
  runtime_env_args+=(-e AGENTBOX_BROKER_TOKEN -e AGENTBOX_BROKER=true)
  extra_mounts+=(-v "${broker_socket_volume:-agentbox-socket-preview}:/run/agentbox:ro")
  if [ "$agent_runtime" = claude ]; then
    runtime_env_args+=(-e ANTHROPIC_BASE_URL=http://127.0.0.1:18080 -e ANTHROPIC_AUTH_TOKEN=agentbox-session -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
  fi
fi
plugins_ro_suffix="$ro_suffix"
[ "$plugins_enabled" != true ] || plugins_ro_suffix=":ro"

# Assemble the complete docker run command as an array for safe quoting
docker_cmd=(
  docker run ${tty_flags[@]+"${tty_flags[@]}"}
  ${container_args[@]+"${container_args[@]}"}
  # Security hardening: drop all Linux capabilities
  --cap-drop=ALL
  # Prevent processes from gaining new privileges (e.g. via setuid binaries)
  --security-opt=no-new-privileges
  # Apply seccomp profile for syscall filtering
  --security-opt "seccomp=$SECCOMP_PROFILE"
  # Project images are forced back to the agentbox runtime contract.
  ${project_runtime_args[@]+"${project_runtime_args[@]}"}
  --user "$CONTAINER_UID:$CONTAINER_GID"
  # Mount rootfs as read-only; writable dirs use tmpfs below
  --read-only
  # Tmpfs mounts for directories that need write access (size-limited)
  --tmpfs "/tmp:rw,nosuid,size=$TMPFS_TMP_SIZE"
  --tmpfs "/home/claude/.cache:rw,nosuid,size=$TMPFS_CACHE_SIZE"
  --tmpfs "/home/claude/.npm:rw,nosuid,size=$TMPFS_NPM_SIZE"
  -v "$MOUNT_SANDBOX_DOTCONFIG_DIR:/home/claude/.config${ro_suffix}"
  --tmpfs "/home/claude/.local:rw,nosuid,size=$TMPFS_LOCAL_SIZE,uid=$CONTAINER_UID,gid=$CONTAINER_GID"
  # Apply resource limits (if configured in profile)
  ${resource_args[@]+"${resource_args[@]}"}
  # Apply network mode if non-default
  ${network_args[@]+"${network_args[@]}"}
  # Pass profile context to container for sandbox awareness CLAUDE.md generation
  -e "AGENTBOX_NETWORK_MODE=${network_mode:-bridge}"
  -e "AGENTBOX_CPU_LIMIT=${profile_cpu:-}"
  -e "AGENTBOX_MEMORY_LIMIT=${profile_memory:-}"
  -e "AGENTBOX_PIDS_LIMIT=${profile_pids_limit:-$DEFAULT_PIDS_LIMIT}"
  -e "AGENTBOX_EXTRA_MOUNTS=${extra_mounts_info:-}"
  -e "AGENTBOX_READONLY=${readonly_mode:-false}"
  -e "HOME=/home/claude"
  -e "CODEX_HOME=/home/claude/.codex"
  ${runtime_env_args[@]+"${runtime_env_args[@]}"}
  # Set the working directory inside the container to match the host
  --workdir "$workdir"
  # Mount the current project directory at the same path for path parity
  -v "${workdir}:${workdir}${ro_suffix}"
  # Mount the sandbox mirror of Claude's ~/.claude directory. Auth is refreshed
  # from the host before launch, but subsequent writes stay isolated to agentbox.
  -v "$MOUNT_SANDBOX_CLAUDE_DIR:/home/claude/.claude${ro_suffix}"
  # Keep sandbox-awareness CLAUDE.md writable via a tmpfs-backed runtime path.
  --tmpfs "/home/claude/.claude/runtime:rw,nosuid,size=16m,uid=$CONTAINER_UID,gid=$CONTAINER_GID"
  # Mount the sandbox mirror of Claude's JSON state file.
  -v "$MOUNT_SANDBOX_CLAUDE_STATE_FILE:/home/claude/.claude.json${ro_suffix}"
  # Mount sandbox plugins directory (isolated from host ~/.claude/plugins/)
  -v "$MOUNT_SANDBOX_PLUGINS_DIR:/home/claude/.claude/plugins${plugins_ro_suffix}"
  # Mount the sandbox mirror of Codex state/config/auth.
  -v "$MOUNT_SANDBOX_CODEX_DIR:/home/claude/.codex${ro_suffix}"
  # Keep sandbox-awareness Codex AGENTS.md writable via tmpfs-backed runtime path.
  --tmpfs "/home/claude/.codex/runtime:rw,nosuid,size=16m,uid=$CONTAINER_UID,gid=$CONTAINER_GID"
  # Add readonly mode tmpfs overlay (plans directory) when enabled
  ${readonly_args[@]+"${readonly_args[@]}"}
  # Add any profile-configured extra mounts, ports, and entrypoint overrides
  ${extra_mounts[@]+"${extra_mounts[@]}"}
  ${extra_ports[@]+"${extra_ports[@]}"}
  ${entrypoint_args[@]+"${entrypoint_args[@]}"}
  # Image to run, followed by arguments forwarded to the entrypoint
  "$run_image" ${cmd_args[@]+"${cmd_args[@]}"}
)

# --- Dry run mode ---
# Print the full command for debugging instead of executing it
if [ "$dry_run" = true ]; then
  section "dry-run" >&2
  list_item "Runtime" "$agent_runtime" >&2
  [ -n "$profile_name" ] && list_item "Profile" "$profile_name" >&2
  [ -n "${extra_mounts_info:-}" ] && { list_item "Mounts" "" >&2; echo "$extra_mounts_info" >&2; }
  [ ${#extra_ports[@]} -gt 0 ] && list_item "Ports" "${extra_ports[*]}" >&2
  [ "${network_mode:-bridge}" != "bridge" ] && list_item "Network" "${network_mode:-bridge}" >&2
  [ "$readonly_mode" = true ] && list_item "Readonly" "true" >&2
  [ -n "$project_image_note" ] && note "$project_image_note" >&2
  echo "" >&2
  # Use printf %q for shell-safe quoting of each argument
  printf '%q ' "${docker_cmd[@]}"
  echo
  exit 0
fi

if [ -f ".agentbox.Dockerfile" ]; then
  step "Building per-project image"
  # Build quietly (-q) since this runs on every invocation
  if ! docker build -q -f .agentbox.Dockerfile -t "$run_image" . >&2; then
    error "Failed to build per-project image from .agentbox.Dockerfile"
    exit 1
  fi
fi

# Keep the wrapper alive so private state is removed after Docker exits.
exit_code=0
"${docker_cmd[@]}" || exit_code=$?
if [ "$audit_log" = true ]; then
  log_file="$AGENTBOX_STATE_DIR/logs/$container_name.log"
  old_umask=$(umask); umask 077
  docker logs "$container_name" > "$log_file" 2>&1 || true
  umask "$old_umask"
  info "Session log: $log_file"
fi
exit "$exit_code"
