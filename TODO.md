# Security TODO

- [x] High: Block ancestor mounts that expose sensitive paths. `scripts/claudebox-template.sh` now rejects exact blocked paths, descendants, and ancestor paths like `$HOME` or `~/.config` that would expose blocked children such as `~/.ssh`, `~/.aws`, `~/.claude`, and `~/.claudebox`.

- [ ] High: Validate the default working-directory mount against the same sensitive-path policy. Running `claudebox` from `$HOME` still mounts the entire home directory without any blocklist check.

- [x] High: Remove or explicitly gate automatic `.venv/bin/activate` sourcing in `entrypoint.sh`. `entrypoint.sh` now avoids auto-sourcing repo-controlled activation scripts before Claude starts.

- [x] Medium: Fix `--readonly` startup failure. The wrapper now bind-mounts `~/.claude/CLAUDE.md` to a dedicated runtime file so `entrypoint.sh` can write sandbox context even when sandbox `~/.claude` is read-only.

- [ ] Medium: Harden installer/build provenance. `Dockerfile` still uses `curl ... | sh` for `uv`, and `scripts/install-claude-code.sh` still verifies the Claude binary with a checksum fetched from the same remote origin as the binary itself.

- [x] Low: Fix the brittle security regression test in `tests/security-regression.sh`. The tmpfs ownership assertion now accepts both escaped and unescaped `uid=1000,gid=1000` dry-run output.
