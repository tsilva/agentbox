#!/usr/bin/env bash
#
# install.sh - Self-contained agentbox installer (dual-mode)
#
# Modes:
#   Curl pipe:  curl -fsSL .../install.sh | bash   (clones repo, then re-execs)
#   Local repo: ./install.sh                        (builds image + installs CLI)
#

set -euo pipefail

# Source terminal styling library (graceful fallback to plain echo)
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
# shellcheck source=style.sh
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/style.sh" ]; then
  source "${SCRIPT_DIR:-}/style.sh"
fi

# Piped installation must never source a style.sh from the current project.
if ! declare -F header >/dev/null; then
  header() { printf '%s\n' "$*"; }
  step() { printf '%s\n' "$*"; }
  error() { printf '%s\n' "$*" >&2; }
fi

# Docker image name used for building and running containers
IMAGE_NAME="agentbox"
# Name of the installed CLI command the user will invoke
SCRIPT_NAME="agentbox"
# Repo URL for curl-pipe mode
REPO_URL="https://github.com/tsilva/agentbox.git"
# Clone destination for curl-pipe installs
CLONE_DIR="$HOME/.agentbox/repo"

# --- Dual-mode detection ---
# When piped via curl, BASH_SOURCE[0] is empty or unset.
# When run as a file, it resolves to the script path.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  if [ -L "$HOME/.agentbox" ] || [ -L "$CLONE_DIR" ]; then
    error 'Refusing symlinked installation state'; exit 1
  fi
  # Curl-pipe mode: clone/update repo, then re-exec the cloned install.sh
  header "agentbox" "installer"

  if [ -d "$CLONE_DIR" ]; then
    step "Updating existing installation"
    git -C "$CLONE_DIR" pull --ff-only
  else
    step "Cloning repository"
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone "$REPO_URL" "$CLONE_DIR"
  fi

  exec "$CLONE_DIR/install.sh" "$@"
fi

# --- Local repo mode ---
# Resolve the repo root from this script's location
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/repo-common.sh
source "$REPO_ROOT/scripts/repo-common.sh"

