#!/bin/bash
# =============================================================================
# validation-test.sh - Input sanitization and validation tests
#
# These tests verify that malicious or malformed configuration inputs are
# properly rejected to prevent injection attacks and unexpected behavior.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

echo "=== Input Validation Tests ==="
echo ""

require_jq

# Use the template directly with --dry-run
TEMPLATE="$REPO_ROOT/scripts/agentbox-template.sh"

# Create a processed version of the template
PROCESSED_TEMPLATE=$(mktemp)
sed 's|PLACEHOLDER_IMAGE_NAME|agentbox|g' \
    "$TEMPLATE" > "$PROCESSED_TEMPLATE"
chmod +x "$PROCESSED_TEMPLATE"

# Ensure the seccomp profile exists for dry-run validation.
mkdir -p ~/.agentbox
cp "$REPO_ROOT/scripts/seccomp.json" ~/.agentbox/seccomp.json

FAKE_HOMES=()
LAST_FAKE_HOME=""

setup_fake_home() {
  LAST_FAKE_HOME=$(mktemp -d /tmp/agentbox-fake-home.XXXXXX 2>/dev/null || mktemp -d)
  LAST_FAKE_HOME=$(canonicalize_path "$LAST_FAKE_HOME")
  FAKE_HOMES+=("$LAST_FAKE_HOME")
  mkdir -p "$LAST_FAKE_HOME/.agentbox"
  cp "$REPO_ROOT/scripts/seccomp.json" "$LAST_FAKE_HOME/.agentbox/seccomp.json"
  cp "$REPO_ROOT/entrypoint.sh" "$LAST_FAKE_HOME/.agentbox/entrypoint.sh"
}

make_canonical_temp_dir() {
  local temp_dir
  temp_dir=$(mktemp -d /tmp/agentbox-temp.XXXXXX 2>/dev/null || mktemp -d)
  canonicalize_path "$temp_dir"
}

file_mode() {
  stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"
}

setup_fake_docker() {
  FAKE_DOCKER_MARKER="$TEST_DIR/docker-invoked"
  local fake_bin="$TEST_DIR/fake-bin"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/docker" <<EOF
#!/bin/sh
printf '%s\n' invoked >> "$FAKE_DOCKER_MARKER"
printf '%s\n' "fake docker invoked" >&2
exit 99
EOF
  chmod +x "$fake_bin/docker"
  FAKE_DOCKER_PATH="$fake_bin:$PATH"
  FAKE_TOOLS_PATH="$FAKE_DOCKER_PATH"
}

setup_fake_security() {
  local fake_bin="$TEST_DIR/fake-bin"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/security" <<'EOF'
#!/bin/sh
set -eu

command_name="${1:-}"
shift || true

if [ "$command_name" != "find-generic-password" ]; then
  echo "fake security only supports find-generic-password" >&2
  exit 2
fi

service=""
account=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s)
      service="$2"
      shift 2
      ;;
    -a)
      account="$2"
      shift 2
      ;;
    -w)
      shift
      ;;
    *)
      shift
      ;;
  esac
done

expected_service="${FAKE_SECURITY_EXPECTED_SERVICE:-Claude Code-credentials}"
expected_account="${FAKE_SECURITY_EXPECTED_ACCOUNT:-${USER:-}}"

if [ "$service" != "$expected_service" ] || [ "$account" != "$expected_account" ]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi

case "${FAKE_SECURITY_MODE:-not_found}" in
  success)
    cat "${FAKE_SECURITY_PAYLOAD_FILE}"
    ;;
  denied)
    echo "security: SecKeychainSearchCopyNext: User interaction is not allowed." >&2
    exit 51
    ;;
  *)
    echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
    exit 44
    ;;
esac
EOF
  chmod +x "$fake_bin/security"
  FAKE_TOOLS_PATH="$fake_bin:$PATH"
}

assert_docker_not_invoked() {
  local name="$1"

  if [ ! -e "$FAKE_DOCKER_MARKER" ]; then
    pass "$name"
  else
    fail "$name"
    echo "    Docker marker should not exist: $FAKE_DOCKER_MARKER" >&2
  fi
}

assert_docker_invoked() {
  local name="$1"

  if [ -e "$FAKE_DOCKER_MARKER" ]; then
    pass "$name"
  else
    fail "$name"
    echo "    Expected Docker marker at: $FAKE_DOCKER_MARKER" >&2
  fi
}

# Cleanup on exit
cleanup() {
  rm -f "$PROCESSED_TEMPLATE"
  if [ "${#FAKE_HOMES[@]}" -gt 0 ]; then
    for fake_home in "${FAKE_HOMES[@]}"; do
      rm -rf "$fake_home"
    done
  fi
  teardown_test_dir 2>/dev/null || true
}
trap cleanup EXIT

