#!/usr/bin/env bash
#
# uninstall.sh - Standalone claudebox uninstaller
#
# Removes the Docker image, installed scripts, seccomp profile,
# and PATH entry from the user's shell config.
#

set -euo pipefail

# Source terminal styling library (graceful fallback to plain echo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=style.sh
source "$SCRIPT_DIR/style.sh" 2>/dev/null || true

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
    warn "Neither .zshrc nor .bashrc found, defaulting to $HOME/.zshrc"
  fi
}

# Check if Docker CLI is available and the daemon is running.
check_runtime() {
  if ! command -v docker &>/dev/null; then
    error_block "Docker is not installed or not in PATH" \
      "Please install Docker Desktop: https://docs.docker.com/get-docker/"
    exit 1
  fi

  if ! docker info &>/dev/null; then
    error_block "Docker daemon is not running" \
      "Please start Docker Desktop and try again."
    exit 1
  fi
}

do_uninstall() {
  check_runtime

  # Prompt for confirmation before destructive operations
  header "claudebox" "uninstaller"
  confirm "Remove $IMAGE_NAME image and standalone script?"
  if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    info "Uninstall cancelled"
    exit 0
  fi

  # Remove the Docker image (ignore errors if already removed)
  step "Removing $IMAGE_NAME image"
  docker image rm "$IMAGE_NAME" 2>/dev/null || dim "Image not found, skipping"

  # Remove the standalone CLI script from ~/.claudebox/bin/
  local script_path="$HOME/.claudebox/bin/$SCRIPT_NAME"
  if [ -f "$script_path" ]; then
    rm -f "$script_path"
    success "Removed $script_path"
  else
    dim "Script not found at $script_path, skipping"
  fi

  # Remove alias symlink
  local alias_path="$HOME/.claudebox/bin/claudes"
  if [ -L "$alias_path" ] || [ -f "$alias_path" ]; then
    rm -f "$alias_path"
    success "Removed $alias_path"
  fi

  # Remove seccomp profile
  local seccomp_path="$HOME/.claudebox/seccomp.json"
  if [ -f "$seccomp_path" ]; then
    rm -f "$seccomp_path"
    success "Removed seccomp profile"
  fi

  # Remove style library
  local style_path="$HOME/.claudebox/bin/style.sh"
  if [ -f "$style_path" ]; then
    rm -f "$style_path"
    success "Removed $style_path"
  fi

  local shell_rc
  shell_rc="$(detect_shell_rc)"

  # Remove the PATH entry and comment block from the shell config
  if grep -qF '.claudebox/bin' "$shell_rc" 2>/dev/null; then
    step "Removing PATH entry from $shell_rc"
    # Delete both the "# claudebox" comment line and the PATH export line
    sed -i.bak '/^# claudebox$/d;/\.claudebox\/bin/d' "$shell_rc"
    # Clean up the backup file created by sed -i
    rm -f "$shell_rc.bak"
    success "PATH entry removed"
  else
    dim "PATH entry not found in $shell_rc, skipping"
  fi

  banner "Uninstall complete"
  note "Run: source $shell_rc"
  echo ""
}

do_uninstall
