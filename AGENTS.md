# AGENTS.md

This file provides repository guidance for coding agents. `CLAUDE.md` links to it.

## Project Overview

agentbox runs Claude Code (`--dangerously-skip-permissions`) or Codex (`--dangerously-bypass-approvals-and-sandbox`) with full autonomy inside an isolated Docker container. The host launcher controls filesystem grants, credentials, networking, and session cleanup.

## Directory Structure

```
agentbox/
├── Dockerfile              # Separate Claude, Codex, broker, and development targets
├── .dockerignore           # Files excluded from build context
├── entrypoint.sh           # Container entrypoint (sandbox awareness, optional relay)
├── install.sh              # Self-contained installer (dual-mode: curl pipe + local repo)
├── uninstall.sh            # Standalone uninstaller
├── style.sh                # Canonical terminal styling library for repo + installed CLI
├── scripts/
│   ├── agentbox-dev.sh        # Dev CLI (build/kill/update)
│   ├── agentbox-template.sh   # Standalone script template
│   ├── onboarding.sh          # Project init, config loading, local grant approval
│   ├── launch-common.sh       # Launch state, preferences, staging, broker lifecycle
│   ├── render-cli.sh          # Embed launch and onboarding modules into the standalone CLI
│   ├── workspace.py           # Optional staged editing and conflict-checked apply
│   ├── install-agent-clis.sh  # Selected-runtime installer with checksum verification
│   ├── repo-common.sh          # Shared host-side helpers for repo scripts
│   └── seccomp.json            # Syscall filtering profile
├── tests/
│   ├── smoke-test.sh           # Basic functionality tests
│   ├── isolation-test.sh       # Filesystem isolation tests
│   ├── security-regression.sh  # Security constraint tests
│   ├── validation-test.sh      # Config validation tests
│   ├── launcher-test.py        # Installed-launcher behavior with controlled adapters
│   ├── launcher-docker-test.sh # Actual launcher and broker isolation checks
│   ├── provider-protocol-test.py # Native client API compatibility without providers
│   ├── version-check-test.sh   # Runtime-specific update warnings
│   ├── golden/                 # Expected output fixtures
│   └── lib/                    # Test utilities
├── broker/                 # Standard-library Go credential broker and local relay
├── requirements.txt        # Optional pinned Python tools, references constraints.txt
├── constraints.txt         # Python transitive version constraints
├── .github/workflows/
│   ├── ci.yml              # Lint, behavioral tests, Docker isolation, broker race tests
│   └── release-images.yml  # Manual verified multi-platform image publication
├── SECURITY.md
├── CLAUDE.md
└── README.md
```

## Commands

```bash
# Install selected runtime (verified prebuilt preferred, local build if no release)
./install.sh --runtime claude
./install.sh --runtime codex --build
# Optional Python tooling: --python; require verified images: --prebuilt

# Uninstall (removes image, scripts, PATH entry)
./uninstall.sh

# Build/rebuild the container image (dev convenience)
./scripts/agentbox-dev.sh build

# Force stop running containers
./scripts/agentbox-dev.sh kill

# Pull latest + rebuild
./scripts/agentbox-dev.sh update
```

## Usage

After installation, the `agentbox` command accepts the following arguments:

```bash
# Run Claude Code in the sandbox (interactive mode)
agentbox

# Configure the repository and approve its access plan
agentbox init

# Save a global runtime preference and inspect effective grants
agentbox setup --codex
agentbox doctor
agentbox inspect

# Read-only review, explicit edit, or offline shell without authentication
agentbox review
agentbox edit
agentbox offline shell

# API-key-only provider access, with the key held outside the agent container
agentbox --codex --broker -p "explain this code"

# Opt into a reviewed private workspace; apply after reviewing the printed path
agentbox --codex --staged -p "refactor this module"
agentbox apply session.<id>

# Claude plugins are explicit versioned snapshots mounted read-only
agentbox plugins refresh
agentbox --claude --plugins

# Update the selected runtime independently
agentbox --claude update
agentbox --codex update

# Non-interactive print mode: run a prompt and exit
agentbox -p "explain this code"

# Pipe input to print mode
cat file.txt | agentbox -p "summarize this"

# Drop into a bash shell to inspect the sandbox environment
agentbox shell

# Trust the current project for networked runtime access
agentbox trust
agentbox trust --list
agentbox untrust

# Mount all host paths as read-only (workspace, config, extra mounts)
agentbox --readonly

# Allow a reviewed repo-controlled project Dockerfile for this launch
agentbox --allow-project-dockerfile
```

