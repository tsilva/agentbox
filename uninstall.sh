#!/usr/bin/env bash
#
# uninstall.sh - Standalone claudebox uninstaller
#
# Removes the Docker image, installed scripts, seccomp profile,
# and PATH entry from the user's shell config.
#

set -euo pipefail

# Docker image name to remove
IMAGE_NAME="claudebox"
# Name of the installed CLI command
SCRIPT_NAME="claudebox"

# Detect the user's shell RC file for PATH cleanup.
detect_shell_rc() {
  if [ -f "$HOME/.zshrc" ]; then
    echo "$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    echo "$HOME/.bashrc"
  else
    echo "$HOME/.zshrc"
    echo "Warning: Neither .zshrc nor .bashrc found, defaulting to $HOME/.zshrc" >&2
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

do_uninstall() {
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

do_uninstall
