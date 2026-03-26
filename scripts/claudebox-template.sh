#!/bin/bash
# =============================================================================
# claudebox-template.sh - Standalone script template
#
# This template is processed by do_install() which replaces
# PLACEHOLDER_IMAGE_NAME with the real value. The resulting script is installed to
# ~/.claudebox/bin/ and becomes the user-facing CLI.
# =============================================================================

# Abort on any error
set -euo pipefail

# Source terminal styling library (graceful fallback to plain echo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=style.sh
[[ -f "$SCRIPT_DIR/style.sh" ]] && source "$SCRIPT_DIR/style.sh" || true

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

# Seccomp profile path (for syscall filtering)
SECCOMP_PROFILE="$HOME/.claudebox/seccomp.json"

# Host Claude state is the source of truth for auth/account data. claudebox keeps
# isolated writable mirrors under ~/.claudebox/ and refreshes them before launch.
HOST_CLAUDE_DIR="$HOME/.claude"
HOST_CLAUDE_STATE_FILE="$HOME/.claude.json"
HOST_CREDENTIALS_FILE="$HOST_CLAUDE_DIR/.credentials.json"
CLAUDEBOX_STATE_DIR="$HOME/.claudebox"
SANDBOX_CLAUDE_DIR="$CLAUDEBOX_STATE_DIR/claude-config"
SANDBOX_DOTCONFIG_DIR="$CLAUDEBOX_STATE_DIR/claude-dotconfig"
SANDBOX_PLUGINS_DIR="$CLAUDEBOX_STATE_DIR/plugins"
SANDBOX_CLAUDE_STATE_FILE="$CLAUDEBOX_STATE_DIR/.claude.json"
SANDBOX_CREDENTIALS_FILE="$SANDBOX_CLAUDE_DIR/.credentials.json"

mkdir -p "$SANDBOX_CLAUDE_DIR"
mkdir -p "$SANDBOX_DOTCONFIG_DIR"
mkdir -p "$SANDBOX_PLUGINS_DIR"

sync_directory() {
  local src="$1"
  local dest="$2"

  if [ -d "$src" ]; then
    if command -v rsync &>/dev/null; then
      mkdir -p "$dest"
      rsync -a --delete "$src"/ "$dest"/ 2>/dev/null || true
    else
      rm -rf "$dest" 2>/dev/null || true
      cp -R "$src" "$dest" 2>/dev/null || true
    fi
  fi
}

sync_host_auth_state() {
  # Host ~/.claude.json carries the current account and auth metadata. Copy it
  # into the sandbox mirror so each container launch starts from fresh host state.
  if [ -s "$HOST_CLAUDE_STATE_FILE" ]; then
    cp "$HOST_CLAUDE_STATE_FILE" "$SANDBOX_CLAUDE_STATE_FILE" 2>/dev/null || true
  elif [ ! -s "$SANDBOX_CLAUDE_STATE_FILE" ]; then
    echo '{}' > "$SANDBOX_CLAUDE_STATE_FILE"
  fi

  # Claude Code may still use ~/.claude/.credentials.json on some installs. If
  # the host no longer has this file, remove any stale sandbox copy.
  if [ -f "$HOST_CREDENTIALS_FILE" ]; then
    cp "$HOST_CREDENTIALS_FILE" "$SANDBOX_CREDENTIALS_FILE" 2>/dev/null || true
    chmod 600 "$SANDBOX_CREDENTIALS_FILE" 2>/dev/null || true
  else
    rm -f "$SANDBOX_CREDENTIALS_FILE" 2>/dev/null || true
  fi
}

sync_host_auth_state

# Sync sandbox plugins from host (always sync to keep in sync with host state)
sync_directory "$HOST_CLAUDE_DIR/plugins/marketplaces" "$SANDBOX_PLUGINS_DIR/marketplaces"

# Sync cache directory (contains installed plugin files)
sync_directory "$HOST_CLAUDE_DIR/plugins/cache" "$SANDBOX_PLUGINS_DIR/cache"

# Sync metadata files with path conversion (host paths → container paths)
for metadata_file in known_marketplaces.json installed_plugins.json; do
  if [ -f "$HOST_CLAUDE_DIR/plugins/$metadata_file" ]; then
    content=$(<"$HOST_CLAUDE_DIR/plugins/$metadata_file")
    printf '%s\n' "${content//$HOME//home/claude}" > "$SANDBOX_PLUGINS_DIR/$metadata_file" 2>/dev/null || true
  fi
