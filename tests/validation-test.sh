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

# Cleanup on exit
cleanup() {
  rm -f "$PROCESSED_TEMPLATE"
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

# Test: Control characters in path should be rejected
# Using printf to actually include a tab character
printf '{"dev":{"mounts":[{"path":"/tmp/test\tpath"}]}}' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "invalid characters" "control chars in path rejected"

# Test: Multiple colons in path should be rejected (Docker mount syntax ambiguity)
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/tmp/a:b:c"}]}}
EOF
# First create the path so it passes the existence check
mkdir -p "/tmp/a:b:c" 2>/dev/null || true
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "containing ':'" "colon in path warned"
rmdir "/tmp/a:b:c" 2>/dev/null || true

# Test: Path traversal should be rejected
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/tmp/test/../../../etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "path traversal" "path traversal rejected"

# Test: Non-existent path should warn
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/nonexistent/path/that/does/not/exist"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "does not exist" "non-existent path warned"

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
assert_contains "$output" "blocked (security policy)" "\$HOME/.ssh blocked"

# Test: /etc should be blocked
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "/etc blocked"

# Test: /etc/passwd should be blocked (child of /etc)
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/etc/passwd"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "/etc/passwd blocked"

# Test: / should be blocked
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "/ blocked"

# Test: ~/.aws should be blocked
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.aws"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "\$HOME/.aws blocked"

# Test: ~/.docker should be blocked
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.docker"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "\$HOME/.docker blocked"

# Test: Blocked path exits with non-zero
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
if "$PROCESSED_TEMPLATE" --dry-run --profile dev &>/dev/null; then
  fail "blocked path should exit non-zero"
else
  pass "blocked path exits non-zero"
fi

# Test: /tmp is NOT blocked (common writable mount)
mkdir -p /tmp/claudebox-test-allowed
cat > .claudebox.json << 'EOF'
{"dev":{"mounts":[{"path":"/tmp/claudebox-test-allowed"}]}}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "blocked" "/tmp is not blocked"
rmdir /tmp/claudebox-test-allowed 2>/dev/null || true

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
mkdir -p /tmp/test-mount-rw
mkdir -p /tmp/test-mount-ro

cat > .claudebox.json << 'EOF'
{
  "dev": {
    "mounts": [
      {"path": "/tmp/test-mount-rw", "readonly": false},
      {"path": "/tmp/test-mount-ro", "readonly": true}
    ]
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
# RW mount should not have :ro suffix (beyond the path)
assert_matches "$output" "/tmp/test-mount-rw:/tmp/test-mount-rw[^:]" "rw mount without :ro"
# RO mount should have :ro suffix
assert_contains "$output" "/tmp/test-mount-ro:/tmp/test-mount-ro:ro" "ro mount has :ro"

# Cleanup
rmdir /tmp/test-mount-rw /tmp/test-mount-ro 2>/dev/null || true

teardown_test_dir

# --- Summary ---
summary
