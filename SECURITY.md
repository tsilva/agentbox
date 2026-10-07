# Security

## Isolation Model

agentbox runs Claude Code or Codex inside a Docker container with:

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
- **Mounted directories**: Any mounted path (working directory, extra mounts) is fully writable unless mounted read-only. With `review` or `--readonly`, private session state is also mounted read-only.
- **Selected runtime credentials**: In direct mode, selected Claude or Codex authentication is copied into a private per-session directory and mounted into trusted networked containers. The inactive runtime receives empty sandbox state. Trust is stored outside the repo under `~/.agentbox/trusted-projects`, and records include project path, filesystem identity, git identity, remote URL, and agentbox config digests so `.agentbox.json` cannot self-authorize or silently replace a trusted project.
- **Image build inputs**: The base and build-tool images are pinned by digest. Local builds track upstream agent releases unless explicit versions/hashes are supplied. Signed prebuilt images are verified against the release workflow identity and installed by digest. Downloads, including a matching Codex Code Mode host when present, are protected by TLS and release checksums. For pinned base and agent inputs, run `./install.sh --locked` with `AGENTBOX_BASE_IMAGE` including an `@sha256:` digest plus explicit Claude/Codex versions and SHA-256 hashes, including `AGENTBOX_CODEX_CODE_MODE_SHA256` for releases with that companion.

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

When a project Dockerfile is allowed, agentbox forces the runtime back to the invoking host UID/GID and the host-controlled trusted entrypoint. This prevents the project image from replacing startup behavior with its own `ENTRYPOINT`, `CMD`, or `USER`, but it does **not** make the project image untrusted code: the image can still replace shells, shared libraries, installed agent binaries, and other runtime components. Treat `--allow-project-dockerfile` as full runtime trust, especially for networked launches that expose agent credentials.

## Project Trust

Networked launches expose the selected runtime's credentials inside the container so Claude Code or Codex can authenticate. agentbox requires explicit host-side trust before that combination is allowed:

```bash
agentbox trust
agentbox trust --list
agentbox untrust
```

`network: "none"` can run without project trust. Every offline launch, trusted or untrusted, uses private authless runtime state and no host plugins. Claude Code will not be able to reach Anthropic services in that mode.

Trust records fail closed when project identity changes. Re-run `agentbox trust` after intentionally replacing the checkout, moving `.git`, changing the remote URL, or changing `.agentbox.json` / `.agentbox.Dockerfile`.

## Credential Broker

`--broker` requires `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` for the selected runtime. It does not support subscription OAuth and can change billing to API usage. The agent runs with `--network none` and has no provider credentials or broker-private files. A loopback relay uses a read-only Unix-socket mount to reach a separate non-root broker; that broker has no project mount and is limited to 128 MiB, one CPU, and 64 processes.

The broker accepts a per-session capability and only `POST /v1/responses` for Codex or `POST /v1/messages` / `POST /v1/messages/count_tokens` for Claude. Claude routes also accept the native client's fixed `?beta=true` query. It fixes the HTTPS upstream hostname, discards caller credentials and arbitrary headers, refuses CONNECT, other query strings, alternate routes and redirects, caps bodies at 8 MiB, permits four concurrent requests, and caps a session at 2,000 requests. Requests have a 30-minute deadline. Bodies and keys are not logged. API keys are supplied through a private file, not Docker arguments or environment metadata. The main container's ephemeral capability appears in its environment but is not a reusable provider credential; removing the broker revokes it.

There is no fallback to raw keys or direct networking if the broker fails. Broker and relay code remain trusted software. A compromised agent can still send permitted workspace data to the provider or consume API usage within the session limits; those limits are not a monetary/token budget. Provider responses remain untrusted application data.

## State And Extensions

Transient runtime state is private to each launch and removed on normal exit or handled interrupts. Cleanup retries transient filesystem errors; persistent state-removal failure reports the private path and returns a nonzero status. Broker sockets use a private Docker-managed tmpfs volume, mounted read-only in the agent. Hard process termination or host crashes can leave private state, including credentials, under `~/.agentbox/sessions/`, managed containers, and socket volumes; remove abandoned resources when no session uses them. Audit logs are private but may contain agent output and secrets. Plugins require explicit refresh and opt-in and are mounted read-only; plugin execution retains the session's authority.

`--dry-run` and `inspect` validate the launch plan without reading auth, accessing Keychain, creating state, or building project images. Invalid profile types, unknown fields, invalid ports, unsafe/missing mounts and invalid resource limits fail before credential preparation.

## Staged Editing

`--staged` exposes a private copy of tracked and unignored regular files. It excludes `.git`, `.env*`, `.pem`, `.key`, and symlinks; other secret-bearing files can still be present. It cannot use extra host mounts. `agentbox apply <session>` checks original checkout identity and every changed source file before writing, rejects symlinks/protected paths, and uses directory handles to avoid following replaced parent symlinks. Apply is not a transaction across files: an I/O failure or concurrent source mutation during apply requires reviewing the partially applied result. A reviewed custom project Dockerfile still has full build/runtime trust and uses the original build context.

## Validation

The launcher tests use controlled auth/Docker adapters to check session ownership, offline credentials, inspection, verification failures, and staging. `tests/launcher-docker-test.sh` exercises the actual launcher for capability/identity/filesystem restrictions, absence of provider keys, direct IPv4/IPv6/DNS denial, and broker route rejection. The broker has standard-library tests with race detection. No test suite establishes immunity to container-runtime or kernel vulnerabilities.

## Recommendations

- Avoid mounting sensitive directories (SSH keys, credentials, etc.)
- Use absolute canonical paths directly for the working directory and extra mounts (`pwd -P` is useful here)
- Use read-only mounts where possible
- Review `.agentbox.json` profiles before use
- Run `agentbox trust` only after reviewing a project you intend to run with network access
- Use `network: "none"` for sensitive workloads that do not need outbound network access

## Reporting Vulnerabilities

Please report security vulnerabilities by opening a GitHub issue at:
https://github.com/tsilva/agentbox/issues

For sensitive issues, contact the maintainer directly via GitHub.