# --- Test: JSON structure validation ---
echo "--- JSON Structure Validation ---"

setup_test_dir
git init -q

# Test: Array at root level should be rejected
echo '["not","an","object"]' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .agentbox.json" "JSON array rejected"

# Test: String at root level should be rejected
echo '"just a string"' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .agentbox.json" "JSON string rejected"

# Test: Number at root level should be rejected
echo '42' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .agentbox.json" "JSON number rejected"

# Test: Invalid JSON should be rejected
echo '{invalid json}' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .agentbox.json" "malformed JSON rejected"

# Test: Empty object is valid (no profiles)
echo '{}' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
# Should not contain any error about invalid JSON
assert_not_contains "$output" "Invalid" "empty object accepted"

teardown_test_dir

# --- Test: Path injection prevention ---
echo ""
echo "--- Path Injection Prevention ---"

setup_test_dir
git init -q
path_test_root=$(make_canonical_temp_dir)

# Test: Control characters in path should be rejected
# Using printf to actually include a tab character
printf '{"dev":{"mounts":[{"path":"%s"}]}}' "${path_test_root}/test"$'\t'"path" > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
# Raw control characters make the JSON invalid before mount validation runs.
assert_contains "$output" "Invalid .agentbox.json" "control chars in path rejected"

# Test: JSON-escaped control characters should be rejected before mount parsing
escaped_control_path="${path_test_root}/safe"$'\n'"${path_test_root}/also-safe"
jq -n --arg p "$escaped_control_path" '{"dev":{"mounts":[{"path":$p}]}}' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "invalid characters" "escaped control chars in path rejected"
assert_not_contains "$output" "${path_test_root}/also-safe:${path_test_root}/also-safe" "escaped newline does not create second mount"

# Test: Multiple colons in path should be rejected (Docker mount syntax ambiguity)
colon_path="${path_test_root}/a:b:c"
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$colon_path"}]}}
EOF
# First create the path so it passes the existence check
mkdir -p "$colon_path" 2>/dev/null || true
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "containing ':'" "colon in path warned"
rmdir "$colon_path" 2>/dev/null || true

# Test: Path traversal should be rejected
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$path_test_root/test/../../../etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "path traversal" "path traversal rejected"

