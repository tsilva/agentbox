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
  version=$(curl -fsSL "$gcs_bucket/latest")

  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) claude_arch="linux-x64" ;;
    aarch64|arm64) claude_arch="linux-arm64" ;;
    *) echo "Unsupported architecture for Claude Code: $arch" >&2 && exit 1 ;;
  esac

  echo "Installing Claude Code $version for $claude_arch..."

  curl -fsSL --progress-bar -o /opt/claude-code/claude "$gcs_bucket/$version/$claude_arch/claude"
  chmod +x /opt/claude-code/claude

  expected_sha=$(curl -fsSL "$gcs_bucket/$version/manifest.json" | jq -r ".platforms[\"$claude_arch\"].checksum")
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
  local download_url digest expected_sha actual_sha

  release_api="${CODEX_RELEASE_API:-https://api.github.com/repos/openai/codex/releases/latest}"
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

  if [[ "$digest" == sha256:* ]]; then
    expected_sha="${digest#sha256:}"
    actual_sha=$(sha256sum "$tmp_dir/$asset_name" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "Codex checksum mismatch for $asset_name" >&2
      echo "Expected: $expected_sha" >&2
      echo "Actual:   $actual_sha" >&2
      exit 1
    fi
    echo "Checksum verified: $actual_sha"
  else
    echo "Warning: release asset did not include a sha256 digest; skipping checksum verification" >&2
  fi

  tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  install -m 755 "$tmp_dir/codex-${codex_arch}-unknown-linux-musl" "$install_dir/codex"
  printf '%s\n' "$version" > "$install_dir/VERSION"

  echo "Installed Codex CLI $version"
}

install_claude_code
install_codex_cli