done
# Claude Code expects valid JSON in the mirrored state file.
[ -s "$SANDBOX_CLAUDE_STATE_FILE" ] || echo '{}' > "$SANDBOX_CLAUDE_STATE_FILE"

# --- Argument parsing ---
# Arrays and variables for building the docker run command
entrypoint_args=()     # Override entrypoint (used for "shell" command)
extra_mounts=()        # Additional -v mounts from profile config
extra_mounts_info=""   # Human-readable mount info for sandbox awareness
extra_ports=()         # Additional -p ports from profile config
workdir="$(pwd)"       # Mount the current directory as the working directory
profile_name=""        # Selected profile from .claudebox.json
cmd_args=()            # Arguments forwarded to Claude Code inside the container
first_cmd=""           # First non-flag argument (used to detect "shell" command)
skip_next=false        # Flag to skip the next argument (used for --profile value)
dry_run=false          # When true, print the docker command instead of running it
audit_log=false        # When true, keep named container and dump logs on exit
readonly_mode=false    # When true, mount all host paths as read-only
print_mode=false       # When true, Claude is in -p/--print mode (no TTY needed)

# Extract our flags (--profile, --dry-run), pass everything else to Claude
for arg in "$@"; do
  if [ "$skip_next" = true ]; then
    # This arg is the value for --profile/-P
    profile_name="$arg"
    skip_next=false
  elif [ "$arg" = "--profile" ] || [ "$arg" = "-P" ]; then
    # Next arg will be the profile name
    skip_next=true
  elif [ "$arg" = "--dry-run" ]; then
    # Enable dry-run mode: print command without executing
    dry_run=true
  elif [ "$arg" = "--readonly" ]; then
    # Enable readonly mode: all host mounts become read-only
    readonly_mode=true
  else
    # Track the first non-flag arg to detect the "shell" command
    [ -z "$first_cmd" ] && first_cmd="$arg"
    # Detect -p/--print for TTY allocation (print mode runs non-interactively)
    [ "$arg" = "-p" ] || [ "$arg" = "--print" ] && print_mode=true
    cmd_args+=("$arg")
  fi
done

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
  if [ -d "$HOME/.claudebox/repo" ]; then
    repo_path="$HOME/.claudebox/repo"
  elif [ -f "$HOME/.claudebox/.repo-path" ]; then
    repo_path=$(<"$HOME/.claudebox/.repo-path")
  fi
  if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
    error_block "Cannot find claudebox source directory" \
      "Reinstall claudebox from the repo to enable updates."
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
  version_file="$HOME/.claudebox/version"
  if [ -f "$version_file" ]; then
    installed_version=$(<"$version_file")
  fi
  latest_version=$(curl -fsSL --max-time 5 \
    "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest" 2>/dev/null) || true

  # If neither repo nor Claude Code version changed, skip rebuild
  if [ "$git_before" = "$git_after" ] && [ -n "$installed_version" ] && [ -n "$latest_version" ] && [ "$installed_version" = "$latest_version" ]; then
    info "Already up to date"
    exit 0
  fi

  rm -f "$HOME/.claudebox/.latest-version"
  exec "$repo_path/install.sh" --update
fi

# --- Version staleness check ---
# Warn the user if a newer Claude Code version is available upstream.
# Uses a 24h-cached check against the GCS latest endpoint.
check_version_staleness() {
  local installed_version latest_version cache_file cache_age now file_mtime
  local version_file="$HOME/.claudebox/version"
  cache_file="$HOME/.claudebox/.latest-version"

  # No version file means pre-version-tracking build — skip silently
  [ -f "$version_file" ] || return 0
  installed_version=$(<"$version_file")
  [ -n "$installed_version" ] || return 0

  # Check if cache is fresh (< 24h)
  if [ -f "$cache_file" ]; then
    now=$(date +%s)
    # macOS stat uses -f %m, Linux uses -c %Y
    file_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    cache_age=$(( now - file_mtime ))
    if [ "$cache_age" -lt 86400 ]; then
      latest_version=$(<"$cache_file")
    fi
  fi

  # Fetch from upstream if cache is stale or missing
  if [ -z "${latest_version:-}" ]; then
    latest_version=$(curl -fsSL --max-time 2 \
      "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest" 2>/dev/null) || true
    if [ -n "$latest_version" ]; then
      mkdir -p "$HOME/.claudebox"
      printf '%s' "$latest_version" > "$cache_file"
    else
      # Fetch failed — fall back to stale cache
      [ -f "$cache_file" ] && latest_version=$(<"$cache_file")
    fi
  fi

  # Compare versions
  [ -n "${latest_version:-}" ] || return 0
  if [ "$installed_version" != "$latest_version" ]; then
    warn "update available ($installed_version → $latest_version) — run: claudebox update"
  fi
}
[ "$print_mode" = false ] && check_version_staleness

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
  # Claude-specific (already managed)
  "$HOME/.claude" "$HOME/.claudebox"
)