# Test: Relative mount paths should be rejected
mkdir -p relative-data
cat > .agentbox.json << 'EOF'
{"dev":{"mounts":[{"path":"relative-data"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "not absolute" "relative mount path rejected"
assert_not_contains "$output" "-v relative-data:relative-data" "relative mount not passed to Docker"

# Test: Non-existent path should warn
cat > .agentbox.json << 'EOF'
{"dev":{"mounts":[{"path":"/nonexistent/path/that/does/not/exist"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "does not exist" "non-existent path warned"

rm -rf "$path_test_root" 2>/dev/null || true

teardown_test_dir

# --- Test: Port validation ---
echo ""
echo "--- Port Validation ---"

setup_test_dir
git init -q

# Test: Port above 65535 should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"ports":[{"host":65536,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "out of range" "port > 65535 rejected"

# Test: Port 0 should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"ports":[{"host":0,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "out of range" "port 0 rejected"

# Test: Negative port should be rejected (jq will output negative number)
cat > .agentbox.json << 'EOF'
{"dev":{"ports":[{"host":-1,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
# Negative numbers won't match the numeric regex
assert_contains "$output" "Invalid port" "negative port rejected"

# Test: Non-numeric port should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"ports":[{"host":"abc","container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "Invalid port" "non-numeric port rejected"

# Test: Valid ports should work
cat > .agentbox.json << 'EOF'
{"dev":{"ports":[{"host":8080,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "127.0.0.1:8080:80" "valid port accepted"

teardown_test_dir

# --- Test: Network mode injection ---
echo ""
echo "--- Network Mode Injection ---"

setup_test_dir
git init -q

# Test: "host" network mode should be rejected (bypasses isolation)
cat > .agentbox.json << 'EOF'
{"dev":{"network":"host"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "host network rejected"

# Test: Injection attempt via network mode
cat > .agentbox.json << 'EOF'
{"dev":{"network":"bridge; rm -rf /"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported" "network injection blocked"

# Test: macvlan network mode should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"network":"macvlan"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "macvlan network rejected"

# Test: Valid network modes
cat > .agentbox.json << 'EOF'
{"dev":{"network":"bridge"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "Unsupported" "bridge network accepted"

cat > .agentbox.json << 'EOF'
{"dev":{"network":"none"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "Unsupported" "none network accepted"
assert_contains "$output" "--network none" "none network applied"

teardown_test_dir

# --- Test: Profile validation ---
echo ""
echo "--- Profile Validation ---"

setup_test_dir
git init -q

# Test: Non-existent profile should error
cat > .agentbox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile nonexistent 2>&1 || true)
assert_contains "$output" "not found" "non-existent profile rejected"

# Test: Empty string profile name should work (auto-select)
cat > .agentbox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "not found" "existing profile accepted"

teardown_test_dir

# --- Test: Resource limit validation ---
echo ""
echo "--- Resource Limit Validation ---"

setup_test_dir
git init -q

# Test: Valid resource limits should be passed through
cat > .agentbox.json << 'EOF'
{
  "dev": {
    "cpu": "2",
    "memory": "4g",
    "pids_limit": 256
  }
}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "--cpus 2" "cpu limit passed"
assert_contains "$output" "--memory 4g" "memory limit passed"
assert_contains "$output" "--pids-limit 256" "pids limit passed"

teardown_test_dir

# --- Test: Blocked path enforcement ---
echo ""
echo "--- Blocked Path Enforcement ---"

setup_test_dir
git init -q

# Test: ~/.ssh should be blocked
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.ssh blocked"

# Test: /etc should be blocked
cat > .agentbox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/etc blocked"

# Test: /etc/passwd should be blocked (child of /etc)
cat > .agentbox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc/passwd"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/etc/passwd blocked"

# Test: / should be blocked
cat > .agentbox.json << 'EOF'
{"dev":{"mounts":[{"path":"/"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/ blocked"

# Test: ~/.aws should be blocked
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.aws"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.aws blocked"

# Test: ~/.docker should be blocked
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.docker"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.docker blocked"

# Test: common user-secret paths should be blocked
for sensitive_path in "$HOME/Library" "$HOME/.config/gh" "$HOME/.git-credentials" "$HOME/.pypirc" "$HOME/.codex"; do
  cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$sensitive_path"}]}}
EOF
  output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
  assert_contains "$output" "blocked by security policy" "$sensitive_path blocked"
done

# Test: $HOME should be blocked because it would expose blocked children
setup_fake_home
fake_home="$LAST_FAKE_HOME"
mkdir -p "$fake_home/.config" "$fake_home/projects/data"
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME ancestor blocked"

# Test: $HOME/.config should be blocked because it would expose .config/gcloud
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/.config"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.config ancestor blocked"

# Test: any hidden direct child under $HOME should be blocked by default
mkdir -p "$fake_home/.customsecret"
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/.customsecret"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "hidden \$HOME child blocked"

# Test: Safe child under $HOME should still be allowed
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/projects/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "blocked" "safe child under \$HOME allowed"

# Test: Blocked mount is skipped without aborting the whole run
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
if "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev &>/dev/null; then
  pass "blocked path skipped without aborting"
else
  fail "blocked path should be skipped, not abort"
fi

# Test: Ancestor mount is also skipped without aborting
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
if HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev &>/dev/null; then
  pass "ancestor blocked path skipped without aborting"
else
  fail "ancestor blocked path should be skipped, not abort"
fi

# Test: Running from $HOME should also be blocked because the implicit cwd mount
# would expose blocked children.
mkdir -p "$fake_home/project"
output=$(
  cd "$fake_home" || exit 1
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true
)
assert_contains "$output" "Working directory blocked (security policy)" "implicit \$HOME cwd blocked"

# Test: Running from a safe child under $HOME should still be allowed
output=$(
  cd "$fake_home/project" &&
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1
)
assert_not_contains "$output" "Working directory blocked" "safe cwd under \$HOME allowed"

# Test: Canonical temp paths are not blocked
allowed_mount_dir=$(make_canonical_temp_dir)
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$allowed_mount_dir"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "blocked" "canonical temp path is not blocked"
rm -rf "$allowed_mount_dir" 2>/dev/null || true

teardown_test_dir

# --- Test: Symlink path enforcement ---
echo ""
echo "--- Symlink Path Enforcement ---"

setup_test_dir
git init -q

setup_fake_home
fake_home="$LAST_FAKE_HOME"
symlink_root=$(make_canonical_temp_dir)
mkdir -p "$fake_home/.ssh/child" "$symlink_root/safe-target/data" "$symlink_root/real/project"
ln -s "$fake_home/.ssh" "$symlink_root/blocked-link"
ln -s "$symlink_root/safe-target" "$symlink_root/safe-link"
ln -s "$symlink_root/real" "$symlink_root/workdir-link"

# Test: Mount with blocked target behind a symlinked ancestor is rejected and skipped
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/blocked-link/child"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "traverses a symlink (security policy)" "blocked symlink ancestor rejected"
assert_contains "$output" "docker run" "blocked symlink ancestor skipped without aborting"

# Test: Mount with a safe target behind a symlinked ancestor is also rejected
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/safe-link/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "traverses a symlink (security policy)" "safe symlink ancestor rejected"
assert_contains "$output" "docker run" "safe symlink ancestor skipped without aborting"

# Test: Canonical safe path is still accepted
cat > .agentbox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/safe-target/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_not_contains "$output" "traverses a symlink" "canonical safe mount accepted"
assert_contains "$output" "$symlink_root/safe-target/data:$symlink_root/safe-target/data" "canonical safe mount included"

# Test: Working directory via symlinked ancestor is rejected
output=$(
  cd "$symlink_root/workdir-link/project" || exit 1
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true
)
assert_contains "$output" "Working directory traverses a symlink" "symlinked cwd rejected"

# Test: Canonical working directory is still accepted
output=$(
  cd "$symlink_root/real/project" &&
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1
)
assert_not_contains "$output" "Working directory traverses a symlink" "canonical cwd accepted"

rm -rf "$symlink_root" 2>/dev/null || true

teardown_test_dir

# --- Test: Resource limit format validation ---
echo ""
echo "--- Resource Limit Format Validation ---"

setup_test_dir
git init -q

# Test: Invalid cpu format should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"cpu":"abc"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid cpu format" "invalid cpu rejected"

# Test: Injection attempt in cpu should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"cpu":"2; rm -rf /"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid cpu format" "cpu injection rejected"

# Test: Invalid memory format should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"memory":"lots"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid memory format" "invalid memory rejected"

# Test: Invalid pids_limit format should be rejected
cat > .agentbox.json << 'EOF'
{"dev":{"pids_limit":"abc"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid pids_limit format" "invalid pids_limit rejected"

# Test: Default pids-limit is always present (no profile config)
echo '{"dev":{}}' > .agentbox.json
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "--pids-limit 256" "default pids-limit present"

# Test: Valid decimal cpu should be accepted
cat > .agentbox.json << 'EOF'
{"dev":{"cpu":"1.5"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "--cpus 1.5" "decimal cpu accepted"

teardown_test_dir

# --- Test: Mount readonly flag ---
echo ""
echo "--- Mount Readonly Flag ---"

setup_test_dir
git init -q

# Create test directories
test_mount_rw=$(make_canonical_temp_dir)
test_mount_ro=$(make_canonical_temp_dir)

cat > .agentbox.json << EOF
{
  "dev": {
    "mounts": [
      {"path": "$test_mount_rw", "readonly": false},
      {"path": "$test_mount_ro", "readonly": true}
    ]
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
# RW mount should not have :ro suffix (beyond the path)
assert_matches "$output" "${test_mount_rw}:${test_mount_rw}[^:]" "rw mount without :ro"
# RO mount should have :ro suffix
assert_contains "$output" "$test_mount_ro:$test_mount_ro:ro" "ro mount has :ro"

# Cleanup
rm -rf "$test_mount_rw" "$test_mount_ro" 2>/dev/null || true

teardown_test_dir

# --- Test: Config detection ---
echo ""
echo "--- Config Detection ---"

setup_test_dir
git init -q

# Test: --profile with no config file should error
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "no .agentbox.json found" "error when --profile but no config"

# Test: No config file and no --profile should NOT error about config
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
assert_not_contains "$output" ".agentbox.json" "no spurious config message without --profile"

# Test: Config file with jq missing fails closed instead of skipping settings
cat > .agentbox.json << 'EOF'
{"dev":{"network":"none"}}
EOF
no_jq_bin="$TEST_DIR/no-jq-bin"
mkdir -p "$no_jq_bin"
for tool in basename dirname mkdir; do
  ln -s "$(command -v "$tool")" "$no_jq_bin/$tool"
done
output=$(PATH="$no_jq_bin" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 || true)
assert_contains "$output" "jq is required to parse .agentbox.json" "missing jq fails closed"

teardown_test_dir

# --- Test: Project Dockerfile opt-in ---
echo ""
echo "--- Project Dockerfile Opt-In ---"

setup_test_dir
git init -q

setup_fake_home
fake_home="$LAST_FAKE_HOME"

cat > .agentbox.Dockerfile << 'EOF'
FROM agentbox
RUN exit 99
EOF

project_dockerfile_exit=0
if output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run 2>&1); then
  project_dockerfile_exit=0
else
  project_dockerfile_exit=$?
fi
if [ "$project_dockerfile_exit" -ne 0 ]; then
  pass "project Dockerfile without opt-in fails in dry-run"
else
  fail "project Dockerfile without opt-in should fail in dry-run"
fi
assert_contains "$output" "Refusing to build repo-controlled .agentbox.Dockerfile" "project Dockerfile dry-run requires opt-in"

output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --allow-project-dockerfile --dry-run 2>&1)
assert_contains "$output" "Per-project image build allowed by --allow-project-dockerfile" "project Dockerfile dry-run reports opt-in"
assert_contains "$output" "--user 1000:1000" "project Dockerfile dry-run forces UID 1000"
assert_contains "$output" "--entrypoint /bin/bash" "project Dockerfile dry-run forces bash entrypoint"
assert_contains "$output" "/home/claude/entrypoint.sh" "project Dockerfile dry-run runs trusted entrypoint"

teardown_test_dir

# --- Test: Dry-run summary ---
echo ""
echo "--- Dry-run Summary ---"

setup_test_dir
git init -q

test_dryrun_mount=$(make_canonical_temp_dir)
cat > .agentbox.json << EOF
{
  "dev": {
    "mounts": [
      {"path": "$test_dryrun_mount", "readonly": true}
    ],
    "ports": [
      {"host": 3000, "container": 3000}
    ]
  }
}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "Runtime: claude" "dry-run shows claude runtime"
assert_contains "$output" "Profile: dev" "dry-run shows profile"
assert_contains "$output" "$test_dryrun_mount" "dry-run shows mount paths"
assert_contains "$output" "Ports:" "dry-run shows ports"
assert_contains "$output" "dry-run" "dry-run shows summary header"

output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "No agent runtime selected." "missing runtime is rejected"
assert_contains "$output" "--claude, --codex" "missing runtime points to explicit choices"

output=$("$PROCESSED_TEMPLATE" --codex --dry-run -p "hello codex" 2>&1)
assert_contains "$output" "Runtime: codex" "dry-run shows codex runtime"
assert_contains "$output" "AGENTBOX_RUNTIME=codex" "codex dry-run passes runtime env"
assert_contains "$output" "CODEX_HOME=/home/claude/.codex" "codex dry-run sets CODEX_HOME"
assert_contains "$output" "/home/claude/.codex" "codex dry-run mounts codex state"
assert_contains "$output" "exec hello\\ codex" "codex -p translates to exec prompt"

setup_fake_home
runtime_home="$LAST_FAKE_HOME"
output=$(HOME="$runtime_home" "$PROCESSED_TEMPLATE" --codex --dry-run -p "hello codex" 2>&1)
assert_contains "$output" "$runtime_home/.agentbox/empty-runtime/claude-config:/home/claude/.claude" "codex run mounts empty Claude state"
assert_not_contains "$output" "$runtime_home/.agentbox/claude-config:/home/claude/.claude" "codex run does not mount Claude credential state"
assert_contains "$output" "$runtime_home/.agentbox/codex-config:/home/claude/.codex" "codex run mounts Codex state"

output=$(HOME="$runtime_home" "$PROCESSED_TEMPLATE" --claude --dry-run -p "hello claude" 2>&1)
assert_contains "$output" "$runtime_home/.agentbox/claude-config:/home/claude/.claude" "claude run mounts Claude state"
assert_contains "$output" "$runtime_home/.agentbox/empty-runtime/codex-config:/home/claude/.codex" "claude run mounts empty Codex state"
assert_not_contains "$output" "$runtime_home/.agentbox/codex-config:/home/claude/.codex" "claude run does not mount Codex credential state"

rm -rf "$test_dryrun_mount" 2>/dev/null || true

teardown_test_dir

# --- Test: Profile confirmation ---
echo ""
echo "--- Profile Confirmation ---"

setup_test_dir
git init -q

cat > .agentbox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1)
assert_contains "$output" "Using profile:" "explicit --profile shows confirmation"

teardown_test_dir

# --- Test: Parse error visibility ---
echo ""
echo "--- Parse Error Visibility ---"

setup_test_dir
git init -q

# Test: Profile with invalid mounts type should show jq error (not silently swallowed)
cat > .agentbox.json << 'EOF'
{"dev": {"mounts": "not-an-array"}}
EOF
output=$("$PROCESSED_TEMPLATE" --claude --dry-run --profile dev 2>&1 || true)
# jq should produce an error since .mounts is not iterable as an array
assert_not_contains "$output" "AGENTBOX_EXTRA_MOUNTS=$" "parse error not silently swallowed"

teardown_test_dir

# --- Test: Project trust commands ---
echo ""
echo "--- Project Trust Commands ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude"
cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" trust --list 2>&1)
assert_contains "$output" "$TEST_DIR" "trusted project appears in trust list"

trust_record=$(find "$fake_home/.agentbox/trusted-projects" -type f -print -quit)
assert_contains "$(<"$trust_record")" "version=2" "trusted project record uses identity format"

git_dir_before=$(git rev-parse --absolute-git-dir)
rm -rf "$git_dir_before"
git init -q
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
if [[ "$output" == *"Project is not trusted for networked Claude credentials"* ]]; then
  pass "replaced project identity is not trusted"
else
  fail "replaced project identity should not stay trusted"
fi

HOME="$fake_home" "$PROCESSED_TEMPLATE" untrust >/dev/null 2>&1
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" trust --list 2>&1)
assert_not_contains "$output" "$TEST_DIR" "untrusted project removed from trust list"

teardown_test_dir

# --- Test: Host auth preflight ---
echo ""
echo "--- Host Auth Preflight ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.agentbox/claude-config"

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "missing host auth is rejected"
assert_contains "$output" "Run 'claude' on the host and complete /login" "missing host auth points to host login"
assert_docker_not_invoked "missing host auth exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.agentbox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"sandbox-access","refreshToken":"sandbox-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.agentbox/.claude.json" << 'EOF'
{"oauthAccount":{"displayName":"Sandbox Session"}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude shell 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "sandbox-only auth does not satisfy preflight"
assert_docker_not_invoked "sandbox-only auth still exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude"

cat > "$fake_home/.claude.json" << 'EOF'
{"oauthAccount":{"displayName":"Host Session"}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "host account metadata alone does not satisfy preflight"
assert_docker_not_invoked "host account metadata alone exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"refreshToken":}}
EOF

cat > "$fake_home/.claude.json" << 'EOF'
{"oauthAccount":
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "invalid host auth JSON is rejected"
assert_docker_not_invoked "invalid host auth exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=denied "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "Host Claude login could not be read from macOS Keychain." "keychain denial shows a specific error"
assert_contains "$output" "Approve read access to 'Claude Code-credentials'" "keychain denial points to the exact keychain item"
assert_docker_not_invoked "keychain denial exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "Project is not trusted for networked Claude credentials" "valid host auth still requires project trust"
assert_docker_not_invoked "untrusted project exits before docker"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "trusted project with valid host auth allows launch flow to continue"
assert_docker_invoked "trusted project with valid host auth reaches docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
keychain_credentials_file="$TEST_DIR/keychain-credentials.json"

cat > "$keychain_credentials_file" << 'EOF'
{"claudeAiOauth":{"accessToken":"keychain-access","refreshToken":"keychain-refresh","expiresAt":123}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "Project is not trusted for networked Claude credentials" "valid keychain auth still requires project trust"
assert_docker_not_invoked "untrusted keychain-auth project exits before docker"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "trusted project with valid keychain auth allows launch flow to continue"
assert_docker_invoked "trusted project with valid keychain auth reaches docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --codex -p "hello" 2>&1 || true)
assert_contains "$output" "No host Codex login detected." "missing codex auth is rejected"
assert_contains "$output" "Run 'codex login' on the host" "missing codex auth points to host login"
assert_docker_not_invoked "missing codex auth exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.codex"

cat > "$fake_home/.codex/auth.json" << 'EOF'
{"OPENAI_API_KEY":"host-key"}
EOF

cat > "$fake_home/.codex/config.toml" << 'EOF'
model = "gpt-5.4"
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --codex -p "hello" 2>&1 || true)
assert_contains "$output" "Project is not trusted for networked Codex credentials" "valid codex auth still requires project trust"
assert_docker_not_invoked "untrusted codex project exits before docker"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --codex -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "trusted project with valid codex auth allows launch flow to continue"
assert_docker_invoked "trusted project with valid codex auth reaches docker"
assert_contains "$(<"$fake_home/.agentbox/codex-config/auth.json")" "host-key" "host codex auth mirrored"
assert_contains "$(<"$fake_home/.agentbox/codex-config/config.toml")" "gpt-5.4" "host codex config mirrored"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" OPENAI_API_KEY="env-key" "$PROCESSED_TEMPLATE" --codex -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "codex OPENAI_API_KEY allows launch flow to continue"
assert_docker_invoked "codex OPENAI_API_KEY reaches docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
secret_key="sk-test-secret-for-dry-run"
output=$(HOME="$fake_home" OPENAI_API_KEY="$secret_key" "$PROCESSED_TEMPLATE" --codex --dry-run -p "hello" 2>&1)
assert_contains "$output" "OPENAI_API_KEY" "codex dry-run shows API key env name"
assert_not_contains "$output" "$secret_key" "codex dry-run redacts API key value"
assert_not_contains "$output" "OPENAI_API_KEY=$secret_key" "codex dry-run does not embed API key assignment"

teardown_test_dir

# --- Test: Network none bypasses project trust gate ---
echo ""
echo "--- Network Trust Gate ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF
cat > "$fake_home/.agentbox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

cat > .agentbox.json << 'EOF'
{"offline":{"network":"none"}}
EOF

dry_output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run -p "hello" 2>&1)
assert_contains "$dry_output" "$fake_home/.agentbox/authless-runtime/claude-config:/home/claude/.claude" "network none untrusted mounts authless Claude state"
assert_not_contains "$dry_output" "$fake_home/.agentbox/claude-config:/home/claude/.claude" "network none untrusted does not mount normal Claude state"
codex_offline_secret="sk-offline-untrusted-secret"
codex_dry_output=$(HOME="$fake_home" OPENAI_API_KEY="$codex_offline_secret" "$PROCESSED_TEMPLATE" --codex --dry-run -p "hello" 2>&1)
assert_not_contains "$codex_dry_output" "OPENAI_API_KEY" "network none untrusted does not pass Codex API key env"
assert_not_contains "$codex_dry_output" "$codex_offline_secret" "network none untrusted does not expose Codex API key value"

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "network none allows untrusted project to reach docker"
assert_docker_invoked "network none bypasses trust gate"
authless_credentials=$(cat "$fake_home/.agentbox/authless-runtime/claude-config/.credentials.json" 2>/dev/null || true)
assert_not_contains "$authless_credentials" "host-refresh" "network none untrusted does not mirror host credentials"
normal_credentials=$(cat "$fake_home/.agentbox/claude-config/.credentials.json" 2>/dev/null || true)
assert_contains "$normal_credentials" "stale-refresh" "network none untrusted leaves normal credential mirror untouched"

teardown_test_dir

# --- Test: Host auth sync ---
echo ""
echo "--- Host Auth Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.claude.json" << 'EOF'
{
  "recommendedSubscription": "max",
  "subscriptionUpsellShownCount": 7,
  "oauthAccount": {
    "displayName": "Host Session",
    "accountCreatedAt": "2026-03-21T16:50:27Z"
  }
}
EOF

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.agentbox/.claude.json" << 'EOF'
{
  "recommendedSubscription": "stale",
  "subscriptionUpsellShownCount": 99,
  "oauthAccount": {
    "displayName": "Sandbox Session"
  }
}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" >/dev/null 2>&1 || true

synced_name=$(jq -r '.oauthAccount.displayName' "$fake_home/.agentbox/.claude.json")
synced_subscription=$(jq -r '.recommendedSubscription' "$fake_home/.agentbox/.claude.json")
synced_upsell_count=$(jq -r '.subscriptionUpsellShownCount' "$fake_home/.agentbox/.claude.json")
synced_created_at=$(jq -r '.oauthAccount.accountCreatedAt' "$fake_home/.agentbox/.claude.json")
synced_state_mode=$(file_mode "$fake_home/.agentbox/.claude.json")

assert_equals "$synced_name" "Host Session" "host oauthAccount overwrites stale sandbox data"
assert_equals "$synced_subscription" "max" "host subscription metadata mirrored"
assert_equals "$synced_upsell_count" "7" "host upsell counters mirrored"
assert_equals "$synced_created_at" "2026-03-21T16:50:27Z" "host auth metadata fields preserved in mirror"
assert_equals "$synced_state_mode" "600" "host Claude state mirror is private"

teardown_test_dir

# --- Test: Host credentials sync ---
echo ""
echo "--- Host Credentials Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.claude.json" << 'EOF'
{}
EOF

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.agentbox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" >/dev/null 2>&1 || true

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.agentbox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "host-refresh" "host credentials file mirrored into sandbox"

teardown_test_dir

# --- Test: State sync does not follow sandbox-planted symlinks ---
echo ""
echo "--- State Sync Symlink Safety ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security

mkdir -p "$fake_home/.claude/plugins/cache/example-market/example-plugin"
mkdir -p "$fake_home/.agentbox/claude-config" "$fake_home/.agentbox/plugins"

cat > "$fake_home/.claude.json" << 'EOF'
{"hostState":true}
EOF
cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF
printf '%s\n' 'host-plugin' > "$fake_home/.claude/plugins/cache/example-market/example-plugin/plugin.js"

credential_target="$TEST_DIR/credential-target.json"
state_target="$TEST_DIR/state-target.json"
plugin_target="$TEST_DIR/plugin-target"
printf '%s\n' 'do-not-overwrite-credential' > "$credential_target"
printf '%s\n' 'do-not-overwrite-state' > "$state_target"
mkdir -p "$plugin_target"

ln -s "$credential_target" "$fake_home/.agentbox/claude-config/.credentials.json"
ln -s "$state_target" "$fake_home/.agentbox/.claude.json"
ln -s "$plugin_target" "$fake_home/.agentbox/plugins/cache"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" >/dev/null 2>&1 || true

assert_equals "$(<"$credential_target")" "do-not-overwrite-credential" "credential sync does not follow planted file symlink"
assert_equals "$(<"$state_target")" "do-not-overwrite-state" "state sync does not follow planted file symlink"
assert_not_contains "$(find "$plugin_target" -maxdepth 2 -type f -print 2>/dev/null || true)" "plugin.js" "plugin sync does not follow planted directory symlink"
if [ ! -L "$fake_home/.agentbox/claude-config/.credentials.json" ]; then
  pass "credential symlink replaced with private file"
else
  fail "credential symlink replaced with private file"
fi
if [ ! -L "$fake_home/.agentbox/.claude.json" ]; then
  pass "state symlink replaced with private file"
else
  fail "state symlink replaced with private file"
fi
if [ ! -L "$fake_home/.agentbox/plugins/cache" ] && [ -f "$fake_home/.agentbox/plugins/cache/example-market/example-plugin/plugin.js" ]; then
  pass "plugin cache symlink replaced with private directory"
else
  fail "plugin cache symlink replaced with private directory"
fi
assert_equals "$(file_mode "$fake_home/.agentbox")" "700" "agentbox state root is private"
assert_equals "$(file_mode "$fake_home/.agentbox/claude-config")" "700" "claude state directory is private"

teardown_test_dir

# --- Test: Host keychain credentials sync ---
echo ""
echo "--- Host Keychain Credentials Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
keychain_credentials_file="$TEST_DIR/keychain-credentials.json"
mkdir -p "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.agentbox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

cat > "$keychain_credentials_file" << 'EOF'
{"claudeAiOauth":{"accessToken":"keychain-access","refreshToken":"keychain-refresh","expiresAt":123}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" --claude -p "hello" >/dev/null 2>&1 || true

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.agentbox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "keychain-refresh" "host keychain credentials mirrored into sandbox when file is absent"

teardown_test_dir

# --- Test: Dry-run does not sync credentials ---
echo ""
echo "--- Dry-run Credential Safety ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.agentbox/claude-config"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.agentbox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude --dry-run >/dev/null 2>&1

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.agentbox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "stale-refresh" "dry-run does not mirror host credentials"

teardown_test_dir

# --- Test: Audit log permissions ---
echo ""
echo "--- Audit Log Permissions ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker

cat > .agentbox.json << 'EOF'
{"audit":{"network":"none","audit_log":true}}
EOF

HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --claude -p "hello" >/dev/null 2>&1 || true
logs_dir="$fake_home/.agentbox/logs"
log_file=$(find "$logs_dir" -type f -name 'agentbox-*.log' -print -quit 2>/dev/null || true)

assert_equals "$(file_mode "$logs_dir")" "700" "audit log directory is private"
if [ -n "$log_file" ]; then
  pass "audit log file is created"
  assert_equals "$(file_mode "$log_file")" "600" "audit log file is private"
else
  fail "audit log file is created"
fi

teardown_test_dir

# --- Test: Plugin sync still works ---
echo ""
echo "--- Plugin Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
mkdir -p "$fake_home/.claude/plugins/marketplaces/example-market"
mkdir -p "$fake_home/.claude/plugins/cache/example-market/example-plugin"

printf '%s\n' '{"name":"example-market"}' > "$fake_home/.claude/plugins/marketplaces/example-market/manifest.json"
printf '%s\n' 'console.log("cached plugin")' > "$fake_home/.claude/plugins/cache/example-market/example-plugin/plugin.js"

cat > "$fake_home/.claude/plugins/installed_plugins.json" << EOF
{"plugins":[{"path":"$fake_home/.claude/plugins/cache/example-market/example-plugin/plugin.js"}]}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" --claude --dry-run >/dev/null 2>&1

if [ -f "$fake_home/.agentbox/plugins/marketplaces/example-market/manifest.json" ]; then
  pass "marketplace plugins synced into sandbox mirror"
else
  fail "marketplace plugins synced into sandbox mirror"
fi

if [ -f "$fake_home/.agentbox/plugins/cache/example-market/example-plugin/plugin.js" ]; then
  pass "plugin cache synced into sandbox mirror"
else
  fail "plugin cache synced into sandbox mirror"
fi

plugin_metadata=$(<"$fake_home/.agentbox/plugins/installed_plugins.json")
assert_contains "$plugin_metadata" "/home/claude/.claude/plugins/cache/example-market/example-plugin/plugin.js" "plugin metadata paths rewritten for container"
assert_not_contains "$plugin_metadata" "$fake_home" "plugin metadata omits host home paths"

teardown_test_dir

# --- Summary ---
summary
