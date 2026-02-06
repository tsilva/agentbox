#!/bin/bash
#
# claudebox-dev.sh - Development CLI for claudebox
#
# Usage: ./claudebox-dev.sh <command>
#
# Commands:
#   build      Build the Docker image
#   install    Build image and install standalone script
#   uninstall  Remove image and standalone script
#   kill       Stop all running containers
#   update     Pull latest changes and rebuild
#

# Abort on any error
set -euo pipefail

# Resolve the repo root from this script's location (works even if invoked via symlink)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Docker image name used for building and running containers
IMAGE_NAME="claudebox"
# Name of the installed CLI command the user will invoke
SCRIPT_NAME="claudebox"

# Detect the user's shell RC file for PATH configuration.
# Returns the path to the first found RC file, defaulting to .zshrc (macOS default).
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
# Called before any command that requires Docker.
check_runtime() {
  # Verify the docker binary is installed and on PATH
  if ! command -v docker &>/dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    echo "Please install Docker Desktop: https://docs.docker.com/get-docker/"
    exit 1
  fi

  # Verify the Docker daemon is responsive (not just installed)
  if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running." >&2
    echo "Please start Docker Desktop and try again." >&2
    exit 1
  fi
}

# Build the Docker image from the repo's Dockerfile
do_build() {
  # Ensure Docker is available before attempting a build
  check_runtime

  echo "Building $IMAGE_NAME image..."
  # Build from the repo root which contains the Dockerfile
  docker build -t "$IMAGE_NAME" "$REPO_ROOT"

  # Extract the baked-in Claude Code version so the host CLI can check for updates
  installed_version=$(docker run --rm --entrypoint cat "$IMAGE_NAME" /opt/claude-code/VERSION 2>/dev/null) || true
  if [ -n "$installed_version" ]; then
    mkdir -p "$HOME/.claudebox"
    printf '%s' "$installed_version" > "$HOME/.claudebox/version"
  fi

  echo ""
  echo "Done! Image '$IMAGE_NAME' is ready."
  echo "Run '$SCRIPT_NAME' from any directory to start."
}

# Build the image and install the standalone CLI script to ~/.claudebox/bin/
do_install() {
  # Build the image first (calls check_runtime internally)
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
  # Make the generated script executable
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

# Remove the Docker image and the installed standalone script
do_uninstall() {
  # Ensure Docker is available to remove the image
  check_runtime

  # Prompt for confirmation before destructive operations
  read -rp "This will remove the $IMAGE_NAME image and standalone script. Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
  fi

  # Remove the Docker image (ignore errors if already removed)
  echo "Removing $IMAGE_NAME image..."
  docker image rm "$IMAGE_NAME" 2>/dev/null || echo "Image not found, skipping"

  # Remove the standalone CLI script from ~/.claudebox/bin/
  local script_path="$HOME/.claudebox/bin/$SCRIPT_NAME"
  if [ -f "$script_path" ]; then
    rm -f "$script_path"
    echo "Removed $script_path"
  else
    echo "Script not found at $script_path, skipping"
  fi

  # Remove alias symlink
  local alias_path="$HOME/.claudebox/bin/claudes"
  if [ -L "$alias_path" ] || [ -f "$alias_path" ]; then
    rm -f "$alias_path"
    echo "Removed $alias_path"
  fi

  # Remove seccomp profile
  local seccomp_path="$HOME/.claudebox/seccomp.json"
  if [ -f "$seccomp_path" ]; then
    rm -f "$seccomp_path"
    echo "Removed seccomp profile"
  fi

  local shell_rc
  shell_rc="$(detect_shell_rc)"

  # Remove the PATH entry and comment block from the shell config
  if grep -qF '.claudebox/bin' "$shell_rc" 2>/dev/null; then
    echo "Removing PATH entry from $shell_rc..."
    # Delete both the "# claudebox" comment line and the PATH export line
    sed -i.bak '/^# claudebox$/d;/\.claudebox\/bin/d' "$shell_rc"
    # Clean up the backup file created by sed -i
    rm -f "$shell_rc.bak"
    echo "PATH entry removed."
  else
    echo "PATH entry not found in $shell_rc, skipping"
  fi

  echo ""
  echo "Uninstall complete."
  echo ""
  echo "Run: source $shell_rc"
}

# Stop all running containers spawned from the claudebox image
do_kill_containers() {
  # Ensure Docker is available to query/stop containers
  check_runtime

  echo "Finding running $IMAGE_NAME containers..."

  # List container IDs filtered by the ancestor image
  local containers
  containers=$(docker ps -q --filter "ancestor=$IMAGE_NAME" 2>/dev/null)

  # Nothing to do if no containers are running
  if [ -z "$containers" ]; then
    echo "No $IMAGE_NAME containers found running."
    return 0
  fi

  # Gracefully stop each container; force-kill if stop fails
  echo "Stopping containers..."
  for id in $containers; do
    echo "  - $id"
    docker stop "$id" 2>/dev/null || docker kill "$id" 2>/dev/null || true
  done

  echo ""
  echo "All $IMAGE_NAME containers stopped."
}

# Read the first CLI argument as the command (default: empty → show usage)
cmd="${1:-}"

# Dispatch to the appropriate handler based on the command
case "$cmd" in
  build)
    do_build
    ;;
  install)
    do_install
    ;;
  uninstall)
    do_uninstall
    ;;
  kill)
    do_kill_containers
    ;;
  update)
    # Pull latest git changes, then rebuild the image
    echo "Pulling latest changes..."
    git -C "$REPO_ROOT" pull
    do_build
    ;;
  *)
    # No valid command — print usage and exit with error
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  build      Build the Docker image"
    echo "  install    Build image and install standalone script"
    echo "  uninstall  Remove image and standalone script"
    echo "  kill       Stop all running containers"
    echo "  update     Pull latest changes and rebuild"
    exit 1
    ;;
esac
