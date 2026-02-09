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

# Source terminal styling library (graceful fallback to plain echo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/style.sh
source "$SCRIPT_DIR/style.sh" 2>/dev/null || true

# Resolve the repo root from this script's location (scripts/ → repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Docker image name used for building and running containers
IMAGE_NAME="claudebox"

# Check if Docker CLI is available and the daemon is running.
# Called before any command that requires Docker.
check_runtime() {
  # Verify the docker binary is installed and on PATH
  if ! command -v docker &>/dev/null; then
    error_block "Docker is not installed or not in PATH" \
      "Please install Docker Desktop: https://docs.docker.com/get-docker/"
    exit 1
  fi

  # Verify the Docker daemon is responsive (not just installed)
  if ! docker info &>/dev/null; then
    error_block "Docker daemon is not running" \
      "Please start Docker Desktop and try again."
    exit 1
  fi
}

# Build the Docker image from the repo's Dockerfile
# Pass --bust-cache to invalidate the Claude Code download layer
do_build() {
  # Ensure Docker is available before attempting a build
  check_runtime

  local build_args=()
  local old_id=""
  if [ "${1:-}" = "--bust-cache" ]; then
    # Use Claude Code version as cache key so Docker caches the download layer
    # when the version hasn't changed. Fall back to timestamp if fetch fails.
    local cache_key
    cache_key=$(curl -fsSL --max-time 5 \
      "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest" 2>/dev/null) || true
    [ -z "$cache_key" ] && cache_key="$(date +%s)"
    build_args+=(--build-arg "CACHE_BUST=$cache_key")
    old_id=$(docker images -q "$IMAGE_NAME:latest" 2>/dev/null || true)
  fi

  step "Building $IMAGE_NAME image"
  # Build from the repo root which contains the Dockerfile
  docker build ${build_args[@]+"${build_args[@]}"} -t "$IMAGE_NAME" "$REPO_ROOT"

  # Remove the previous image to avoid dangling image accumulation.
  # docker rmi safely refuses if containers are still using the old image.
  if [ -n "$old_id" ]; then
    local new_id
    new_id=$(docker images -q "$IMAGE_NAME:latest" 2>/dev/null || true)
    if [ "$old_id" != "$new_id" ]; then
      docker rmi "$old_id" 2>/dev/null || true
    fi
  fi

  # Extract the baked-in Claude Code version so the host CLI can check for updates
  installed_version=$(docker run --rm --entrypoint cat "$IMAGE_NAME" /opt/claude-code/VERSION 2>/dev/null) || true
  if [ -n "$installed_version" ]; then
    mkdir -p "$HOME/.claudebox"
    printf '%s' "$installed_version" > "$HOME/.claudebox/version"
  fi

  success "Image '$IMAGE_NAME' is ready"
  info "Run 'claudebox' from any directory to start"
}

# Stop all running containers spawned from the claudebox image
do_kill_containers() {
  # Ensure Docker is available to query/stop containers
  check_runtime

  step "Finding running $IMAGE_NAME containers"

  # List container IDs filtered by the ancestor image
  local containers
  containers=$(docker ps -q --filter "ancestor=$IMAGE_NAME" 2>/dev/null)

  # Nothing to do if no containers are running
  if [ -z "$containers" ]; then
    info "No $IMAGE_NAME containers found running"
    return 0
  fi

  # Gracefully stop each container; force-kill if stop fails
  step "Stopping containers"
  for id in $containers; do
    list_item "Container" "$id"
    docker stop "$id" 2>/dev/null || docker kill "$id" 2>/dev/null || true
  done

  success "All $IMAGE_NAME containers stopped"
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
    step "Pulling latest changes"
    git -C "$REPO_ROOT" pull
    rm -f "$HOME/.claudebox/.latest-version"
    do_build --bust-cache
    ;;
  *)
    # No valid command — print usage and exit with error
    header "claudebox" "dev"
    list_item "build" "Build the Docker image"
    list_item "install" "Build image and install standalone script"
    list_item "uninstall" "Remove image and standalone script"
    list_item "kill" "Stop all running containers"
    list_item "update" "Pull latest changes and rebuild"
    echo ""
    exit 1
    ;;
esac
