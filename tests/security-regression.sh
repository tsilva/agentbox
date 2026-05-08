#!/bin/bash
# =============================================================================
# security-regression.sh - Critical security flag verification
#
# These tests ensure security-critical flags are ALWAYS present in the
# docker run command. Regression of any of these flags could expose
# the host system to container escape or privilege escalation.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

echo "=== Security Regression Tests ==="
echo ""

# These tests use the template directly with --dry-run to inspect the generated command
TEMPLATE="$REPO_ROOT/scripts/agentbox-template.sh"

# Create a processed version of the template with placeholders replaced
PROCESSED_TEMPLATE=$(mktemp)
sed 's|PLACEHOLDER_IMAGE_NAME|agentbox|g' \
    "$TEMPLATE" > "$PROCESSED_TEMPLATE"
chmod +x "$PROCESSED_TEMPLATE"

FAKE_HOMES=()
LAST_FAKE_HOME=""
REAL_DOCKER_HOST="${DOCKER_HOST:-}"

setup_fake_home() {
  LAST_FAKE_HOME=$(mktemp -d)
  FAKE_HOMES+=("$LAST_FAKE_HOME")
  mkdir -p "$LAST_FAKE_HOME/.agentbox"
  cp "$REPO_ROOT/scripts/seccomp.json" "$LAST_FAKE_HOME/.agentbox/seccomp.json"
  cp "$REPO_ROOT/entrypoint.sh" "$LAST_FAKE_HOME/.agentbox/entrypoint.sh"
  chmod +x "$LAST_FAKE_HOME/.agentbox/entrypoint.sh"
}

# Cleanup on exit
cleanup() {
  rm -f "$PROCESSED_TEMPLATE" 2>/dev/null || true
  if [ "${#FAKE_HOMES[@]}" -gt 0 ]; then
    for fake_home in "${FAKE_HOMES[@]}"; do
      rm -rf "$fake_home" 2>/dev/null || true
    done
  fi
  teardown_test_dir 2>/dev/null || true
}
trap cleanup EXIT

# Ensure the seccomp profile is installed for all tests
mkdir -p ~/.agentbox
cp "$REPO_ROOT/scripts/seccomp.json" ~/.agentbox/seccomp.json
cp "$REPO_ROOT/entrypoint.sh" ~/.agentbox/entrypoint.sh
chmod +x ~/.agentbox/entrypoint.sh

# --- Test: Critical security flags are present ---
echo "--- Critical Security Flags ---"

setup_test_dir

# Run dry-run to get the docker command
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)

# Test: --cap-drop=ALL (drop all Linux capabilities)
assert_contains "$output" "--cap-drop=ALL" "cap-drop=ALL present"

# Test: --security-opt=no-new-privileges (prevent setuid escalation)
assert_contains "$output" "--security-opt=no-new-privileges" "no-new-privileges present"

# Test: --read-only (read-only root filesystem)
assert_contains "$output" "--read-only" "read-only rootfs present"

# Test: tmpfs mounts have nosuid flag
assert_contains "$output" "nosuid" "tmpfs has nosuid flag"

# Test: tmpfs mounts have proper ownership (printf %q may escape commas)
assert_matches "$output" "uid=1000(\\\\,|,)gid=1000" "tmpfs has correct ownership"

teardown_test_dir

# --- Test: Seccomp profile is applied ---
echo ""
echo "--- Seccomp Profile ---"

setup_test_dir

output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
assert_matches "$output" "--security-opt seccomp=" "seccomp profile specified"

