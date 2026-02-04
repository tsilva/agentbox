# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claudebox is a tool that runs Claude Code with full autonomy (`--dangerously-skip-permissions`) inside an isolated Docker container.

## Directory Structure

```
claudebox/
├── Dockerfile              # OCI-compatible image definition
├── .dockerignore           # Files excluded from build context
├── entrypoint.sh           # Container entrypoint (sandbox awareness, venv activation)
├── install.sh              # One-liner curl install script
├── claudebox-dev.sh        # Dev CLI (build/install/uninstall/kill/update)
├── scripts/
│   ├── claudebox-template.sh   # Standalone script template
│   ├── install-claude-code.sh  # Claude Code installer
│   └── seccomp.json            # Syscall filtering profile
├── tests/
│   ├── smoke-test.sh           # Basic functionality tests
│   ├── isolation-test.sh       # Filesystem isolation tests
│   ├── security-regression.sh  # Security constraint tests
│   ├── validation-test.sh      # Config validation tests
│   ├── golden/                 # Expected output fixtures
│   └── lib/                    # Test utilities
├── .github/workflows/
│   └── ci.yml              # Shellcheck + Docker build CI
├── SECURITY.md
├── CLAUDE.md
└── README.md
```

## Commands

```bash
# Build/rebuild the container image
./claudebox-dev.sh build

# Install (builds image + installs script to ~/.claudebox/bin/)
./claudebox-dev.sh install

# Remove the container image
./claudebox-dev.sh uninstall

# Force stop running containers
./claudebox-dev.sh kill

# Pull latest + rebuild
./claudebox-dev.sh update
```

## Usage

After installation, the `claudebox` command accepts the following arguments:

```bash
# Run Claude Code in the sandbox (interactive mode)
claudebox

# Pass arguments to Claude (e.g., login)
claudebox login

# Non-interactive print mode: run a prompt and exit
claudebox -p "explain this code"

# Pipe input to print mode
cat file.txt | claudebox -p "summarize this"

# Drop into a bash shell to inspect the sandbox environment
claudebox shell

# Mount all host paths as read-only (workspace, config, extra mounts)
claudebox --readonly
```

## Per-Project Configuration

Projects can define named profiles via `.claudebox.json` in the project root:

```json
{
  "dev": {
    "mounts": [
      { "path": "/Volumes/Data/input", "readonly": true },
      { "path": "/Volumes/Data/output" }
    ],
    "ports": [
      { "host": 3000, "container": 3000 }
    ]
  },
  "prod": {
    "mounts": [
      { "path": "/Volumes/Data/prod", "readonly": true }
    ]
  }
}
```

**Fields:**
- Root-level keys are profile names
- `mounts[].path` (required): Absolute host path, mounted to the same path inside the container
- `mounts[].readonly` (optional): If `true`, mount is read-only (default: `false`)
- `ports[].host` (required): Host port number (1-65535)
- `ports[].container` (required): Container port number (1-65535)
- `network` (optional): Docker network mode — `"bridge"` (default) or `"none"` for full isolation
- `audit_log` (optional): If `true`, enables session audit logging to `~/.claudebox/logs/` (default: `false`)
- `cpu` (optional): CPU limit string (e.g., `"4"`) — maps to `docker --cpus`
- `memory` (optional): Memory limit string (e.g., `"8g"`) — maps to `docker --memory`
- `pids_limit` (optional): Max number of processes (e.g., `256`) — maps to `docker --pids-limit`
- `ulimit_nofile` (optional): Open file descriptors limit (e.g., `"1024:2048"`) — maps to `docker --ulimit nofile=`
- `ulimit_fsize` (optional): Max file size in bytes (e.g., `1073741824`) — maps to `docker --ulimit fsize=`

**Requirements:**
- `jq` must be installed for config parsing (`brew install jq`)
- If `jq` is missing or config is invalid, warnings are shown and extra mounts are skipped

**Path behavior:** The working directory is mounted at its actual path (e.g., `/Users/foo/project` inside and outside). This allows file paths to work identically in both environments.

**Profile selection:**
- With `--profile <name>` or `-P <name>` (uppercase): Use specified profile
- Without flag: Interactive prompt to select profile

> Note: `-P` (uppercase) is used for profiles to avoid collision with Claude's `-p` (lowercase) print mode.

**Usage:**
```bash
claudebox --profile dev      # Use specific profile
claudebox -P prod            # Short form (uppercase -P)
claudebox                    # Interactive prompt
claudebox --profile dev login  # Profile + args to Claude
claudebox -P dev -p "run tests"  # Profile + print mode
```

## Architecture

The project consists of shell scripts that wrap Docker:

- **Dockerfile** - Debian slim image with Claude Code binary installed to `/opt/claude-code/`, entry point runs `claude --dangerously-skip-permissions`
- **claudebox-dev.sh** - Self-contained dev CLI with build, install, uninstall, and kill functions
- **scripts/claudebox-template.sh** - Template for the installed standalone script

### Key Implementation Details

1. **Binary location**: Claude Code is installed to `/opt/claude-code/` (not `~/.claude/`) to avoid collision with the config volume mount at `~/.claude/`. A symlink at `~/.local/bin/claude` points to the binary to satisfy Claude Code's native install detection.

2. **Persisted state**: Two paths are mounted from the host:
   - `~/.claudebox/claude-config` → `/home/claude/.claude` (credentials, cache, settings)
   - `~/.claudebox/.claude.json` → `/home/claude/.claude.json` (session state)

3. **Environment variables** (set in Dockerfile):
   - `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` - Uses system CA certs (Claude Code's bundled certs may be incomplete)
   - `NODE_OPTIONS="--dns-result-order=ipv4first"` - Avoids IPv6 routing issues in Docker

4. **Container lifecycle**: Containers use `--rm` by default for zero overhead. Audit logging (named containers + log dump) is opt-in via `audit_log: true` in profile config.

5. **Sandbox awareness**: At container startup, `entrypoint.sh` generates `/home/claude/.claude/CLAUDE.md` with sandbox constraints and profile settings. This file is automatically loaded by Claude Code, making the AI aware of filesystem restrictions, blocked paths, network mode, resource limits, and extra mounts.

## Requirements

- [Docker Desktop](https://docs.docker.com/get-docker/) installed and running

## Notifications

Desktop notifications are provided by [claude-code-notify](https://github.com/tsilva/claude-code-notify) (separate project). When sandbox support is enabled during claude-code-notify installation, a TCP listener starts on `localhost:19223`. The container connects via `host.docker.internal`. See README.md for setup instructions.

## Documentation

README.md must be kept up to date with any significant project changes.

## Linting

When adding new shell scripts, update `scripts/lint.sh` to include them.
