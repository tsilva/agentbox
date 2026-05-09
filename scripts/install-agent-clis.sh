#!/usr/bin/env bash
# =============================================================================
# install-agent-clis.sh
# Downloads and verifies all agent CLIs included in the agentbox image.
# Installs Claude Code to /opt/claude-code/claude and Codex to /opt/codex/codex.
# =============================================================================

set -euo pipefail

install_claude_code() {
  local gcs_bucket version arch claude_arch expected_sha actual_sha

  gcs_bucket="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
  version="${CLAUDE_CODE_VERSION:-latest}"
  if [ "$version" = "latest" ]; then
    version=$(curl -fsSL "$gcs_bucket/latest")
  fi

  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) claude_arch="linux-x64" ;;
    aarch64|arm64) claude_arch="linux-arm64" ;;
    *) echo "Unsupported architecture for Claude Code: $arch" >&2 && exit 1 ;;
  esac

  echo "Installing Claude Code $version for $claude_arch..."

  curl -fsSL --progress-bar -o /opt/claude-code/claude "$gcs_bucket/$version/$claude_arch/claude"
  chmod +x /opt/claude-code/claude

  expected_sha="${CLAUDE_CODE_SHA256:-}"
  if [ -z "$expected_sha" ]; then
    expected_sha=$(curl -fsSL "$gcs_bucket/$version/manifest.json" | jq -r ".platforms[\"$claude_arch\"].checksum")
  fi
  actual_sha=$(sha256sum /opt/claude-code/claude | cut -d' ' -f1)

  if [ "$expected_sha" != "$actual_sha" ]; then
    echo "Claude Code checksum mismatch! Expected: $expected_sha, Got: $actual_sha" >&2
    exit 1
  fi

  echo "Checksum verified: $actual_sha"
  echo "$version" > /opt/claude-code/VERSION
}

install_codex_cli() {
  local release_api install_dir codex_arch asset_name tmp_dir release_json version
  local download_url digest expected_sha actual_sha release_tag

  release_tag="${CODEX_RELEASE_TAG:-latest}"
  if [ -n "${CODEX_RELEASE_API:-}" ]; then
    release_api="$CODEX_RELEASE_API"
  elif [ "$release_tag" = "latest" ]; then
    release_api="https://api.github.com/repos/openai/codex/releases/latest"
  else
    release_api="https://api.github.com/repos/openai/codex/releases/tags/$release_tag"
  fi
  install_dir="/opt/codex"

  case "$(uname -m)" in
    x86_64|amd64)
      codex_arch="x86_64"
      ;;
    aarch64|arm64)
      codex_arch="aarch64"
      ;;
    *)
      echo "Unsupported architecture for Codex CLI: $(uname -m)" >&2
      exit 1
      ;;
  esac

  asset_name="codex-${codex_arch}-unknown-linux-musl.tar.gz"
  tmp_dir=$(mktemp -d)
  cleanup_codex_tmp() {
    rm -rf "$tmp_dir"
  }
  trap cleanup_codex_tmp RETURN

  echo "Installing Codex CLI from $release_api..."
  release_json=$(curl -fsSL "$release_api")
  version=$(printf '%s' "$release_json" | jq -r '.tag_name')
  download_url=$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url')
  digest=$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest // ""')

  if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
    echo "Could not find Codex release asset: $asset_name" >&2
    exit 1
  fi

  curl -fsSL -o "$tmp_dir/$asset_name" "$download_url"

  expected_sha="${CODEX_SHA256:-}"
  if [ -z "$expected_sha" ] && [[ "$digest" == sha256:* ]]; then
    expected_sha="${digest#sha256:}"
  fi

  if [ -n "$expected_sha" ]; then
    actual_sha=$(sha256sum "$tmp_dir/$asset_name" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "Codex checksum mismatch for $asset_name" >&2
      echo "Expected: $expected_sha" >&2
      echo "Actual:   $actual_sha" >&2
      exit 1
    fi
    echo "Checksum verified: $actual_sha"
  else
    echo "Codex release asset did not include a sha256 digest; refusing unverifiable download" >&2
    exit 1
  fi

  tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  install -m 755 "$tmp_dir/codex-${codex_arch}-unknown-linux-musl" "$install_dir/codex"
  printf '%s\n' "$version" > "$install_dir/VERSION"

  echo "Installed Codex CLI $version"
}

install_claude_code
install_codex_cli