normalize_path() {
  local p="$1"
  local normalized
  normalized=$(realpath -m "${p/#\~/$HOME}" 2>/dev/null) || normalized="${p/#\~/$HOME}"
  [[ "$normalized" != "/" ]] && normalized="${normalized%/}"
  echo "$normalized"
}

is_path_blocked() {
  local normalized="$1"
  for blocked in "${BLOCKED_PATHS[@]}"; do
    [[ "$normalized" == "$blocked" ]] && return 0
    [[ "$normalized" == "$blocked"/* ]] && return 0
  done
  return 1
}

# --- Per-project configuration (.claudebox.json) ---
if [ -f ".claudebox.json" ]; then
  # jq is required to parse the JSON config
  if ! command -v jq &>/dev/null; then
    warn "jq not installed, skipping .claudebox.json config"
    note "Install with: brew install jq"
  else
    # Validate the config file is a JSON object (not array, string, etc.)
    jq_error=""
    if ! jq_error=$(jq -e 'type == "object"' .claudebox.json 2>&1); then
      error "Invalid .claudebox.json: $jq_error"
      exit 1
    fi

    # Count available profiles (root-level keys in the JSON object)
    profile_count=$(jq 'keys | length' .claudebox.json 2>/dev/null || echo 0)

    # If no profile was specified via flag, auto-select or prompt interactively
    if [ -z "$profile_name" ] && [ "$profile_count" -eq 1 ]; then
      profile_name=$(jq -r 'keys[0]' .claudebox.json)
    elif [ -z "$profile_name" ] && [ "$profile_count" -gt 1 ]; then
      # Read profile names into an array for the selection menu (compatible with Bash 3)
      profile_array=()
      while IFS= read -r _p; do profile_array+=("$_p"); done < <(jq -r 'keys[]' .claudebox.json)
      profile_name=$(choose "Select profile:" "${profile_array[@]}")
    fi

    # Validate the selected profile exists in the config
    if [ -n "$profile_name" ]; then
      if ! jq -e --arg p "$profile_name" 'has($p)' .claudebox.json &>/dev/null; then
        error "Profile '$profile_name' not found"
        note "Available: $(jq -r 'keys | join(", ")' .claudebox.json)"
        exit 1
      fi

      info "Using profile: $profile_name"

      # Extract all profile settings in a single jq call for efficiency.
      # Produces a normalized JSON object with mounts, ports, and scalar options.
      profile_config=$(jq -r --arg p "$profile_name" '
        .[($p)] | {
          mounts: [(.mounts // [])[] | .path + ":" + .path + (if .readonly then ":ro" else "" end)],
          ports: [(.ports // [])[] | (.host|tostring) + ":" + (.container|tostring)],
          network: (.network // "bridge"),
          audit_log: (.audit_log // false),
          cpu: (.cpu // null),
          memory: (.memory // null),
          pids_limit: (.pids_limit // null),
          ulimit_nofile: (.ulimit_nofile // null),
          ulimit_fsize: (.ulimit_fsize // null)
        }
      ' .claudebox.json)

      if [ -z "$profile_config" ]; then
        error "Failed to parse profile '$profile_name' from .claudebox.json"
        exit 1
      fi

      # Parse mount specifications and validate each one
      while IFS= read -r mount_spec; do
        # Skip empty lines from jq output
        [ -z "$mount_spec" ] && continue
        # Extract the host path (everything before the first colon)
        mount_path="${mount_spec%%:*}"
        # Normalize path once for blocklist checks
        normalized_path=$(normalize_path "$mount_path")
        # Check against dangerous path blocklist
        if is_path_blocked "$normalized_path"; then
          error "Mount path blocked (security policy): $mount_path"
          exit 1
        # Reject paths with multiple colons (ambiguous Docker mount syntax)
        elif [[ "$mount_spec" == *":"*":"*":"* ]]; then
          warn "Skipping mount path containing ':': $mount_path"
        # Reject paths with path traversal sequences (../)
        elif [[ "$mount_path" =~ (^|/)\.\.($|/) ]]; then
          warn "Skipping mount with path traversal: $mount_path"
        # Reject paths with control characters (potential injection)
        elif [[ "$mount_path" =~ [[:cntrl:]] ]]; then
          warn "Skipping mount with invalid characters"
        # Warn if the host path doesn't exist (Docker would create it as root)
        elif [ ! -e "$mount_path" ]; then
          warn "Mount path does not exist: $mount_path"
          note "Create it with: mkdir -p $mount_path"
        # Reject symlinks (TOCTOU risk: symlink target could change between validation and mount)
        elif [ -L "$mount_path" ]; then
          real_path=$(readlink -f "$mount_path" 2>/dev/null || echo "unresolved")
          error "Mount path is a symlink (security policy): $mount_path → $real_path"
          note "Specify the actual path directly"
          continue
        else
          # Valid mount — add to the docker run arguments
          extra_mounts+=(-v "$mount_spec")
          # Build human-readable mount info for sandbox awareness
          if [[ "$mount_spec" == *":ro" ]]; then
            extra_mounts_info+="- \`$mount_path\` (read-only)"$'\n'
          else
            extra_mounts_info+="- \`$mount_path\` (read-write)"$'\n'
          fi
        fi
      done < <(echo "$profile_config" | jq -r '.mounts[]')

      # Parse port specifications and validate ranges
      while IFS= read -r port_spec; do
        # Skip empty lines from jq output
        [ -z "$port_spec" ] && continue
        # Split host:container port pair
        host_port="${port_spec%%:*}"
        container_port="${port_spec##*:}"
        # Validate both ports are numeric
        if ! [[ "$host_port" =~ ^[0-9]+$ ]] || ! [[ "$container_port" =~ ^[0-9]+$ ]]; then
          warn "Invalid port specification: $port_spec"
        # Validate ports are in the valid TCP/UDP range
        elif [ "$host_port" -lt 1 ] || [ "$host_port" -gt 65535 ] || [ "$container_port" -lt 1 ] || [ "$container_port" -gt 65535 ]; then
          warn "Port out of range (1-65535): $port_spec"
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
  fi
else
  if [ -n "$profile_name" ]; then
    error "--profile '$profile_name' specified but no .claudebox.json found in $(pwd)"
    exit 1
  fi
fi

# --- Git read-only .git mount ---
# When inside a git repo, mount .git as read-only to prevent commits.
# Without SSH keys or git credentials in the container, pushes fail anyway.
git_dir=""
if git -C "$workdir" rev-parse --git-dir &>/dev/null; then
  git_dir="$(cd "$workdir" && git rev-parse --absolute-git-dir)"
  normalized_git_dir=$(normalize_path "$git_dir")
  if is_path_blocked "$normalized_git_dir"; then
    error "Git directory blocked (security policy): $git_dir"
    exit 1
  elif [ -L "$git_dir" ]; then
    real_git_path=$(readlink -f "$git_dir" 2>/dev/null || echo "unresolved")
    error "Git directory is a symlink (security policy): $git_dir → $real_git_path"
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

# --- Per-project Dockerfile ---
# If a project provides .claudebox.Dockerfile, build a custom image
# layered on top of the base image for project-specific dependencies
run_image="$IMAGE_NAME"
if [ -f ".claudebox.Dockerfile" ]; then
  run_image="${IMAGE_NAME}-project"
  step "Building per-project image"
  # Build quietly (-q) since this runs on every invocation
  if ! docker build -q -f .claudebox.Dockerfile -t "$run_image" . >&2; then
    error "Failed to build per-project image from .claudebox.Dockerfile"
    exit 1
  fi
fi

# --- Readonly mode ---
# When enabled, all host mounts get :ro suffix and extra profile mounts are forced read-only.
# A tmpfs overlay keeps the plans directory writable so Claude can still create plans.
ro_suffix=""
readonly_args=()
if [ "$readonly_mode" = true ]; then
  ro_suffix=":ro"
  readonly_args+=(--tmpfs "/home/claude/.claude/plans:rw,nosuid,size=64m,uid=1000,gid=1000")
  # Force all extra mounts to read-only regardless of profile config
  for i in "${!extra_mounts[@]}"; do
    [[ "${extra_mounts[$i]}" != "-v" && "${extra_mounts[$i]}" != *":ro" ]] && extra_mounts[i]+=":ro"
  done
fi

# --- Seccomp profile validation ---
# Ensure the seccomp profile exists before running the container
if [ ! -f "$SECCOMP_PROFILE" ]; then
  error_block "Seccomp profile not found at $SECCOMP_PROFILE" \
    "Please reinstall claudebox."
  exit 1
fi

# --- Build the docker run command ---
# Use --rm for ephemeral containers; use named containers when audit logging
# is enabled so we can dump logs after the session ends.
container_args=()
if [ "$audit_log" = "true" ]; then
  # Name includes timestamp and PID for uniqueness across concurrent sessions
  container_name="claudebox-$(date +%s)-$$"
  container_args+=(--name "$container_name")
  # Ensure the logs directory exists for session log dumps
  mkdir -p ~/.claudebox/logs
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
  tty_flags=(-it)
fi

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
  # Mount rootfs as read-only; writable dirs use tmpfs below
  --read-only
  # Tmpfs mounts for directories that need write access (size-limited)
  --tmpfs "/tmp:rw,nosuid,size=$TMPFS_TMP_SIZE"
  --tmpfs "/home/claude/.cache:rw,nosuid,size=$TMPFS_CACHE_SIZE"
  --tmpfs "/home/claude/.npm:rw,nosuid,size=$TMPFS_NPM_SIZE"
  -v "$SANDBOX_DOTCONFIG_DIR:/home/claude/.config${ro_suffix}"
  --tmpfs "/home/claude/.local:rw,nosuid,size=$TMPFS_LOCAL_SIZE,uid=1000,gid=1000"
  # Apply resource limits (if configured in profile)
  ${resource_args[@]+"${resource_args[@]}"}
  # Apply network mode if non-default
  ${network_args[@]+"${network_args[@]}"}
  # Pass profile context to container for sandbox awareness CLAUDE.md generation
  -e "CLAUDEBOX_NETWORK_MODE=${network_mode:-bridge}"
  -e "CLAUDEBOX_CPU_LIMIT=${profile_cpu:-}"
  -e "CLAUDEBOX_MEMORY_LIMIT=${profile_memory:-}"
  -e "CLAUDEBOX_PIDS_LIMIT=${profile_pids_limit:-$DEFAULT_PIDS_LIMIT}"
  -e "CLAUDEBOX_EXTRA_MOUNTS=${extra_mounts_info:-}"
  -e "CLAUDEBOX_READONLY=${readonly_mode:-false}"
  # Set the working directory inside the container to match the host
  --workdir "$workdir"
  # Mount the current project directory at the same path for path parity
  -v "${workdir}:${workdir}${ro_suffix}"
  # Mount the sandbox mirror of Claude's ~/.claude directory. Auth is refreshed
  # from the host before launch, but subsequent writes stay isolated to claudebox.
  -v "$SANDBOX_CLAUDE_DIR:/home/claude/.claude${ro_suffix}"
  # Mount the sandbox mirror of Claude's JSON state file. NOTE: Always writable
  # so sandbox-local state can persist even when host paths are read-only.
  -v "$SANDBOX_CLAUDE_STATE_FILE:/home/claude/.claude.json"
  # Mount sandbox plugins directory (writable, isolated from host ~/.claude/plugins/)
  -v "$SANDBOX_PLUGINS_DIR:/home/claude/.claude/plugins"
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
  [ -n "$profile_name" ] && list_item "Profile" "$profile_name" >&2
  [ -n "${extra_mounts_info:-}" ] && { list_item "Mounts" "" >&2; echo "$extra_mounts_info" >&2; }
  [ ${#extra_ports[@]} -gt 0 ] && list_item "Ports" "${extra_ports[*]}" >&2
  [ "${network_mode:-bridge}" != "bridge" ] && list_item "Network" "${network_mode:-bridge}" >&2
  [ "$readonly_mode" = true ] && list_item "Readonly" "true" >&2
  echo "" >&2
  # Use printf %q for shell-safe quoting of each argument
  printf '%q ' "${docker_cmd[@]}"
  echo
  exit 0
fi

# --- Execute the container ---
if [ "$audit_log" = "true" ]; then
  # With audit logging: use a named container so we can dump logs afterward
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    # On interrupt/termination, force-stop and remove the named container
    docker kill "$container_name" &>/dev/null || true
    docker rm "$container_name" &>/dev/null || true
  }
  # Register cleanup for SIGINT (Ctrl+C) and SIGTERM
  trap cleanup INT TERM

  # Run the container; capture the exit code
  exit_code=0
  "${docker_cmd[@]}" || exit_code=$?

  # Dump the container's stdout/stderr to a log file for audit review
  log_file=~/.claudebox/logs/${container_name}.log
  docker logs "$container_name" > "$log_file" 2>&1 || true
  # Remove the named container now that logs are captured
  docker rm "$container_name" &>/dev/null || true
  info "Session log: $log_file"

  # Remove the trap and exit with the container's exit code
  trap - INT TERM
  exit $exit_code
else
  exec "${docker_cmd[@]}"
fi
