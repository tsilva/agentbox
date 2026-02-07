#!/bin/bash
#
# claudebox-dev.sh - Development CLI for claudebox
#
# Usage: ./scripts/claudebox-dev.sh <command>
#
# Commands:
#   build      Build the Docker image
#   install    Build image and install standalone script (delegates to install.sh)
#   uninstall  Remove image and standalone script (delegates to uninstall.sh)
#   kill       Stop all running containers
#   update     Pull latest changes and rebuild
#

# Abort on any error
set -euo pipefail

# Resolve the repo root from this script's location (scripts/ → repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Docker image name used for building and running containers
IMAGE_NAME="claudebox"

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
  echo "Run 'claudebox' from any directory to start."
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
    exec "$REPO_ROOT/install.sh"
    ;;
  uninstall)
    exec "$REPO_ROOT/uninstall.sh"
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
