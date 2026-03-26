#!/usr/bin/env bash
#
# repo-common.sh - Shared host-side helpers for repo scripts
#
# These helpers are used by install/dev flows that run from the source tree.
# The installed standalone CLI must remain self-contained and does not source
# this file.
#

CLAUDE_CODE_LATEST_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"
CLAUDEBOX_STATE_DIR="${CLAUDEBOX_STATE_DIR:-$HOME/.claudebox}"

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

fetch_latest_claude_version() {
  local max_time="${1:-5}"
  curl -fsSL --max-time "$max_time" "$CLAUDE_CODE_LATEST_URL"
}

build_cache_bust_key() {
  local latest_version
  latest_version=$(fetch_latest_claude_version "${1:-5}" 2>/dev/null) || true
  if [ -n "$latest_version" ]; then
    printf '%s' "$latest_version"
  else
    date +%s
  fi
}

clear_latest_version_cache() {
  rm -f "$CLAUDEBOX_STATE_DIR/.latest-version"
}

cleanup_replaced_image() {
  local image_name="$1"
  local old_id="${2:-}"

  [ -n "$old_id" ] || return 0

  local new_id
  new_id=$(docker images -q "$image_name:latest" 2>/dev/null || true)
  if [ -n "$new_id" ] && [ "$old_id" != "$new_id" ]; then
    docker rmi "$old_id" 2>/dev/null || true
  fi
}

persist_installed_version() {
  local image_name="$1"
  local installed_version

  installed_version=$(docker run --rm --entrypoint cat "$image_name" /opt/claude-code/VERSION 2>/dev/null) || true
  if [ -n "$installed_version" ]; then
    mkdir -p "$CLAUDEBOX_STATE_DIR"
    printf '%s' "$installed_version" > "$CLAUDEBOX_STATE_DIR/version"
  fi
}