## Per-Project Configuration

`agentbox init` creates `.agentbox.json` at the Git checkout root (current directory outside Git). Launches from subdirectories use that root. Versioned configuration:

```json
{
  "version": 1,
  "runtime": "codex",
  "default_profile": "dev",
  "profiles": {
    "dev": {
      "mode": "edit",
      "access": "direct",
      "mounts": [{ "path": "/Volumes/Data/input", "readonly": true }],
      "ports": [{ "host": 3000, "container": 3000 }],
      "network": "bridge",
      "cpu": "4",
      "memory": "8g",
      "pids_limit": 256
    }
  }
}
```

Root fields: `version` (must be `1`), `runtime` (`claude`/`codex`), `default_profile` (existing profile name), and `profiles` (nonempty object). Unknown fields fail closed. Legacy root-level profile maps remain supported and are migrated by `init` without discarding other profiles.

Profile fields:

- `mode`: `edit` (default), `review`, or `offline`
- `access`: `direct` (default) or `broker`; broker requires API-key auth and API billing
- `mounts[].path`: absolute canonical host path, mounted at the same path; optional boolean `readonly` defaults to false
- `ports[].host` and `ports[].container`: integers from 1 to 65535, bound to host localhost
- `network`: `bridge` (default) or `none`; offline mode disables network/auth regardless
- `audit_log`: boolean (default false)
- `cpu`: positive numeric string, for example `"4"`
- `memory`: positive string, for example `"8g"`
- `pids_limit`: positive integer (default 256)
- `ulimit_nofile`: string `"soft:hard"` or `"value"`
- `ulimit_fsize`: nonnegative integer in bytes

CLI flags override project defaults, which override the global runtime preference. `--direct` overrides a saved broker access mode. `--readonly` always restricts mounts. `init` requires a terminal, validates the launch plan before writing, asks for explicit local approval, and reads authentication only after approval. It does not build project images or install runtimes. A bare launch without config suggests `init`.

Credentials and approvals never go into project config. Versioned launches require local project identity and effective-grant approval, including offline launches. Cloned configs and changed grants prompt only in interactive launch mode; unattended launches fail closed. `agentbox trust` prints and approves the validated plan. `untrust` removes identity and grant records. Preview commands do not prompt or create state.

**Requirements:**
- `jq` must be installed for config parsing (`brew install jq`)
- If `.agentbox.json` exists and `jq` is missing, agentbox exits instead of skipping profile security settings
- If config is invalid, agentbox exits with an error
- Unknown fields and invalid field types are rejected before authentication is prepared

**Path behavior:** The working directory is mounted at its canonical path (e.g., `/Users/foo/project` inside and outside). Any symlink hop in the working directory or an extra mount source is rejected, so use canonical paths directly. Sensitive host paths, hidden direct children under `$HOME`, and parent paths that would expose them are blocked.

**Profile selection:**
- With `--profile <name>` or `-P <name>` (uppercase): Use specified profile
- Without flag: Use saved `default_profile`; legacy files select one profile or prompt interactively for multiple profiles

> Note: `-P` (uppercase) is used for profiles to avoid collision with Claude's `-p` (lowercase) print mode.

**Usage:**
```bash
agentbox --profile dev      # Use specific profile
agentbox -P prod            # Short form (uppercase -P)
agentbox                    # Saved runtime and default profile
agentbox -P dev -p "run tests"  # Profile + print mode
```

