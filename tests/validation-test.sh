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
TEMPLATE="$REPO_ROOT/scripts/claudebox-template.sh"

# Create a processed version of the template
PROCESSED_TEMPLATE=$(mktemp)
sed 's|PLACEHOLDER_IMAGE_NAME|claudebox|g' \
    "$TEMPLATE" > "$PROCESSED_TEMPLATE"
chmod +x "$PROCESSED_TEMPLATE"

# Ensure the seccomp profile exists for dry-run validation.
mkdir -p ~/.claudebox
cp "$REPO_ROOT/scripts/seccomp.json" ~/.claudebox/seccomp.json

FAKE_HOMES=()
LAST_FAKE_HOME=""

setup_fake_home() {
  LAST_FAKE_HOME=$(mktemp -d /tmp/claudebox-fake-home.XXXXXX 2>/dev/null || mktemp -d)
  LAST_FAKE_HOME=$(canonicalize_path "$LAST_FAKE_HOME")
  FAKE_HOMES+=("$LAST_FAKE_HOME")
  mkdir -p "$LAST_FAKE_HOME/.claudebox"
  cp "$REPO_ROOT/scripts/seccomp.json" "$LAST_FAKE_HOME/.claudebox/seccomp.json"
  cp "$REPO_ROOT/entrypoint.sh" "$LAST_FAKE_HOME/.claudebox/entrypoint.sh"
}

