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
TEMPLATE="$REPO_ROOT/scripts/claudebox-template.sh"

# Create a processed version of the template
PROCESSED_TEMPLATE=$(mktemp)
sed 's|PLACEHOLDER_IMAGE_NAME|claudebox|g' \
    "$TEMPLATE" > "$PROCESSED_TEMPLATE"
chmod +x "$PROCESSED_TEMPLATE"

# Save originals so we can restore them after tests
ORIG_VERSION=""
ORIG_LATEST=""
[ -f "$HOME/.claudebox/version" ] && ORIG_VERSION=$(<"$HOME/.claudebox/version")
[ -f "$HOME/.claudebox/.latest-version" ] && ORIG_LATEST=$(<"$HOME/.claudebox/.latest-version")

# Cleanup on exit: restore originals and remove temp files
cleanup() {
  rm -f "$PROCESSED_TEMPLATE"
  # Restore or remove version files
  if [ -n "$ORIG_VERSION" ]; then
    printf '%s' "$ORIG_VERSION" > "$HOME/.claudebox/version"
  else
    rm -f "$HOME/.claudebox/version"
  fi
  if [ -n "$ORIG_LATEST" ]; then
    printf '%s' "$ORIG_LATEST" > "$HOME/.claudebox/.latest-version"
  else
    rm -f "$HOME/.claudebox/.latest-version"
  fi
  teardown_test_dir 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$HOME/.claudebox"

# --- Test: No warning when version file is missing ---
echo "--- Missing Version File ---"

setup_test_dir

rm -f "$HOME/.claudebox/version"
rm -f "$HOME/.claudebox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
assert_not_contains "$output" "update available" "no warning when version file missing"

teardown_test_dir

# --- Test: No warning when versions match ---
echo ""
echo "--- Versions Match ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.claudebox/version"
printf '%s' "2.1.31" > "$HOME/.claudebox/.latest-version"
# Touch the cache so it's fresh
touch "$HOME/.claudebox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
assert_not_contains "$output" "update available" "no warning when versions match"

teardown_test_dir

# --- Test: Warning shown when versions differ ---
echo ""
echo "--- Versions Differ ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.claudebox/version"
printf '%s' "2.1.34" > "$HOME/.claudebox/.latest-version"
touch "$HOME/.claudebox/.latest-version"
output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1)
assert_contains "$output" "update available" "warning shown when versions differ"
assert_contains "$output" "2.1.31" "warning includes installed version"
assert_contains "$output" "2.1.34" "warning includes latest version"
assert_contains "$output" "claudebox update" "warning includes update command"

teardown_test_dir

# --- Test: Warning goes to stderr ---
echo ""
echo "--- Warning on stderr ---"

setup_test_dir

printf '%s' "2.1.31" > "$HOME/.claudebox/version"
printf '%s' "2.1.34" > "$HOME/.claudebox/.latest-version"
touch "$HOME/.claudebox/.latest-version"
# Capture stdout and stderr separately
stdout_output=$("$PROCESSED_TEMPLATE" --dry-run 2>/dev/null)
stderr_output=$("$PROCESSED_TEMPLATE" --dry-run 2>&1 >/dev/null)
assert_not_contains "$stdout_output" "update available" "warning not on stdout"
assert_contains "$stderr_output" "update available" "warning on stderr"

teardown_test_dir

# --- Summary ---
summary
