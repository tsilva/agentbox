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
# shellcheck source=../style.sh
if [ -f "$SCRIPT_DIR/../style.sh" ]; then
  source "$SCRIPT_DIR/../style.sh"
fi

# Resolve the repo root from this script's location (scripts/ → repo root)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=repo-common.sh
source "$SCRIPT_DIR/repo-common.sh"
# Docker image name used for building and running containers
IMAGE_NAME="claudebox"

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
    cache_key=$(build_cache_bust_key 5)
    build_args+=(--build-arg "CACHE_BUST=$cache_key")
    old_id=$(docker images -q "$IMAGE_NAME:latest" 2>/dev/null || true)
  fi

  step "Building $IMAGE_NAME image"
  # Build from the repo root which contains the Dockerfile
  docker build ${build_args[@]+"${build_args[@]}"} -t "$IMAGE_NAME" "$REPO_ROOT"

  cleanup_replaced_image "$IMAGE_NAME" "$old_id"
  persist_installed_version "$IMAGE_NAME"

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
    clear_latest_version_cache
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