if command -v jq &>/dev/null; then
  unconditional_seccomp_allows=$(jq -r '.syscalls[] | select(.action == "SCMP_ACT_ALLOW" and ((.args // []) | length == 0)) | .names[]' "$REPO_ROOT/scripts/seccomp.json")
  all_seccomp_allows=$(jq -r '.syscalls[] | select(.action == "SCMP_ACT_ALLOW") | .names[]' "$REPO_ROOT/scripts/seccomp.json")
  clone_rule=$(jq -c '.syscalls[] | select((.names // []) | index("clone"))' "$REPO_ROOT/scripts/seccomp.json")

  assert_not_contains "$all_seccomp_allows" "clone3" "clone3 is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "mknod" "mknod is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "mknodat" "mknodat is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "setuid" "setuid is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "setgid" "setgid is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "setgroups" "setgroups is blocked by seccomp"
  assert_not_contains "$all_seccomp_allows" "syslog" "syslog is blocked by seccomp"
  assert_not_contains "$unconditional_seccomp_allows" "clone" "clone is not unconditionally allowed"
  assert_contains "$clone_rule" "SCMP_CMP_MASKED_EQ" "clone has namespace mask"
  assert_contains "$clone_rule" "2114060288" "clone namespace mask covers CLONE_NEW flags"
else
  skip "jq not installed, skipping seccomp JSON assertions"
fi

teardown_test_dir

# --- Test: Git directory is always read-only ---
echo ""
echo "--- Git Protection ---"

setup_test_dir

# Create a git repo
git init -q
echo "test" > file.txt
git add file.txt
git commit -m "initial" -q

output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)

# The .git directory should be mounted read-only
assert_matches "$output" "\.git[^:]*:ro" ".git mounted read-only"

teardown_test_dir

# --- Test: Localhost-only port binding ---
echo ""
echo "--- Port Binding Security ---"

require_jq

setup_test_dir
git init -q