## Architecture

The project uses shell scripts to wrap Docker, an optional Python workspace helper, and a Go credential broker:

- **Dockerfile** - Pinned Debian base, minimal single-runtime targets, optional Python tools, separate broker target, and a development target containing both agents
- **scripts/agentbox-dev.sh** - Dev CLI with build, kill, and update commands (delegates install/uninstall)
- **scripts/agentbox-template.sh** - Template for the installed standalone script
- **scripts/launch-common.sh** and **scripts/render-cli.sh** - Shared launch behavior embedded into the installed script
- **scripts/workspace.py** - Staged file copying and conflict-checked host application; Python standard library only
- **broker/** - API-key broker and loopback relay; Go standard library only
- **style.sh** - Single source of truth for terminal styling used by repo scripts and copied into the installed CLI
- **scripts/repo-common.sh** - Shared host-side helper functions used by repo-only install/dev flows

### Key Implementation Details

1. **Binary locations**: Claude Code is installed to `/opt/claude-code/` and Codex to `/opt/codex/`, outside mounted config directories. Codex releases with a separate Code Mode host install that matching checksum-verified companion beside the CLI; pinned builds require `AGENTBOX_CODEX_CODE_MODE_SHA256` when it exists. Entrypoint recreates symlinks under `~/.local/bin/` for binaries present in the selected image. The image home directory must be traversable by the invoking host UID, which can differ from the image user.

2. **Private session state**: Each launch owns `~/.agentbox/sessions/session.<id>/`. Only the selected runtime's auth/config is copied after trust and validation. Offline/broker modes use authless state. Inactive runtime state is empty. Normal exit and handled interrupts remove transient state; staged workspaces and baselines remain for review/apply. Conversation history is ephemeral. Host preferences, image references, trust records, optional audit logs, and versioned plugin snapshots persist outside sessions.

3. **Environment variables** (set in Dockerfile):
   - `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` - Uses system CA certs (Claude Code's bundled certs may be incomplete)
   - `NODE_OPTIONS="--dns-result-order=ipv4first"` - Avoids IPv6 routing issues in Docker

4. **Container lifecycle**: Containers are named and labelled `agentbox.managed=true`, normally use `--rm`, and are cleaned up by the host wrapper. Audit logging (retained container until log dump) is opt-in via `audit_log: true`. Broker mode creates a separate limited container and a Docker-managed tmpfs socket volume; the agent mounts the socket volume read-only and has `--network none`. The broker owns the provider key and permits only fixed provider HTTPS routes. Failure never grants direct networking or raw keys.

5. **Sandbox awareness**: `entrypoint.sh` writes `/home/claude/.claude/CLAUDE.md` and `/home/claude/.codex/AGENTS.md` through tmpfs-backed runtime paths, including current filesystem, network, resource, and mount restrictions. Repo-managed virtualenv activation scripts are never sourced automatically.

6. **Staged edits**: Launch from the Git root with host Python 3. Copy tracked/unignored regular files except `.git`, `.env*`, `.pem`, `.key`, and symlinks. Extra host mounts are forbidden. Apply validates checkout identity and changed-file baselines, rejects protected paths/symlinks, and writes through directory handles. Application is per-file and can be partial on I/O failure; it never commits.

## Requirements

- [Docker Desktop](https://docs.docker.com/get-docker/) installed and running
- Git, curl, and Perl on the host; jq for profiles and prebuilt verification; Cosign for prebuilt verification
- Host Python 3 only for staged editing; container Python tools are opt-in

## Documentation

Keep README.md, SECURITY.md, and these architecture/command references aligned with significant behavior changes.

## Linting

When adding new shell scripts, update `scripts/lint.sh` to include them.
The lint script checks the rendered standalone CLI so embedded template/module references resolve together. Launcher unit tests require only host Python, jq, and normal shell tools; Docker isolation tests require a running daemon and development/broker images. Run `go test -race ./...` in `broker/` for broker changes.