update_mode=false
locked_mode=false
install_runtime=""
python_tools=0
install_source=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --update) update_mode=true ;;
    --locked) locked_mode=true; install_source=build ;;
    --build) install_source=build ;;
    --prebuilt) install_source=prebuilt ;;
    --python) python_tools=1 ;;
    --runtime) shift; install_runtime="${1:-}" ;;
    --help) echo 'Usage: install.sh [--runtime claude|codex] [--python] [--build|--prebuilt] [--locked]'; exit 0 ;;
    *) error "Unknown installer argument: $1"; exit 1 ;;
  esac
  [ $# -gt 0 ] && shift
done
[ "$locked_mode" != true ] || install_source=build
if [ -z "$install_runtime" ]; then
  install_runtime=claude
  [ ! -f "$HOME/.agentbox/default-runtime" ] || install_runtime=$(cat "$HOME/.agentbox/default-runtime")
fi
[[ "$install_runtime" =~ ^(claude|codex)$ ]] || { error 'Runtime must be claude or codex'; exit 1; }
if [ "$update_mode" = true ]; then
  if [ -f "$HOME/.agentbox/python-tools-$install_runtime" ]; then
    python_tools=$(cat "$HOME/.agentbox/python-tools-$install_runtime")
  elif [ -f "$HOME/.agentbox/python-tools" ]; then
    python_tools=$(cat "$HOME/.agentbox/python-tools")
  fi
fi
[[ "$python_tools" =~ ^[01]$ ]] || { error 'Invalid saved Python tool selection'; exit 1; }
IMAGE_NAME="agentbox-$install_runtime"
[ "$python_tools" = 0 ] || IMAGE_NAME="$IMAGE_NAME-python"

require_locked_build_value() {
  local name="$1"
  local value="${!name:-}"

  if [ -z "$value" ]; then
    error "Locked builds require $name"
    exit 1
  fi
}

# Detect the user's shell RC file for PATH configuration.
detect_shell_rc() {
  if [ -f "$HOME/.zshrc" ]; then
    echo "$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.zshrc"
    warn "Neither .zshrc nor .bashrc found, creating $HOME/.zshrc"
    note "If you use a different shell, add the function to your shell config manually."
  fi
}

# Build the Docker image from the repo's Dockerfile
do_build() {
  check_runtime

  step "Building $IMAGE_NAME image"
  local build_args=()

  if [ "$locked_mode" = true ]; then
    require_locked_build_value AGENTBOX_BASE_IMAGE
    require_locked_build_value AGENTBOX_CLAUDE_CODE_VERSION
    require_locked_build_value AGENTBOX_CLAUDE_CODE_SHA256
    require_locked_build_value AGENTBOX_CODEX_RELEASE_TAG
    require_locked_build_value AGENTBOX_CODEX_SHA256
    if [[ "$AGENTBOX_BASE_IMAGE" != *@sha256:* ]]; then
      error "Locked builds require AGENTBOX_BASE_IMAGE to include an immutable @sha256 digest"
      exit 1
    fi
    build_args+=(
      --build-arg "BASE_IMAGE=$AGENTBOX_BASE_IMAGE"
      --build-arg "CLAUDE_CODE_VERSION=$AGENTBOX_CLAUDE_CODE_VERSION"
      --build-arg "CLAUDE_CODE_SHA256=$AGENTBOX_CLAUDE_CODE_SHA256"
      --build-arg "CODEX_RELEASE_TAG=$AGENTBOX_CODEX_RELEASE_TAG"
      --build-arg "CODEX_SHA256=$AGENTBOX_CODEX_SHA256"
      --build-arg "CODEX_CODE_MODE_SHA256=${AGENTBOX_CODEX_CODE_MODE_SHA256:-}"
    )
  else
    # Always use latest Claude Code version as cache key so fresh installs
    # get the newest binary while still reusing cache when version is unchanged.
    local cache_key
    cache_key=$(build_cache_bust_key 5)
    build_args+=(--build-arg "CACHE_BUST=$cache_key")
  fi

  # Track old image ID for cleanup during updates
  local old_id=""
  if [ "$update_mode" = true ]; then
    old_id=$(docker images -q "$IMAGE_NAME:latest" 2>/dev/null || true)
  fi
  docker build ${build_args[@]+"${build_args[@]}"} --target "$install_runtime" --build-arg "PYTHON_TOOLS=$python_tools" -t "$IMAGE_NAME" "$REPO_ROOT"
  docker build ${build_args[@]+"${build_args[@]}"} --target broker -t agentbox-broker "$REPO_ROOT"

  cleanup_replaced_image "$IMAGE_NAME" "$old_id"
  persist_installed_version "$IMAGE_NAME"

  success "Image '$IMAGE_NAME' is ready"
}

install_prebuilt() {
  check_runtime
  local manifest status key image broker
  manifest=$(mktemp)
  status=$(curl -sSL --max-time 15 -o "$manifest" -w '%{http_code}' \
    https://github.com/tsilva/agentbox/releases/latest/download/images.json) || { rm -f "$manifest"; error 'Release lookup failed'; exit 1; }
  if [ "$status" = 404 ]; then rm -f "$manifest"; return 1; fi
  [ "$status" = 200 ] || { rm -f "$manifest"; error "Release lookup returned HTTP $status"; exit 1; }
  for tool in jq cosign; do
    command -v "$tool" >/dev/null || { rm -f "$manifest"; error "Prebuilt verification requires $tool; install it or use --build"; exit 1; }
  done
  jq -e ' .schemaVersion == 1 and (.images | type == "object") ' "$manifest" >/dev/null || { rm -f "$manifest"; error "Unsupported release image index"; exit 1; }
  key="$install_runtime"
  [ "$python_tools" = 0 ] || key="$key-python"
  image=$(jq -er --arg key "$key" '.images[$key].reference | strings' "$manifest") || { rm -f "$manifest"; error 'Invalid release image index'; exit 1; }
  broker=$(jq -er '.images.broker.reference | strings' "$manifest") || { rm -f "$manifest"; error 'Missing broker image'; exit 1; }
  rm -f "$manifest"
  if ! [[ "$image" =~ ^ghcr\.io/tsilva/agentbox-$key@sha256:[a-f0-9]{64}$ ]] ||
    ! [[ "$broker" =~ ^ghcr\.io/tsilva/agentbox-broker@sha256:[a-f0-9]{64}$ ]]; then
    error 'Release references must be agentbox images pinned by SHA-256'
    exit 1
  fi
  for ref in "$image" "$broker"; do
    cosign verify --certificate-identity \
      https://github.com/tsilva/agentbox/.github/workflows/release-images.yml@refs/heads/main \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com "$ref" >/dev/null || { error 'Image signature verification failed'; exit 1; }
    docker pull "$ref" || { error "Verified image could not be pulled"; exit 1; }
  done
  IMAGE_NAME="$image"
  BROKER_IMAGE="$broker"
  persist_installed_version "$IMAGE_NAME"
}

# Build the image and install the standalone CLI script to ~/.agentbox/bin/
do_install() {
  header "agentbox" "installer"

  if [ -L "$HOME/.agentbox" ]; then error 'Refusing symlinked installation state'; exit 1; fi
  mkdir -p "$HOME/.agentbox/images"
  chmod 700 "$HOME/.agentbox" "$HOME/.agentbox/images"
  if [ "$install_source" = build ]; then
    do_build
  elif ! install_prebuilt; then
    # Only absence of a release (404) permits the bootstrap source-build path.
    [ "$install_source" = auto ] || { error 'No prebuilt release available; use --build'; exit 1; }
    info 'No prebuilt release published yet; building the selected runtime locally'
    do_build
  fi

  local shell_rc
  shell_rc="$(detect_shell_rc)"

  # Create the bin directory and generate the standalone script from the template
  local bin_dir="$HOME/.agentbox/bin"
  local script_path="$bin_dir/$SCRIPT_NAME"
  mkdir -p "$bin_dir"

  # Replace placeholders in the template with the actual image name
  local script_tmp
  script_tmp=$(mktemp "$bin_dir/.agentbox.XXXXXXXX")
  "$REPO_ROOT/scripts/render-cli.sh" agentbox > "$script_tmp"
  chmod 755 "$script_tmp"
  mv "$script_tmp" "$script_path"
  cp "$REPO_ROOT/scripts/workspace.py" "$bin_dir/workspace.py"
  printf '%s' "$IMAGE_NAME" > "$HOME/.agentbox/images/$install_runtime"
  printf '%s' "${BROKER_IMAGE:-agentbox-broker}" > "$HOME/.agentbox/images/broker"
  printf '%s' "$install_runtime" > "$HOME/.agentbox/default-runtime"
  printf '%s' "$python_tools" > "$HOME/.agentbox/python-tools"
  printf '%s' "$python_tools" > "$HOME/.agentbox/python-tools-$install_runtime"
  success "Installed $script_path"

  # Copy the seccomp profile to the install directory
  cp "${REPO_ROOT}/scripts/seccomp.json" "$HOME/.agentbox/seccomp.json"
  success "Installed $HOME/.agentbox/seccomp.json"

  # Copy the trusted entrypoint used to override repo-controlled project images
  cp "${REPO_ROOT}/entrypoint.sh" "$HOME/.agentbox/entrypoint.sh"
  chmod +x "$HOME/.agentbox/entrypoint.sh"
  success "Installed $HOME/.agentbox/entrypoint.sh"

  # Copy the style library for the standalone CLI
  cp "${REPO_ROOT}/style.sh" "$bin_dir/style.sh"
  success "Installed $bin_dir/style.sh"

  # Store repo path so `agentbox update` can find the source tree
  printf '%s' "$REPO_ROOT" > "$HOME/.agentbox/.repo-path"

  # Create alias symlink
  ln -sf "$SCRIPT_NAME" "$bin_dir/claudes"
  success "Installed $bin_dir/claudes (alias)"

  # Add the bin directory to PATH in the user's shell config (idempotent)
  # shellcheck disable=SC2016
  local path_line='export PATH="$HOME/.agentbox/bin:$PATH"'
  if ! grep -qF '.agentbox/bin' "$shell_rc" 2>/dev/null; then
    {
      echo ""
      echo "# agentbox"
      echo "$path_line"
    } >> "$shell_rc"
    success "Added PATH entry to $shell_rc"
  else
    info "PATH entry already present in $shell_rc"
  fi

  banner "Installation complete!"
  list_item "Activate" "source $shell_rc"
  list_item "Set up a project" "cd <your-project> && $SCRIPT_NAME init --$install_runtime"
  list_item "Start" "$SCRIPT_NAME"
  note "Project setup requires jq. Authentication uses your host login or provider API key."
  echo ""
}

do_install
