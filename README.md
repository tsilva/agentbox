<div align="center">
  <img src="./logo.png" alt="claudebox" width="512" />

  **⚡ Full autonomy. Zero blast radius. 🛡️**
</div>

claudebox runs Claude Code with `--dangerously-skip-permissions` inside an isolated Docker container. Claude gets full autonomy inside the sandbox, while sensitive host paths, git credentials, and system files stay outside its reach.

Use it from any project directory when you want Claude Code to work without permission prompts, but with Docker-backed filesystem, network, process, and mount boundaries.

## Install

Requires Docker installed and running. On macOS, Docker Desktop is the standard setup.

```bash
curl -fsSL https://raw.githubusercontent.com/tsilva/claudebox/main/install.sh | bash
```

Or install from a local checkout:

```bash
git clone https://github.com/tsilva/claudebox.git
cd claudebox
./install.sh
```

Reload your shell, or update `PATH` for the current session, then run claudebox from the project you want to sandbox:

```bash
export PATH="$HOME/.claudebox/bin:$PATH"
cd /path/to/project
claudebox trust
claudebox
```

If Claude Code is not logged in on the host, run `claude` outside the sandbox and complete `/login` first.

## Commands

```bash
claudebox                                      # start Claude Code in the sandbox
claudebox -p "explain this code"              # run a non-interactive prompt
cat README.md | claudebox -p "summarize this" # pipe input to print mode
claudebox shell                               # open a shell inside the sandbox

claudebox trust                               # trust the current canonical project path
claudebox trust --list                        # list trusted project paths
claudebox untrust                             # remove trust for the current project path

claudebox --profile dev                       # launch with a .claudebox.json profile
claudebox -P dev -p "run tests"               # combine profile and print mode
claudebox --readonly                          # mount host-backed paths read-only
claudebox --dry-run                           # print the docker run command only
claudebox --allow-project-dockerfile          # allow a reviewed .claudebox.Dockerfile
claudebox update                              # update the installed script and image

./scripts/claudebox-dev.sh build              # rebuild the local Docker image
./scripts/claudebox-dev.sh kill               # stop running claudebox containers
./scripts/lint.sh                             # run shellcheck
./tests/smoke-test.sh                         # run basic local checks
```

## Configuration

Projects can define launch profiles in `.claudebox.json`:

```json
{
  "dev": {
    "mounts": [
      { "path": "/Volumes/Data/input", "readonly": true },
      { "path": "/Volumes/Data/output" }
    ],
    "ports": [
      { "host": 3000, "container": 3000 }
    ],
    "network": "bridge",
    "audit_log": true,
    "cpu": "4",
    "memory": "8g",
    "pids_limit": 256
  }
}
```

Use `--profile <name>` or `-P <name>` to select a profile. Without a profile flag, claudebox prompts when a config file has more than one profile.

Supported profile fields include `mounts`, `ports`, `network`, `audit_log`, `cpu`, `memory`, `pids_limit`, `ulimit_nofile`, and `ulimit_fsize`.

## Notes

- `jq` is required only when `.claudebox.json` exists. If it is missing, claudebox exits instead of ignoring profile security settings.
- Project paths and extra mounts must be absolute canonical paths. Symlink hops are rejected; use `pwd -P` if needed.
- The current project is mounted at the same canonical path inside the container. The `.git` directory is mounted read-only, and host git credentials are not available.
- Sandbox Claude state lives under `~/.claudebox/`, including the installed CLI, mirrored Claude config, copied credentials, plugin mirrors, logs, seccomp profile, and trusted entrypoint.
- Host auth is the source of truth. claudebox refreshes sandbox auth from `~/.claude.json` plus `~/.claude/.credentials.json` or the macOS `Claude Code-credentials` keychain item before launch.
- A project-local `.claudebox.Dockerfile` can add dependencies, but it is used only when the launch includes `--allow-project-dockerfile`.
- `entrypoint.sh` writes a runtime `CLAUDE.md` inside the sandbox so Claude Code knows the active mounts, blocked paths, network mode, and resource limits.
- Optional desktop notifications are provided by [claude-code-notify](https://github.com/tsilva/claude-code-notify) through `host.docker.internal:19223`.
- See [SECURITY.md](SECURITY.md) for the isolation model, known boundaries, and reporting instructions.

## Architecture

![claudebox architecture diagram](./architecture.png)

## License

[MIT](LICENSE)
