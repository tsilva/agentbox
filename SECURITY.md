# Security

## Isolation Model

agentbox runs Claude Code inside a Docker container with:

- `--cap-drop=ALL` — all Linux capabilities are dropped
- `--security-opt=no-new-privileges` — prevents privilege escalation
- A custom seccomp profile that blocks namespace creation, io_uring, device-node creation, identity-changing syscalls, and kernel log access
- Non-root user inside the container

### What IS isolated

- **Host filesystem**: Only explicitly mounted paths are accessible
- **Host processes**: Container cannot see or signal host processes
- **Privilege escalation**: Capabilities are dropped, no-new-privileges is set
- **Symlink aliases to blocked paths**: Working directories and extra mounts must use canonical paths; any symlink hop is rejected before the container starts

### What is NOT isolated

- **Network access**: The container has unrestricted network access by default after the project path is trusted. Claude Code can make arbitrary HTTP requests, install packages, and communicate with external services.
- **Mounted directories**: Any mounted path (working directory, extra mounts) is fully writable unless mounted read-only. With `--readonly`, agentbox-managed host mirrors are also mounted read-only.
- **Selected runtime credentials**: Your selected Claude or Codex authentication state is mounted into trusted networked containers. The inactive runtime receives empty sandbox state. Trust is stored outside the repo under `~/.agentbox/trusted-projects`, so `.agentbox.json` cannot self-authorize a project.
- **Image build inputs**: The base image and bundled agent CLIs are fetched during image build. Downloads are protected by TLS and release checksums, but the build intentionally tracks upstream releases instead of being fully reproducible from checked-in digests.

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

If a `.agentbox.Dockerfile` exists in the project root, agentbox refuses to use it unless the launch includes `--allow-project-dockerfile`. This file runs with full Docker build capabilities and constitutes an **explicit trust boundary** — it can install packages, run arbitrary commands at build time, and modify the container environment. Only use projects with `.agentbox.Dockerfile` from sources you trust. `--dry-run` skips builds.

When a project Dockerfile is allowed, agentbox forces the runtime back to UID 1000 and the host-controlled trusted entrypoint. This prevents the project image from replacing startup behavior with its own `ENTRYPOINT`, `CMD`, or `USER`, but it does **not** make the project image untrusted code: the image can still replace shells, shared libraries, installed agent binaries, and other runtime components. Treat `--allow-project-dockerfile` as full runtime trust, especially for networked launches that expose agent credentials.

## Project Trust

Networked launches expose the selected runtime's credentials inside the container so Claude Code or Codex can authenticate. agentbox requires explicit host-side trust before that combination is allowed:

```bash
agentbox trust
agentbox trust --list
agentbox untrust
```

`network: "none"` can run without project trust. In that untrusted offline mode, agentbox uses a freshly reset authless runtime state instead of mounting mirrored Claude/Codex credentials or plugin state. Claude Code will not be able to reach Anthropic services in that mode.

## Recommendations

- Avoid mounting sensitive directories (SSH keys, credentials, etc.)
- Use canonical paths directly for the working directory and extra mounts (`pwd -P` is useful here)
- Use read-only mounts where possible
- Review `.agentbox.json` profiles before use
- Run `agentbox trust` only after reviewing a project you intend to run with network access
- Use `network: "none"` for sensitive workloads that do not need outbound network access

## Reporting Vulnerabilities

Please report security vulnerabilities by opening a GitHub issue at:
https://github.com/tsilva/agentbox/issues

For sensitive issues, contact the maintainer directly via GitHub.
