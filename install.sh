#!/usr/bin/env bash
#
# install.sh - Self-contained claudebox installer (dual-mode)
#
# Modes:
#   Curl pipe:  curl -fsSL .../install.sh | bash   (clones repo, then re-execs)
#   Local repo: ./install.sh                        (builds image + installs CLI)
#

set -euo pipefail

# Docker image name used for building and running containers
IMAGE_NAME="claudebox"
# Name of the installed CLI command the user will invoke
SCRIPT_NAME="claudebox"
# Repo URL for curl-pipe mode
REPO_URL="https://github.com/tsilva/claudebox.git"
# Clone destination for curl-pipe installs
CLONE_DIR="$HOME/.claudebox/repo"

# --- Dual-mode detection ---
# When piped via curl, BASH_SOURCE[0] is empty or unset.
# When run as a file, it resolves to the script path.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ ! -f "${BASH_SOURCE[0]}" ]; then
  # Curl-pipe mode: clone/update repo, then re-exec the cloned install.sh
  echo "Installing claudebox..."

  if [ -d "$CLONE_DIR" ]; then
    echo "Updating existing installation..."
    git -C "$CLONE_DIR" pull --ff-only
  else
    echo "Cloning repository..."
    mkdir -p "$(dirname "$CLONE_DIR")"
    git clone "$REPO_URL" "$CLONE_DIR"
  fi

  exec "$CLONE_DIR/install.sh"
fi

# --- Local repo mode ---
# Resolve the repo root from this script's location
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the user's shell RC file for PATH configuration.
detect_shell_rc() {
  if [ -f "$HOME/.zshrc" ]; then
    echo "$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.zshrc"
    echo "Warning: Neither .zshrc nor .bashrc found, creating $HOME/.zshrc" >&2
    echo "If you use a different shell, add the function to your shell config manually." >&2
  fi
}

# Check if Docker CLI is available and the daemon is running.
check_runtime() {
  if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    echo "Please install Docker Desktop: https://docs.docker.com/get-docker/"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running." >&2
    echo "Please start Docker Desktop and try again." >&2
    exit 1
  fi
}

# Build the Docker image from the repo's Dockerfile
do_build() {
  check_runtime

  echo "Building $IMAGE_NAME image..."
  docker build -t "$IMAGE_NAME" "$REPO_ROOT"

  # Extract the baked-in Claude Code version so the host CLI can check for updates
  installed_version=$(docker run --rm --entrypoint cat "$IMAGE_NAME" /opt/claude-code/VERSION 2>/dev/null) || true
  if [ -n "$installed_version" ]; then
    mkdir -p "$HOME/.claudebox"
    printf '%s' "$installed_version" > "$HOME/.claudebox/version"
  fi

  echo ""
  echo "Done! Image '$IMAGE_NAME' is ready."
}

# Build the image and install the standalone CLI script to ~/.claudebox/bin/
do_install() {
  do_build

  local shell_rc
  shell_rc="$(detect_shell_rc)"

  # Create the bin directory and generate the standalone script from the template
  local bin_dir="$HOME/.claudebox/bin"
  local script_path="$bin_dir/$SCRIPT_NAME"
  mkdir -p "$bin_dir"

  # Replace placeholders in the template with the actual image name
  sed "s|PLACEHOLDER_IMAGE_NAME|$IMAGE_NAME|g" \
    "${REPO_ROOT}/scripts/claudebox-template.sh" > "$script_path"
  chmod +x "$script_path"
  echo "Installed $script_path"

  # Copy the seccomp profile to the install directory
  cp "${REPO_ROOT}/scripts/seccomp.json" "$HOME/.claudebox/seccomp.json"
  echo "Installed $HOME/.claudebox/seccomp.json"

  # Store repo path so `claudebox update` can find the source tree
  printf '%s' "$REPO_ROOT" > "$HOME/.claudebox/.repo-path"

  # Create alias symlink
  ln -sf "$SCRIPT_NAME" "$bin_dir/claudes"
  echo "Installed $bin_dir/claudes (alias)"

  # Add the bin directory to PATH in the user's shell config (idempotent)
  # shellcheck disable=SC2016
  local path_line='export PATH="$HOME/.claudebox/bin:$PATH"'
  if ! grep -qF '.claudebox/bin' "$shell_rc" 2>/dev/null; then
    {
      echo ""
      echo "# claudebox"
      echo "$path_line"
    } >> "$shell_rc"
    echo "Added PATH entry to $shell_rc"
  else
    echo "PATH entry already present in $shell_rc"
  fi

  # Print post-install instructions
  echo ""
  echo "Installation complete!"
  echo ""
  echo "Run: source $shell_rc"
  echo ""
  echo "First-time setup (authenticate with Claude subscription):"
  echo "  $SCRIPT_NAME login"
  echo ""
  echo "Then from any project directory:"
  echo "  cd <your-project> && $SCRIPT_NAME"
  echo ""
  echo "To inspect the sandbox environment:"
  echo "  $SCRIPT_NAME shell"
}

do_install
