#!/bin/bash
set -euo pipefail

# Recreate symlink on tmpfs (rootfs is read-only, ~/.local is a tmpfs)
# The binary lives at /opt/claude-code/ to avoid collision with the config
# volume mount at ~/.claude/, so we symlink it into PATH on every boot.
mkdir -p /home/claude/.local/bin
ln -sf /opt/claude-code/claude /home/claude/.local/bin/claude

# Activate any project-level Python venv so Claude can use project dependencies
if [ -f .venv/bin/activate ]; then
  echo "Activating Python virtual environment (.venv) at $PWD/.venv" >&2
  source .venv/bin/activate
fi

# Generate sandbox awareness CLAUDE.md
cat > /home/claude/.claude/CLAUDE.md << 'SANDBOX_EOF'
# Sandbox Environment (claudebox)

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

# Append dynamic context
{
  echo ""
  echo "## Current Profile Settings"
  echo "- Network mode: ${CLAUDEBOX_NETWORK_MODE:-bridge}"
  [ -n "${CLAUDEBOX_CPU_LIMIT:-}" ] && echo "- CPU limit: $CLAUDEBOX_CPU_LIMIT"
  [ -n "${CLAUDEBOX_MEMORY_LIMIT:-}" ] && echo "- Memory limit: $CLAUDEBOX_MEMORY_LIMIT"
  [ -n "${CLAUDEBOX_PIDS_LIMIT:-}" ] && echo "- Process limit: $CLAUDEBOX_PIDS_LIMIT"
  [ "${CLAUDEBOX_READONLY:-false}" = "true" ] && echo "- Workspace: **read-only** (--readonly flag)"

  if [ -n "${CLAUDEBOX_EXTRA_MOUNTS:-}" ]; then
    echo ""
    echo "## Extra Mounts"
    echo "$CLAUDEBOX_EXTRA_MOUNTS"
  fi

  if [ "${CLAUDEBOX_NETWORK_MODE:-bridge}" = "none" ]; then
    echo ""
    echo "## ⚠️ Network Isolated"
    echo "This container has no network access. All external requests will fail."
  else
    echo ""
    echo "## ⚠️ Network Access Enabled"
    echo "This container has outbound network access. Claude can make HTTP requests to external services, which could be used to exfiltrate data from mounted directories."
  fi
} >> /home/claude/.claude/CLAUDE.md

# Replace this process with Claude Code running in fully autonomous mode.
# All remaining arguments (e.g. "login", "shell") are forwarded to the binary.
exec claude --dangerously-skip-permissions --permission-mode plan "$@"
