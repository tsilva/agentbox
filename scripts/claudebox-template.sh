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

# Docker image name (replaced at install time by do_install)
IMAGE_NAME="PLACEHOLDER_IMAGE_NAME"

# Resource defaults (overridable via environment)
: "${TMPFS_TMP_SIZE:=1g}"
: "${TMPFS_CACHE_SIZE:=1g}"
: "${TMPFS_NPM_SIZE:=256m}"
: "${TMPFS_LOCAL_SIZE:=512m}"

# Seccomp profile path (for syscall filtering)
SECCOMP_PROFILE="$HOME/.claudebox/seccomp.json"

# Ensure the persistent config directory and session state file exist.
# claude-config is mounted into the container as ~/.claude/ for credentials.
mkdir -p ~/.claudebox/claude-config
mkdir -p ~/.claudebox/claude-dotconfig
mkdir -p ~/.claudebox/plugins
# Seed sandbox plugins from host on first run (copies Anthropic marketplace, etc.)
if [ -d ~/.claude/plugins ] && [ ! -d ~/.claudebox/plugins/marketplaces ]; then
  cp -R ~/.claude/plugins/* ~/.claudebox/plugins/ 2>/dev/null || true
fi
# Initialize .claude.json if missing or empty (Claude Code expects valid JSON)
[ -s ~/.claudebox/.claude.json ] || echo '{}' > ~/.claudebox/.claude.json

# --- Argument parsing ---
# Arrays and variables for building the docker run command
entrypoint_args=()     # Override entrypoint (used for "shell" command)
extra_mounts=()        # Additional -v mounts from profile config
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

# --- Per-project configuration (.claudebox.json) ---
if [ -f ".claudebox.json" ]; then
  # jq is required to parse the JSON config
  if ! command -v jq &>/dev/null; then
    echo "Warning: jq not installed, skipping .claudebox.json config" >&2
    echo "Install with: brew install jq" >&2
  else
    # Validate the config file is a JSON object (not array, string, etc.)
    jq_error=""
    if ! jq_error=$(jq -e 'type == "object"' .claudebox.json 2>&1); then
      echo "Error: Invalid .claudebox.json: $jq_error" >&2
      exit 1
    fi

    # Count available profiles (root-level keys in the JSON object)
    profile_count=$(jq 'keys | length' .claudebox.json 2>/dev/null || echo 0)

    # If no profile was specified via flag, auto-select or prompt interactively
    if [ -z "$profile_name" ] && [ "$profile_count" -eq 1 ]; then
      profile_name=$(jq -r 'keys[0]' .claudebox.json)
      echo "Using profile: $profile_name" >&2
    elif [ -z "$profile_name" ] && [ "$profile_count" -gt 1 ]; then
      # Read profile names into an array for the select menu (compatible with Bash 3)
      profile_array=()
      while IFS= read -r _p; do profile_array+=("$_p"); done < <(jq -r 'keys[]' .claudebox.json)
      echo "Available profiles:" >&2
      # Present a numbered menu; reads from /dev/tty so it works in pipes
      select profile_name in "${profile_array[@]}"; do
        [ -n "$profile_name" ] && break
        echo "Invalid selection." >&2
      done </dev/tty
    fi

    # Validate the selected profile exists in the config
    if [ -n "$profile_name" ]; then
      if ! jq -e --arg p "$profile_name" 'has($p)' .claudebox.json &>/dev/null; then
        echo "Error: Profile '$profile_name' not found" >&2
        echo "Available: $(jq -r 'keys | join(", ")' .claudebox.json)" >&2
        exit 1
      fi

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
      ' .claudebox.json 2>/dev/null)

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
          echo "Error: Mount path blocked (security policy): $mount_path" >&2
        # Reject paths with multiple colons (ambiguous Docker mount syntax)
        elif [[ "$mount_spec" == *":"*":"*":"* ]]; then
          echo "Warning: Skipping mount path containing ':': $mount_path" >&2
        # Reject paths with path traversal sequences (../)
        elif [[ "$mount_path" =~ (^|/)\.\.($|/) ]]; then
          echo "Warning: Skipping mount with path traversal: $mount_path" >&2
        # Reject paths with control characters (potential injection)
        elif [[ "$mount_path" =~ [[:cntrl:]] ]]; then
          echo "Warning: Skipping mount with invalid characters" >&2
        # Warn if the host path doesn't exist (Docker would create it as root)
        elif [ ! -e "$mount_path" ]; then
          echo "Warning: Mount path does not exist: $mount_path" >&2
          echo "  Hint: Create it with: mkdir -p $mount_path" >&2
        # Detect and reject symlinks (could point to unintended directories)
        elif [ -L "$mount_path" ]; then
          real_path=$(readlink -f "$mount_path" 2>/dev/null || echo "unresolved")
          echo "Warning: Mount path is a symlink: $mount_path → $real_path" >&2
          echo "  Hint: Specify the actual path directly for security" >&2
        else
          # Valid mount — add to the docker run arguments
          extra_mounts+=(-v "$mount_spec")
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
          echo "Warning: Invalid port specification: $port_spec" >&2
        # Validate ports are in the valid TCP/UDP range
        elif [ "$host_port" -lt 1 ] || [ "$host_port" -gt 65535 ] || [ "$container_port" -lt 1 ] || [ "$container_port" -gt 65535 ]; then
          echo "Warning: Port out of range (1-65535): $port_spec" >&2
        else
          # Bind to localhost only (127.0.0.1) to prevent external access
          extra_ports+=(-p "127.0.0.1:$port_spec")
        fi
      done < <(echo "$profile_config" | jq -r '.ports[]')

      # Parse all scalar configuration values in a single jq call
      IFS=$'\t' read -r network_mode audit_log profile_cpu profile_memory \
        profile_pids_limit profile_ulimit_nofile profile_ulimit_fsize \
        < <(echo "$profile_config" | jq -r '[.network, .audit_log, .cpu, .memory, .pids_limit, .ulimit_nofile, .ulimit_fsize] | map(. // "") | @tsv')
    fi
  fi
fi

# --- Git read-only .git mount ---
# When inside a git repo, mount .git as read-only to prevent commits.
# Without SSH keys or git credentials in the container, pushes fail anyway.
git_dir=""
if git -C "$workdir" rev-parse --git-dir &>/dev/null; then
  git_dir="$(cd "$workdir" && git rev-parse --absolute-git-dir)"
  extra_mounts+=(-v "$git_dir:$git_dir:ro")
else
  echo "Warning: Not inside a git repository. Working directory will be writable." >&2
fi

# --- Network mode ---
# Default is "bridge" (normal Docker networking); "none" disables all networking
network_args=()
[[ ! "${network_mode:-bridge}" =~ ^(bridge|none)$ ]] && { echo "Error: Unsupported network mode '$network_mode' (allowed: bridge, none)" >&2; exit 1; }
[[ "${network_mode:-}" == "none" ]] && network_args=(--network none)

# --- Resource limits (opt-in via profile config) ---
resource_args=()
[ -n "${profile_cpu:-}" ] && resource_args+=(--cpus "$profile_cpu")
[ -n "${profile_memory:-}" ] && resource_args+=(--memory "$profile_memory")
[ -n "${profile_pids_limit:-}" ] && resource_args+=(--pids-limit "$profile_pids_limit")
[ -n "${profile_ulimit_nofile:-}" ] && resource_args+=(--ulimit "nofile=$profile_ulimit_nofile")
[ -n "${profile_ulimit_fsize:-}" ] && resource_args+=(--ulimit "fsize=$profile_ulimit_fsize:$profile_ulimit_fsize")

# --- Per-project Dockerfile ---
# If a project provides .claudebox.Dockerfile, build a custom image
# layered on top of the base image for project-specific dependencies
run_image="$IMAGE_NAME"
if [ -f ".claudebox.Dockerfile" ]; then
  run_image="${IMAGE_NAME}-project"
  echo "Building per-project image..." >&2
  # Build quietly (-q) since this runs on every invocation
  if ! docker build -q -f .claudebox.Dockerfile -t "$run_image" . >&2; then
    echo "Error: Failed to build per-project image from .claudebox.Dockerfile" >&2
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
    [[ "${extra_mounts[$i]}" != "-v" && "${extra_mounts[$i]}" != *":ro" ]] && extra_mounts[$i]+=":ro"
  done
fi

# --- Seccomp profile validation ---
# Ensure the seccomp profile exists before running the container
if [ ! -f "$SECCOMP_PROFILE" ]; then
  echo "Error: Seccomp profile not found at $SECCOMP_PROFILE" >&2
  echo "Please reinstall claudebox." >&2
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
  tty_flags="-i"
else
  tty_flags="-it"
fi

# Assemble the complete docker run command as an array for safe quoting
docker_cmd=(
  docker run $tty_flags
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
  -v ~/.claudebox/claude-dotconfig:/home/claude/.config${ro_suffix}
  --tmpfs "/home/claude/.local:rw,nosuid,size=$TMPFS_LOCAL_SIZE,uid=1000,gid=1000"
  # Apply resource limits (if configured in profile)
  ${resource_args[@]+"${resource_args[@]}"}
  # Apply network mode if non-default
  ${network_args[@]+"${network_args[@]}"}
  # Set the working directory inside the container to match the host
  --workdir "$workdir"
  # Mount the current project directory at the same path for path parity
  -v "$workdir:$workdir${ro_suffix}"
  # Persist Claude Code credentials and config across sessions
  -v ~/.claudebox/claude-config:/home/claude/.claude${ro_suffix}
  # Persist Claude Code session state (conversation history, etc.)
  -v ~/.claudebox/.claude.json:/home/claude/.claude.json${ro_suffix}
  # Mount sandbox plugins directory (writable, isolated from host ~/.claude/plugins/)
  -v ~/.claudebox/plugins:/home/claude/.claude/plugins
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
  # Use printf %q for shell-safe quoting of each argument
  printf '%q ' "${docker_cmd[@]}"
  echo
  exit 0
fi

# --- Execute the container ---
if [ "$audit_log" = "true" ]; then
  # With audit logging: use a named container so we can dump logs afterward
  # shellcheck disable=SC2317
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
  echo "Session log: $log_file" >&2

  # Remove the trap and exit with the container's exit code
  trap - INT TERM
  exit $exit_code
else
  exec "${docker_cmd[@]}"
fi