# Create a config with ports
cat > .agentbox.json << 'EOF'
{
  "dev": {
    "ports": [
      {"host": 8080, "container": 8080},
      {"host": 3000, "container": 3000}
    ]
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)

# Ports MUST bind to 127.0.0.1 only
assert_contains "$output" "127.0.0.1:8080:8080" "port 8080 binds to localhost"
assert_contains "$output" "127.0.0.1:3000:3000" "port 3000 binds to localhost"

# Ensure we're NOT binding to 0.0.0.0 (all interfaces)
assert_not_contains "$output" "0.0.0.0:" "no 0.0.0.0 binding"

teardown_test_dir

# --- Test: Network mode restrictions ---
echo ""
echo "--- Network Mode Restrictions ---"

setup_test_dir
git init -q

# Test that "host" network mode is rejected (would bypass network isolation)
cat > .agentbox.json << 'EOF'
{
  "dev": {
    "network": "host"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "host network rejected"

# Test that only bridge and none are allowed
cat > .agentbox.json << 'EOF'
{
  "dev": {
    "network": "bridge"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
# Should not error for bridge
assert_not_contains "$output" "Unsupported network mode" "bridge network allowed"

cat > .agentbox.json << 'EOF'
{
  "dev": {
    "network": "none"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "--network none" "none network allowed"

teardown_test_dir

# --- Test: Non-root user in container ---
echo ""
echo "--- Non-Root User ---"

require_docker
require_image

# Verify the container runs as UID 1000 (non-root)
uid=$(docker run --rm --entrypoint /bin/bash agentbox -c "id -u")
assert_equals "$uid" "1000" "container runs as UID 1000"

# Verify the user is not root
username=$(docker run --rm --entrypoint /bin/bash agentbox -c "whoami")
assert_not_contains "$username" "root" "container user is not root"

# --- Test: Repo-controlled virtualenv activation is not auto-sourced ---
echo ""
echo "--- Startup Script Safety ---"

setup_test_dir

mkdir -p .venv/bin
cat > .venv/bin/activate <<'EOF'
#!/bin/bash
echo "MALICIOUS_VENV_ACTIVATE_RAN" >&2
touch "$PWD/.venv-activate-executed"
EOF
chmod +x .venv/bin/activate

output=$(docker run --rm \
  -v "$PWD":"$PWD" \
  -w "$PWD" \
  agentbox --version 2>&1 || true)

assert_not_contains "$output" "MALICIOUS_VENV_ACTIVATE_RAN" "repo activate script output is absent"

if [ -e .venv-activate-executed ]; then
  fail "repo activate script was executed"
else
  pass "repo activate script is not auto-sourced"
fi

teardown_test_dir

# --- Test: Read-only mode adds protection ---
echo ""
echo "--- Read-Only Mode ---"

setup_test_dir
git init -q

# Test that --readonly flag adds :ro suffix to mounts
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --readonly 2>&1)

# The working directory should have :ro suffix in readonly mode
assert_matches "$output" "$(pwd):[^:]*:ro" "workdir is read-only in readonly mode"
assert_contains "$output" "$HOME/.agentbox/claude-config:/home/claude/.claude:ro" "sandbox Claude config is read-only in readonly mode"
assert_contains "$output" "$HOME/.agentbox/claude-dotconfig:/home/claude/.config:ro" "sandbox dotconfig is read-only in readonly mode"
assert_contains "$output" "$HOME/.agentbox/.claude.json:/home/claude/.claude.json:ro" "sandbox state is read-only in readonly mode"
assert_contains "$output" "$HOME/.agentbox/plugins:/home/claude/.claude/plugins:ro" "sandbox plugins are read-only in readonly mode"

require_docker
require_image
if [ -z "$REAL_DOCKER_HOST" ]; then
  REAL_DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
fi
setup_fake_home

mkdir -p "$LAST_FAKE_HOME/.claude/plugins/cache/example-market/example-plugin"
mkdir -p "$LAST_FAKE_HOME/.claude"
cat > "$LAST_FAKE_HOME/.claude.json" << 'EOF'
{"persisted":false}
EOF
cat > "$LAST_FAKE_HOME/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF
printf '%s\n' 'host-plugin' > "$LAST_FAKE_HOME/.claude/plugins/cache/example-market/example-plugin/plugin.js"

cat > .agentbox.json << 'EOF'
{"safe":{"network":"none"}}
EOF

cat > .agentbox.Dockerfile << 'EOF'
FROM agentbox
USER root
RUN cat <<'SCRIPT' > /opt/claude-code/claude
#!/bin/bash
set -euo pipefail
grep -q "Sandbox Environment (agentbox)" /home/claude/.claude/CLAUDE.md
if (printf '%s\n' '{"persisted":true}' > /home/claude/.claude.json) 2>/tmp/state.err; then
  echo "sandbox state unexpectedly writable" >&2
  exit 1
fi
if (printf '%s\n' 'mutated-plugin' > /home/claude/.claude/plugins/cache/example-market/example-plugin/plugin.js) 2>/tmp/plugin.err; then
  echo "sandbox plugins unexpectedly writable" >&2
  exit 1
fi
grep -Eq 'Read-only file system|Permission denied' /tmp/state.err
grep -Eq 'Read-only file system|Permission denied' /tmp/plugin.err
printf '%s\n' "stub claude ran"
SCRIPT
RUN chmod 755 /opt/claude-code/claude && chown claude:claude /opt/claude-code/claude
USER claude
EOF

readonly_exit=0
if output=$(HOME="$LAST_FAKE_HOME" DOCKER_HOST="$REAL_DOCKER_HOST" "$PROCESSED_TEMPLATE" --claude --allow-project-dockerfile --readonly -p "self-check" 2>&1); then
  readonly_exit=0
else
  readonly_exit=$?
fi
assert_equals "$readonly_exit" "0" "readonly startup exits successfully"
assert_contains "$output" "stub claude ran" "readonly startup reaches Claude"
assert_equals "$(tr -d '\n' < "$LAST_FAKE_HOME/.agentbox/.claude.json")" '{"persisted":false}' "readonly keeps sandbox state unchanged"
assert_equals "$(tr -d '\n' < "$LAST_FAKE_HOME/.agentbox/plugins/cache/example-market/example-plugin/plugin.js")" 'host-plugin' "readonly keeps sandbox plugins unchanged"

teardown_test_dir

# --- Test: Project Dockerfile opt-in ---
echo ""
echo "--- Project Dockerfile Opt-In ---"

setup_test_dir
git init -q

cat > .agentbox.Dockerfile << 'EOF'
FROM agentbox
RUN echo "SHOULD_NOT_BUILD" >&2
RUN exit 99
EOF

dry_run_exit=0
if output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1); then
  dry_run_exit=0
else
  dry_run_exit=$?
fi
if [ "$dry_run_exit" -ne 0 ]; then
  pass "project Dockerfile without opt-in fails"
else
  fail "project Dockerfile without opt-in should fail"
fi
assert_contains "$output" "Refusing to build repo-controlled .agentbox.Dockerfile" "project Dockerfile requires opt-in"
assert_not_contains "$output" "Building per-project image" "dry-run does not build project image"

dry_run_exit=0
if output=$("$PROCESSED_TEMPLATE" --claude --allow-project-dockerfile --dry-run 2>&1); then
  dry_run_exit=0
else
  dry_run_exit=$?
fi
assert_equals "$dry_run_exit" "0" "dry-run with project Dockerfile opt-in exits successfully"
assert_contains "$output" "Per-project image build allowed by --allow-project-dockerfile" "dry-run reports explicit project image opt-in"
assert_contains "$output" "--user 1000:1000" "project image runs as UID 1000"
assert_contains "$output" "--entrypoint /bin/bash" "project image uses bash entrypoint"
assert_contains "$output" "/home/claude/entrypoint.sh" "project image runs trusted entrypoint"
assert_contains "$output" "agentbox-project" "dry-run references project image after opt-in"

teardown_test_dir

# --- Test: Project image runtime contract ---
echo ""
echo "--- Project Image Runtime Contract ---"

require_docker
require_image

setup_test_dir
setup_fake_home

mkdir -p "$LAST_FAKE_HOME/.claude"
cat > "$LAST_FAKE_HOME/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF
cat > .agentbox.json << 'EOF'
{"offline":{"network":"none"}}
EOF
cat > .agentbox.Dockerfile << 'EOF'
FROM agentbox
USER root
RUN cat <<'SCRIPT' > /opt/claude-code/claude
#!/bin/bash
set -euo pipefail
printf 'trusted entrypoint reached\n'
printf 'uid=%s\n' "$(id -u)"
SCRIPT
RUN chmod 755 /opt/claude-code/claude && chown claude:claude /opt/claude-code/claude
RUN cat <<'SCRIPT' > /evil-entrypoint
#!/bin/bash
echo "MALICIOUS_ENTRYPOINT_RAN"
SCRIPT
RUN chmod 755 /evil-entrypoint
USER root
ENTRYPOINT ["/evil-entrypoint"]
EOF

runtime_exit=0
if output=$(HOME="$LAST_FAKE_HOME" DOCKER_HOST="$REAL_DOCKER_HOST" "$PROCESSED_TEMPLATE" --claude --allow-project-dockerfile -p "runtime-contract" 2>&1); then
  runtime_exit=0
else
  runtime_exit=$?
fi
assert_equals "$runtime_exit" "0" "project runtime contract exits successfully"
assert_contains "$output" "trusted entrypoint reached" "trusted entrypoint overrides project entrypoint"
assert_contains "$output" "uid=1000" "project image forced to UID 1000"
assert_not_contains "$output" "MALICIOUS_ENTRYPOINT_RAN" "project entrypoint is not executed"

teardown_test_dir

# --- Test: io_uring is blocked by seccomp ---
echo ""
echo "--- io_uring Seccomp ---"

io_uring_result=$(docker run --rm \
  --security-opt "seccomp=$REPO_ROOT/scripts/seccomp.json" \
  --entrypoint python3 agentbox -c 'import ctypes, os; libc=ctypes.CDLL(None, use_errno=True); rc=libc.syscall(425, 1, 0); print("errno=%s" % ctypes.get_errno() if rc == -1 else "allowed")' 2>&1 || true)
assert_contains "$io_uring_result" "errno=1" "io_uring_setup blocked with EPERM"

# --- Summary ---
summary
