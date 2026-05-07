#!/bin/bash
set -euo pipefail

# Recreate symlink on tmpfs (rootfs is read-only, ~/.local is a tmpfs)
# Agent binaries live under /opt to avoid collision with config volume mounts,
# so symlink them into PATH on every boot.
mkdir -p /home/claude/.local/bin
mkdir -p /home/claude/.claude
mkdir -p /home/claude/.codex
ln -sf /opt/claude-code/claude /home/claude/.local/bin/claude
ln -sf /opt/codex/codex /home/claude/.local/bin/codex

# Intentionally do not auto-source project-managed activation scripts.
# A repo-controlled .venv/bin/activate would execute arbitrary shell code
# before Claude starts. Users can still activate a venv manually if needed.

claude_md_path="/home/claude/.claude/CLAUDE.md"
codex_agents_path="/home/claude/.codex/AGENTS.md"
# The wrapper makes this path a symlink to ~/.claude/runtime/CLAUDE.md, with
# runtime backed by tmpfs so it stays writable even when ~/.claude is read-only.

write_sandbox_awareness() {
  local output_path="$1"
  local heading="$2"

  printf '# %s\n\n' "$heading" > "$output_path"
  cat >> "$output_path" << 'SANDBOX_EOF'
# Sandbox Environment (agentbox)

You are running inside an isolated Docker sandbox. Be aware of these constraints:

## Filesystem Restrictions
- Root filesystem is **read-only**
- Writable locations: `/tmp`, `~/.cache`, `~/.npm`, `~/.local`, mounted project directory
- Blocked paths: `~/.ssh`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker`, `~/.gnupg`
- `.git` directory is **read-only** — you cannot commit or push

## Recommendations
- Do not attempt `git commit`, `git push`, or similar write operations to `.git`
- Do not try to access SSH keys or cloud provider credentials (they are not mounted)
- Use `/tmp` for temporary files
SANDBOX_EOF

  {
    echo ""
    echo "## Current Profile Settings"
    echo "- Runtime: ${AGENTBOX_RUNTIME:-claude}"
    echo "- Network mode: ${AGENTBOX_NETWORK_MODE:-bridge}"
    [ -n "${AGENTBOX_CPU_LIMIT:-}" ] && echo "- CPU limit: $AGENTBOX_CPU_LIMIT"
    [ -n "${AGENTBOX_MEMORY_LIMIT:-}" ] && echo "- Memory limit: $AGENTBOX_MEMORY_LIMIT"
    [ -n "${AGENTBOX_PIDS_LIMIT:-}" ] && echo "- Process limit: $AGENTBOX_PIDS_LIMIT"
    [ "${AGENTBOX_READONLY:-false}" = "true" ] && echo "- Workspace: **read-only** (--readonly flag)"

    if [ -n "${AGENTBOX_EXTRA_MOUNTS:-}" ]; then
      echo ""
      echo "## Extra Mounts"
      echo "$AGENTBOX_EXTRA_MOUNTS"
    fi

    if [ "${AGENTBOX_NETWORK_MODE:-bridge}" = "none" ]; then
      echo ""
      echo "## Network Isolated"
      echo "This container has no network access. All external requests will fail."
    else
      echo ""
      echo "## Network Access Enabled"
      echo "This container has outbound network access. The agent can make HTTP requests to external services, which could be used to exfiltrate data from mounted directories."
    fi
  } >> "$output_path"
}

# Generate sandbox awareness files for both supported agent runtimes.
write_sandbox_awareness "$claude_md_path" "Claude Code Instructions"
write_sandbox_awareness "$codex_agents_path" "Codex Instructions"

# Replace this process with the selected agent runtime in fully autonomous mode.
case "${AGENTBOX_RUNTIME:-claude}" in
  claude)
    exec claude --dangerously-skip-permissions --permission-mode plan "$@"
    ;;
  codex)
    exec codex --dangerously-bypass-approvals-and-sandbox "$@"
    ;;
  *)
    echo "Unsupported AGENTBOX_RUNTIME: ${AGENTBOX_RUNTIME:-}" >&2
    exit 1
    ;;
esac
