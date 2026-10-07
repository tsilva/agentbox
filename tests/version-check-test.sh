#!/bin/bash
# =============================================================================
# version-check-test.sh - Version staleness warning tests
#
# These tests verify that the version staleness check correctly warns users
# when a newer Claude Code version is available, and degrades gracefully
# when version files are missing.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

echo "=== Version Staleness Check Tests ==="
echo ""

# Use the template directly with --dry-run

# Create a processed version of the template
PROCESSED_TEMPLATE=$(mktemp)
"$REPO_ROOT/scripts/render-cli.sh" agentbox > "$PROCESSED_TEMPLATE"
chmod +x "$PROCESSED_TEMPLATE"

# Save originals so we can restore them after tests
ORIG_VERSION=""
ORIG_LATEST=""
[ -f "$HOME/.agentbox/version" ] && ORIG_VERSION=$(<"$HOME/.agentbox/version")
[ -f "$HOME/.agentbox/.latest-version" ] && ORIG_LATEST=$(<"$HOME/.agentbox/.latest-version")

# Cleanup on exit: restore originals and remove temp files
cleanup() {
  rm -f "$PROCESSED_TEMPLATE"
  # Restore or remove version files
  if [ -n "$ORIG_VERSION" ]; then
    printf '%s' "$ORIG_VERSION" > "$HOME/.agentbox/version"
  else
    rm -f "$HOME/.agentbox/version"
  fi
  if [ -n "$ORIG_LATEST" ]; then
    printf '%s' "$ORIG_LATEST" > "$HOME/.agentbox/.latest-version"
  else
    rm -f "$HOME/.agentbox/.latest-version"
  fi
  teardown_test_dir 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$HOME/.agentbox"
cp "$REPO_ROOT/scripts/seccomp.json" "$HOME/.agentbox/seccomp.json"

# --- Test: No warning when version file is missing ---
echo "--- Missing Version File ---"

setup_test_dir

rm -f "$HOME/.agentbox/version"
rm -f "$HOME/.agentbox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
assert_not_contains "$output" "update available" "no warning when version file missing"

teardown_test_dir

# --- Test: No warning when versions match ---
echo ""
echo "--- Versions Match ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.agentbox/version"
printf '%s' "2.1.31" > "$HOME/.agentbox/.latest-version"
# Touch the cache so it's fresh
touch "$HOME/.agentbox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
assert_not_contains "$output" "update available" "no warning when versions match"

teardown_test_dir

# --- Test: Preview skips update lookup even when cache differs ---
echo ""
echo "--- Versions Differ ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.agentbox/version"
printf '%s' "2.1.34" > "$HOME/.agentbox/.latest-version"
touch "$HOME/.agentbox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1)
assert_not_contains "$output" "update available" "preview skips version lookup"

teardown_test_dir

# --- Test: Warning goes to stderr ---
echo ""
echo "--- Warning on stderr ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.agentbox/version"
printf '%s' "2.1.34" > "$HOME/.agentbox/.latest-version"
touch "$HOME/.agentbox/.latest-version"
# Capture stdout and stderr separately
stdout_output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>/dev/null)
stderr_output=$("$PROCESSED_TEMPLATE" --claude --dry-run 2>&1 >/dev/null)
assert_not_contains "$stdout_output" "update available" "warning not on stdout"
assert_not_contains "$stderr_output" "update available" "preview does not check versions on stderr"

teardown_test_dir

# --- Summary ---
summary
