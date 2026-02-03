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
TEMPLATE="$REPO_ROOT/scripts/claudebox-template.sh"

# Create a processed version of the template with placeholders replaced
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

# Ensure the seccomp profile is installed for all tests
mkdir -p ~/.claudebox
cp "$REPO_ROOT/scripts/seccomp.json" ~/.claudebox/seccomp.json

# --- Test: Critical security flags are present ---
echo "--- Critical Security Flags ---"

setup_test_dir

# Run dry-run to get the docker command
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)

# Test: --cap-drop=ALL (drop all Linux capabilities)
assert_contains "$output" "--cap-drop=ALL" "cap-drop=ALL present"

# Test: --security-opt=no-new-privileges (prevent setuid escalation)
assert_contains "$output" "--security-opt=no-new-privileges" "no-new-privileges present"

# Test: --read-only (read-only root filesystem)
assert_contains "$output" "--read-only" "read-only rootfs present"

# Test: tmpfs mounts have nosuid flag
assert_contains "$output" "nosuid" "tmpfs has nosuid flag"

# Test: tmpfs mounts have proper ownership (uid=1000,gid=1000)
assert_contains "$output" "uid=1000,gid=1000" "tmpfs has correct ownership"

teardown_test_dir

# --- Test: Seccomp profile is applied ---
echo ""
echo "--- Seccomp Profile ---"

setup_test_dir

output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
assert_matches "$output" "--security-opt seccomp=" "seccomp profile specified"

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

output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)

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
cat > .claudebox.json << 'EOF'
{
  "dev": {
    "ports": [
      {"host": 8080, "container": 8080},
      {"host": 3000, "container": 3000}
    ]
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)

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
cat > .claudebox.json << 'EOF'
{
  "dev": {
    "network": "host"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "Unsupported network mode" "host network rejected"

# Test that only bridge and none are allowed
cat > .claudebox.json << 'EOF'
{
  "dev": {
    "network": "bridge"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
# Should not error for bridge
assert_not_contains "$output" "Unsupported network mode" "bridge network allowed"

cat > .claudebox.json << 'EOF'
{
  "dev": {
    "network": "none"
  }
}
EOF

output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "--network none" "none network allowed"

teardown_test_dir

# --- Test: Non-root user in container ---
echo ""
echo "--- Non-Root User ---"

require_docker
require_image

# Verify the container runs as UID 1000 (non-root)
uid=$(docker run --rm --entrypoint /bin/bash claudebox -c "id -u")
assert_equals "$uid" "1000" "container runs as UID 1000"

# Verify the user is not root
username=$(docker run --rm --entrypoint /bin/bash claudebox -c "whoami")
assert_not_contains "$username" "root" "container user is not root"

# --- Test: Read-only mode adds protection ---
echo ""
echo "--- Read-Only Mode ---"

setup_test_dir
git init -q

# Test that --readonly flag adds :ro suffix to mounts
output=$("$PROCESSED_TEMPLATE" --dry-run --readonly 2>&1)

# The working directory should have :ro suffix in readonly mode
assert_matches "$output" "$(pwd):[^:]*:ro" "workdir is read-only in readonly mode"

teardown_test_dir

# --- Summary ---
summary
