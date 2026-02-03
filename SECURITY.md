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

### What is NOT isolated

- **Network access**: The container has unrestricted network access by default. Claude Code can make arbitrary HTTP requests, install packages, and communicate with external services.
- **Mounted directories**: Any mounted path (working directory, extra mounts) is fully writable unless mounted read-only.
- **Claude credentials**: Your Claude authentication tokens are mounted into the container.

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

If a `.claudebox.Dockerfile` exists in the project root, it is automatically built and used as the container image. This file runs with full Docker build capabilities and constitutes an **explicit trust boundary** — it can install packages, run arbitrary commands at build time, and modify the container environment. Only use projects with `.claudebox.Dockerfile` from sources you trust.

## Recommendations

- Avoid mounting sensitive directories (SSH keys, credentials, etc.)
- Use read-only mounts where possible
- Review `.claudebox.json` profiles before use
- Consider network isolation for sensitive workloads (future feature)

## Reporting Vulnerabilities

Please report security vulnerabilities by opening a GitHub issue at:
https://github.com/tsilva/claudebox/issues

For sensitive issues, contact the maintainer directly via GitHub.
