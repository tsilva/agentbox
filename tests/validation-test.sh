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
  FAKE_HOMES+=("$LAST_FAKE_HOME")
  mkdir -p "$LAST_FAKE_HOME/.claudebox"
  cp "$REPO_ROOT/scripts/seccomp.json" "$LAST_FAKE_HOME/.claudebox/seccomp.json"
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

# Test: Control characters in path should be rejected
# Using printf to actually include a tab character
printf '{"dev":{"mounts":[{"path":"/tmp/test\tpath"}]}}' > .claudebox.json
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
# Raw control characters make the JSON invalid before mount validation runs.
assert_contains "$output" "Invalid .claudebox.json" "control chars in path rejected"

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

# Test: $HOME should be blocked because it would expose blocked children
setup_fake_home
fake_home="$LAST_FAKE_HOME"
mkdir -p "$fake_home/.config" "$fake_home/projects/data"
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "\$HOME ancestor blocked"

# Test: $HOME/.config should be blocked because it would expose .config/gcloud
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/.config"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1 || true)
assert_contains "$output" "blocked (security policy)" "\$HOME/.config ancestor blocked"

# Test: Safe child under $HOME should still be allowed
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home/projects/data"}]}}
EOF
output=$(HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_not_contains "$output" "blocked" "safe child under \$HOME allowed"

# Test: Blocked path exits with non-zero
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$HOME/.ssh"}]}}
EOF
if "$PROCESSED_TEMPLATE" --dry-run --profile dev &>/dev/null; then
  fail "blocked path should exit non-zero"
else
  pass "blocked path exits non-zero"
fi

# Test: Ancestor mount also exits with non-zero
cat > .claudebox.json << EOF
{"dev":{"mounts":[{"path":"$fake_home"}]}}
EOF
if HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run --profile dev &>/dev/null; then
  fail "ancestor blocked path should exit non-zero"
else
  pass "ancestor blocked path exits non-zero"
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

teardown_test_dir

# --- Test: Dry-run summary ---
echo ""
echo "--- Dry-run Summary ---"

setup_test_dir
git init -q

mkdir -p /tmp/test-dryrun-mount
cat > .claudebox.json << 'EOF'
{
  "dev": {
    "mounts": [
      {"path": "/tmp/test-dryrun-mount", "readonly": true}
    ],
    "ports": [
      {"host": 3000, "container": 3000}
    ]
  }
}
EOF
output=$("$PROCESSED_TEMPLATE" --dry-run --profile dev 2>&1)
assert_contains "$output" "Profile: dev" "dry-run shows profile"
assert_contains "$output" "/tmp/test-dryrun-mount" "dry-run shows mount paths"
assert_contains "$output" "Ports:" "dry-run shows ports"
assert_contains "$output" "dry-run" "dry-run shows summary header"

rmdir /tmp/test-dryrun-mount 2>/dev/null || true

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

# --- Test: Host auth sync ---
echo ""
echo "--- Host Auth Sync ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
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

cat > "$fake_home/.claudebox/.claude.json" << 'EOF'
{
  "recommendedSubscription": "stale",
  "subscriptionUpsellShownCount": 99,
  "oauthAccount": {
    "displayName": "Sandbox Session"
  }
}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run >/dev/null 2>&1

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

HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run >/dev/null 2>&1

synced_refresh_token=$(jq -r '.claudeAiOauth.refreshToken' "$fake_home/.claudebox/claude-config/.credentials.json")
assert_equals "$synced_refresh_token" "host-refresh" "host credentials file mirrored into sandbox"

teardown_test_dir

# --- Test: Stale sandbox credentials removed ---
echo ""
echo "--- Stale Sandbox Credentials ---"

setup_test_dir

setup_fake_home
fake_home="$LAST_FAKE_HOME"
mkdir -p "$fake_home/.claudebox/claude-config"

cat > "$fake_home/.claudebox/claude-config/.credentials.json" << 'EOF'
{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"stale-refresh","expiresAt":1}}
EOF

HOME="$fake_home" "$PROCESSED_TEMPLATE" --dry-run >/dev/null 2>&1

if [ ! -e "$fake_home/.claudebox/claude-config/.credentials.json" ]; then
  pass "stale sandbox credentials removed when host file is absent"
else
  fail "stale sandbox credentials removed when host file is absent"
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