make_canonical_temp_dir() {
  local temp_dir
  temp_dir=$(mktemp -d /tmp/claudebox-temp.XXXXXX 2>/dev/null || mktemp -d)
  canonicalize_path "$temp_dir"
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
echo '["not","an","object"]' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .claudebox.json" "JSON array rejected"

# Test: String at root level should be rejected
echo '"just a string"' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .claudebox.json" "JSON string rejected"

# Test: Number at root level should be rejected
echo '42' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .claudebox.json" "JSON number rejected"

# Test: Invalid JSON should be rejected
echo '{invalid json}' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "Invalid .claudebox.json" "malformed JSON rejected"

# Test: Empty object is valid (no profiles)
echo '{}' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
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
printf '{"dev":{"mounts":[{"path":"%s"}]}}' "${path_test_root}/test"$'\t'"path" > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
# Raw control characters make the JSON invalid before mount validation runs.
assert_contains "$output" "Invalid .claudebox.json" "control chars in path rejected"

# Test: Multiple colons in path should be rejected (Docker mount syntax ambiguity)
colon_path="${path_test_root}/a:b:c"
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$colon_path"}]}}
EOF
# First create the path so it passes the existence check
mkdir -p "$colon_path" 2>/dev/null || true
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "containing ':'" "colon in path warned"
rmdir "$colon_path" 2>/dev/null || true

# Test: Path traversal should be rejected
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$path_test_root/test/../../../etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "path traversal" "path traversal rejected"

# Test: Non-existent path should warn
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/nonexistent/path/that/does/not/exist"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "does not exist" "non-existent path warned"

rm -rf "$path_test_root" 2>/dev/null || true

teardown_test_dir

# --- Test: Port validation ---
echo ""
echo "--- Port Validation ---"

setup_test_dir
git init -q

# Test: Port above 65535 should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"ports":[{"host":65536,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "out of range" "port > 65535 rejected"

# Test: Port 0 should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"ports":[{"host":0,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "out of range" "port 0 rejected"

# Test: Negative port should be rejected (jq will output negative number)
cat > .claudebox.json << 'EOF'
{"dev":{"ports":[{"host":-1,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
# Negative numbers won't match the numeric regex
assert_contains "$output" "Invalid port" "negative port rejected"

# Test: Non-numeric port should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"ports":[{"host":"abc","container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "Invalid port" "non-numeric port rejected"

# Test: Valid ports should work
cat > .claudebox.json << 'EOF'
{"dev":{"ports":[{"host":8080,"container":80}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "127.0.0.1:8080:80" "valid port accepted"

teardown_test_dir

# --- Test: Network mode injection ---
echo ""
echo "--- Network Mode Injection ---"

setup_test_dir
git init -q

# Test: "host" network mode should be rejected (bypasses isolation)
cat > .claudebox.json << 'EOF'
{"dev":{"network":"host"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "host network rejected"

# Test: Injection attempt via network mode
cat > .claudebox.json << 'EOF'
{"dev":{"network":"bridge; rm -rf /"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported" "network injection blocked"

# Test: macvlan network mode should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"network":"macvlan"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "macvlan network rejected"

# Test: Valid network modes
cat > .claudebox.json << 'EOF'
{"dev":{"network":"bridge"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "Unsupported" "bridge network accepted"

cat > .claudebox.json << 'EOF'
{"dev":{"network":"none"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "Unsupported" "none network accepted"
assert_contains "$output" "--network none" "none network applied"

teardown_test_dir

# --- Test: Profile validation ---
echo ""
echo "--- Profile Validation ---"

setup_test_dir
git init -q

# Test: Non-existent profile should error
cat > .claudebox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile nonexistent 2>&1 || true)
assert_contains "$output" "not found" "non-existent profile rejected"

# Test: Empty string profile name should work (auto-select)
cat > .claudebox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "not found" "existing profile accepted"

teardown_test_dir

# --- Test: Resource limit validation ---
echo ""
echo "--- Resource Limit Validation ---"

setup_test_dir
git init -q

# Test: Valid resource limits should be passed through
cat > .claudebox.json << 'EOF'
{
  "dev": {
    "cpu": "2",
    "memory": "4g",
    "pids_limit": 256
  }
}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
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
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.ssh blocked"

# Test: /etc should be blocked
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/etc blocked"

# Test: /etc/passwd should be blocked (child of /etc)
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc/passwd"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/etc/passwd blocked"

# Test: / should be blocked
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "/ blocked"

# Test: ~/.aws should be blocked
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.aws"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.aws blocked"

# Test: ~/.docker should be blocked
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.docker"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.docker blocked"

# Test: common user-secret paths should be blocked
for sensitive_path in "$HOME/Library" "$HOME/.config/gh" "$HOME/.git-credentials" "$HOME/.pypirc"; do
  cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$sensitive_path"}]}}
EOF
  output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
  assert_contains "$output" "blocked by security policy" "$sensitive_path blocked"
done

# Test: $HOME should be blocked because it would expose blocked children
setup_fake_home
fake_home="$LAST_FAKE_HOME"
mkdir -p "$fake_home/.config" "$fake_home/projects/data"
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME ancestor blocked"

# Test: $HOME/.config should be blocked because it would expose .config/gcloud
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/.config"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "\$HOME/.config ancestor blocked"

# Test: any hidden direct child under $HOME should be blocked by default
mkdir -p "$fake_home/.customsecret"
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/.customsecret"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked by security policy" "hidden \$HOME child blocked"

# Test: Safe child under $HOME should still be allowed
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/projects/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "blocked" "safe child under \$HOME allowed"

# Test: Blocked mount is skipped without aborting the whole run
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
if "$PROCESSED_TEMPLATE" --dry-run --profile dev &>/dev/null; then
  pass "blocked path skipped without aborting"
else
  fail "blocked path should be skipped, not abort"
fi

# Test: Ancestor mount is also skipped without aborting
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
if HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev &>/dev/null; then
  pass "ancestor blocked path skipped without aborting"
else
  fail "ancestor blocked path should be skipped, not abort"
fi

# Test: Running from $HOME should also be blocked because the implicit cwd mount
# would expose blocked children.
mkdir -p "$fake_home/project"
output=$(
  cd "$fake_home" || exit 1
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run 2>&1 || true
)
assert_contains "$output" "Working directory blocked (security policy)" "implicit \$HOME cwd blocked"

# Test: Running from a safe child under $HOME should still be allowed
output=$(
  cd "$fake_home/project" &&
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run 2>&1
)
assert_not_contains "$output" "Working directory blocked" "safe cwd under \$HOME allowed"

# Test: Canonical temp paths are not blocked
allowed_mount_dir=$(make_canonical_temp_dir)
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$allowed_mount_dir"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
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
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/blocked-link/child"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "traverses a symlink (security policy)" "blocked symlink ancestor rejected"
assert_contains "$output" "docker run" "blocked symlink ancestor skipped without aborting"

# Test: Mount with a safe target behind a symlinked ancestor is also rejected
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/safe-link/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "traverses a symlink (security policy)" "safe symlink ancestor rejected"
assert_contains "$output" "docker run" "safe symlink ancestor skipped without aborting"

# Test: Canonical safe path is still accepted
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$symlink_root/safe-target/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "traverses a symlink" "canonical safe mount accepted"
assert_contains "$output" "$symlink_root/safe-target/data:$symlink_root/safe-target/data" "canonical safe mount included"

# Test: Working directory via symlinked ancestor is rejected
output=$(
  cd "$symlink_root/workdir-link/project" || exit 1
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run 2>&1 || true
)
assert_contains "$output" "Working directory traverses a symlink" "symlinked cwd rejected"

# Test: Canonical working directory is still accepted
output=$(
  cd "$symlink_root/real/project" &&
  HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run 2>&1
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
cat > .claudebox.json << 'EOF'
{"dev":{"cpu":"abc"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid cpu format" "invalid cpu rejected"

# Test: Injection attempt in cpu should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"cpu":"2; rm -rf /"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid cpu format" "cpu injection rejected"

# Test: Invalid memory format should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"memory":"lots"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid memory format" "invalid memory rejected"

# Test: Invalid pids_limit format should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"pids_limit":"abc"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Invalid pids_limit format" "invalid pids_limit rejected"

# Test: Default pids-limit is always present (no profile config)
echo '{"dev":{}}' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "--pids-limit 256" "default pids-limit present"

# Test: Valid decimal cpu should be accepted
cat > .claudebox.json << 'EOF'
{"dev":{"cpu":"1.5"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
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

cat > .claudebox.json << EOF
{
  "dev": {
    "mounts": [
      {"path": "$test_mount_rw", "readonly": false},
      {"path": "$test_mount_ro", "readonly": true}
    ]
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
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
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "no .claudebox.json found" "error when --profile but no config"

# Test: No config file and no --profile should NOT error about config
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
assert_not_contains "$output" ".claudebox.json" "no spurious config message without --profile"

# Test: Config file with jq missing fails closed instead of skipping settings
cat > .claudebox.json << 'EOF'
{"dev":{"network":"none"}}
EOF
no_jq_bin="$TEST_DIR/no-jq-bin"
mkdir -p "$no_jq_bin"
for tool in basename dirname mkdir; do
  ln -s "$(command -v "$tool")" "$no_jq_bin/$tool"
done
output=$(PATH="$no_jq_bin" "$PROCESSED_TEMPLATE" --dry-run 2>&1 || true)
assert_contains "$output" "jq is required to parse .claudebox.json" "missing jq fails closed"

teardown_test_dir

# --- Test: Project Dockerfile opt-in ---
echo ""
echo "--- Project Dockerfile Opt-In ---"

setup_test_dir
git init -q

setup_fake_home
fake_home="$LAST_FAKE_HOME"

cat > .claudebox.Dockerfile << 'EOF'
FROM claudebox
RUN exit 99
EOF

project_dockerfile_exit=0
if output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run 2>&1); then
  project_dockerfile_exit=0
else
  project_dockerfile_exit=$?
fi
if [ "$project_dockerfile_exit" -ne 0 ]; then
  pass "project Dockerfile without opt-in fails in dry-run"
else
  fail "project Dockerfile without opt-in should fail in dry-run"
fi
assert_contains "$output" "Refusing to build repo-controlled .claudebox.Dockerfile" "project Dockerfile dry-run requires opt-in"

output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --allow-project-dockerfile --dry-run 2>&1)
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
cat > .claudebox.json << EOF
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
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "Profile: dev" "dry-run shows profile"
assert_contains "$output" "$test_dryrun_mount" "dry-run shows mount paths"
assert_contains "$output" "Ports:" "dry-run shows ports"
assert_contains "$output" "dry-run" "dry-run shows summary header"

rm -rf "$test_dryrun_mount" 2>/dev/null || true

teardown_test_dir

# --- Test: Profile confirmation ---
echo ""
echo "--- Profile Confirmation ---"

setup_test_dir
git init -q

cat > .claudebox.json << 'EOF'
{"dev":{}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "Using profile:" "explicit --profile shows confirmation"

teardown_test_dir

# --- Test: Parse error visibility ---
echo ""
echo "--- Parse Error Visibility ---"

setup_test_dir
git init -q

# Test: Profile with invalid mounts type should show jq error (not silently swallowed)
cat > .claudebox.json << 'EOF'
{"dev": {"mounts": "not-an-array"}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
# jq should produce an error since .mounts is not iterable as an array
assert_not_contains "$output" "CLAUDEBOX_EXTRA_MOUNTS=$" "parse error not silently swallowed"

teardown_test_dir

# --- Test: Project trust commands ---
echo ""
echo "--- Project Trust Commands ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" trust --list 2>&1)
assert_contains "$output" "$TEST_DIR" "trusted project appears in trust list"

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
mkdir -p "$fake_home/.claudebox/claude-config"

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "missing host auth is rejected"
assert_contains "$output" "Run 'claude' on the host and complete /login" "missing host auth points to host login"
assert_docker_not_invoked "missing host auth exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claudebox/claude-config"

cat > "$fake_home/.claudebox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"sandbox-access","refreshToken":"sandbox-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.claudebox/.claude.json" << 'EOF'
{"oauthAccount":{"displayName":"Sandbox Session"}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" shell 2>&1 || true)
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

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
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

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "No host Claude login detected." "invalid host auth JSON is rejected"
assert_docker_not_invoked "invalid host auth exits before docker"

teardown_test_dir

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=denied "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
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

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "Project is not trusted for networked Claude credentials" "valid host auth still requires project trust"
assert_docker_not_invoked "untrusted project exits before docker"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
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

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "Project is not trusted for networked Claude credentials" "valid keychain auth still requires project trust"
assert_docker_not_invoked "untrusted keychain-auth project exits before docker"

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "trusted project with valid keychain auth allows launch flow to continue"
assert_docker_invoked "trusted project with valid keychain auth reaches docker"

teardown_test_dir

# --- Test: Network none bypasses project trust gate ---
echo ""
echo "--- Network Trust Gate ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > .claudebox.json << 'EOF'
{"offline":{"network":"none"}}
EOF

output=$(HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" 2>&1 || true)
assert_contains "$output" "fake docker invoked" "network none allows untrusted project to reach docker"
assert_docker_invoked "network none bypasses trust gate"

teardown_test_dir

# --- Test: Host auth sync ---
echo ""
echo "--- Host Auth Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.claudebox/claude-config"

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

cat > "$fake_home/.claudebox/.claude.json" << 'EOF'
{
  "recommendedSubscription": "stale",
  "subscriptionUpsellShownCount": 99,
  "oauthAccount": {
    "displayName": "Sandbox Session"
  }
}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" >/dev/null 2>&1 || true

synced_name=$(jq -r '.oauthAccount.displayName' "$fake_home/.claudebox/.claude.json")
synced_subscription=$(jq -r '.recommendedSubscription' "$fake_home/.claudebox/.claude.json")
synced_upsell_count=$(jq -r '.subscriptionUpsellShownCount' "$fake_home/.claudebox/.claude.json")
synced_created_at=$(jq -r '.oauthAccount.accountCreatedAt' "$fake_home/.claudebox/.claude.json")

assert_equals "$synced_name" "Host Session" "host oauthAccount overwrites stale sandbox data"
assert_equals "$synced_subscription" "max" "host subscription metadata mirrored"
assert_equals "$synced_upsell_count" "7" "host upsell counters mirrored"
assert_equals "$synced_created_at" "2026-03-21T16:50:27Z" "host auth metadata fields preserved in mirror"

teardown_test_dir

# --- Test: Host credentials sync ---
echo ""
echo "--- Host Credentials Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_docker
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.claudebox/claude-config"

cat > "$fake_home/.claude.json" << 'EOF'
{}
EOF

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.claudebox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" -p "hello" >/dev/null 2>&1 || true

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.claudebox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "host-refresh" "host credentials file mirrored into sandbox"

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
mkdir -p "$fake_home/.claudebox/claude-config"

cat > "$fake_home/.claudebox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

cat > "$keychain_credentials_file" << 'EOF'
{"claudeAiOauth":{"accessToken":"keychain-access","refreshToken":"keychain-refresh","expiresAt":123}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" trust >/dev/null 2>&1
HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" FAKE_SECURITY_MODE=success FAKE_SECURITY_PAYLOAD_FILE="$keychain_credentials_file" "$PROCESSED_TEMPLATE" -p "hello" >/dev/null 2>&1 || true

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.claudebox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "keychain-refresh" "host keychain credentials mirrored into sandbox when file is absent"

teardown_test_dir

# --- Test: Dry-run does not sync credentials ---
echo ""
echo "--- Dry-run Credential Safety ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
setup_fake_security
mkdir -p "$fake_home/.claude" "$fake_home/.claudebox/claude-config"

cat > "$fake_home/.claude/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"host-access","refreshToken":"host-refresh","expiresAt":123}}
EOF

cat > "$fake_home/.claudebox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

HOME="$fake_home" PATH="$FAKE_TOOLS_PATH" "$PROCESSED_TEMPLATE" --dry-run >/dev/null 2>&1

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.claudebox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "stale-refresh" "dry-run does not mirror host credentials"

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

HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run >/dev/null 2>&1

if [ -f "$fake_home/.claudebox/plugins/marketplaces/example-market/manifest.json" ]; then
  pass "marketplace plugins synced into sandbox mirror"
else
  fail "marketplace plugins synced into sandbox mirror"
fi

if [ -f "$fake_home/.claudebox/plugins/cache/example-market/example-plugin/plugin.js" ]; then
  pass "plugin cache synced into sandbox mirror"
else
  fail "plugin cache synced into sandbox mirror"
fi

plugin_metadata=$(<"$fake_home/.claudebox/plugins/installed_plugins.json")
assert_contains "$plugin_metadata" "/home/claude/.claude/plugins/cache/example-market/example-plugin/plugin.js" "plugin metadata paths rewritten for container"
assert_not_contains "$plugin_metadata" "$fake_home" "plugin metadata omits host home paths"

teardown_test_dir

# --- Summary ---
summary
