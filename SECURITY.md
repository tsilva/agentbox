# Security

## Isolation Model

claudebox runs Claude Code inside a Docker container with:

- `--cap-drop=ALL` — all Linux capabilities are dropped
- `--security-opt=no-new-privileges` — prevents privilege escalation
- Non-root user inside the container

### What IS isolated

- **Host filesystem**: Only explicitly mounted paths are accessible
- **Host processes**: Container cannot see or signal host processes
- **Privilege escalation**: Capabilities are dropped, no-new-privileges is set
- **Symlink aliases to blocked paths**: Working directories and extra mounts must use canonical paths; any symlink hop is rejected before the container starts

### What is NOT isolated

- **Network access**: The container has unrestricted network access by default after the project path is trusted. Claude Code can make arbitrary HTTP requests, install packages, and communicate with external services.
- **Mounted directories**: Any mounted path (working directory, extra mounts) is fully writable unless mounted read-only. With `--readonly`, claudebox-managed host mirrors are also mounted read-only.
- **Claude credentials**: Your Claude authentication tokens are mounted into trusted networked containers. Trust is stored outside the repo under `~/.claudebox/trusted-projects`, so `.claudebox.json` cannot self-authorize a project.

## `--dangerously-skip-permissions`

Claude Code runs with `--dangerously-skip-permissions`, which means:

- All tool calls are auto-approved (file edits, command execution, etc.)
- Claude can execute arbitrary shell commands inside the container
- No human-in-the-loop confirmation for any action

This is the intended behavior — the container boundary provides the isolation layer instead of permission prompts.

## Git Safety

When running from inside a git repository, the `.git` directory is automatically mounted read-only into the container. This prevents `git commit`, `git add`, and other write operations that modify the `.git` directory.

Additionally, no SSH keys or git credentials are available inside the container, so `git push` and authenticated remote operations will fail regardless.

When running from a directory that is not a git repository, a warning is displayed to inform the user that no `.git` protection is in effect.

## Per-Project Dockerfile

If a `.claudebox.Dockerfile` exists in the project root, claudebox refuses to use it unless the launch includes `--allow-project-dockerfile`. This file runs with full Docker build capabilities and constitutes an **explicit trust boundary** — it can install packages, run arbitrary commands at build time, and modify the container environment. Only use projects with `.claudebox.Dockerfile` from sources you trust. `--dry-run` skips builds.

When a project Dockerfile is allowed, claudebox forces the runtime back to UID 1000 and the host-controlled trusted entrypoint. This prevents the project image from replacing startup behavior with its own `ENTRYPOINT`, `CMD`, or `USER`.

## Project Trust

Networked launches expose Claude credentials inside the container so Claude Code can authenticate. claudebox requires explicit host-side trust before that combination is allowed:

```bash
claudebox trust
claudebox trust --list
claudebox untrust
```

`network: "none"` can run without project trust, but Claude Code will not be able to reach Anthropic services in that mode.

## Recommendations

- Avoid mounting sensitive directories (SSH keys, credentials, etc.)
- Use canonical paths directly for the working directory and extra mounts (`pwd -P` is useful here)
- Use read-only mounts where possible
- Review `.claudebox.json` profiles before use
- Run `claudebox trust` only after reviewing a project you intend to run with network access
- Use `network: "none"` for sensitive workloads that do not need outbound network access

## Reporting Vulnerabilities

Please report security vulnerabilities by opening a GitHub issue at:
https://github.com/tsilva/claudebox/issues

For sensitive issues, contact the maintainer directly via GitHub.
