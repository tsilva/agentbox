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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd 2>/dev/null)" || true
# shellcheck source=style.sh
if [ -f "${SCRIPT_DIR:-}/style.sh" ]; then
  source "${SCRIPT_DIR:-}/style.sh"
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

  exec "$CLONE_DIR/install.sh"
fi

# --- Local repo mode ---
# Resolve the repo root from this script's location
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/repo-common.sh
source "$REPO_ROOT/scripts/repo-common.sh"

# Parse --update flag (passed by `agentbox update` to bust Docker cache)
update_mode=false
locked_mode=false
for arg in "$@"; do
  [ "$arg" = "--update" ] && update_mode=true
  [ "$arg" = "--locked" ] && locked_mode=true
done

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
  docker build ${build_args[@]+"${build_args[@]}"} -t "$IMAGE_NAME" "$REPO_ROOT"

  cleanup_replaced_image "$IMAGE_NAME" "$old_id"
  persist_installed_version "$IMAGE_NAME"

  success "Image '$IMAGE_NAME' is ready"
}

# Build the image and install the standalone CLI script to ~/.agentbox/bin/
do_install() {
  header "agentbox" "installer"

  if [ "$update_mode" = false ] && [ -f "$HOME/.agentbox/bin/$SCRIPT_NAME" ]; then
    warn "agentbox is already installed"
    confirm "Reinstall?"
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      info "Install cancelled"
      exit 0
    fi
    "$REPO_ROOT/uninstall.sh" --yes
  fi
  do_build

  local shell_rc
  shell_rc="$(detect_shell_rc)"

  # Create the bin directory and generate the standalone script from the template
  local bin_dir="$HOME/.agentbox/bin"
  local script_path="$bin_dir/$SCRIPT_NAME"
  mkdir -p "$bin_dir"

  # Replace placeholders in the template with the actual image name
  sed "s|PLACEHOLDER_IMAGE_NAME|$IMAGE_NAME|g" \
    "${REPO_ROOT}/scripts/agentbox-template.sh" > "$script_path"
  chmod +x "$script_path"
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
  list_item "Claude" "cd <your-project> && $SCRIPT_NAME --claude"
  list_item "Codex" "cd <your-project> && $SCRIPT_NAME --codex"
  list_item "Shell" "$SCRIPT_NAME --claude shell"
  echo ""
}

do_install
