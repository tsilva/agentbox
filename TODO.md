# Security TODO

- [ ] High: Block ancestor mounts that expose sensitive paths. `scripts/claudebox-template.sh` rejects exact blocked paths and descendants, but still accepts parent paths like `$HOME`, which exposes blocked children such as `~/.ssh`, `~/.aws`, `~/.claude`, and `~/.claudebox`.

- [ ] High: Validate the default working-directory mount against the same sensitive-path policy. Running `claudebox` from `$HOME` currently mounts the entire home directory without any blocklist check.

- [ ] High: Remove or explicitly gate automatic `.venv/bin/activate` sourcing in `entrypoint.sh`. A repo-controlled virtualenv activate script runs before `claude` starts, which allows untrusted projects to execute shell code at sandbox startup.

- [ ] Medium: Fix `--readonly` startup failure. The wrapper mounts sandbox `~/.claude` read-only, but `entrypoint.sh` still writes `~/.claude/CLAUDE.md`, which aborts startup before Claude launches.

- [ ] Medium: Harden installer/build provenance. `Dockerfile` still uses `curl ... | sh` for `uv`, and `scripts/install-claude-code.sh` verifies the Claude binary with a checksum fetched from the same remote origin as the binary itself.

- [ ] Low: Fix the brittle security regression test in `tests/security-regression.sh`. The tmpfs ownership assertion expects unescaped `uid=1000,gid=1000`, but dry-run output is shell-escaped and currently emits `uid=1000\,gid=1000`.
