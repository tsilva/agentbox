#!/bin/bash
# =============================================================================
# test-helpers.sh - Shared test utilities for claudebox tests
# =============================================================================

# Test counters
PASS=0
FAIL=0

# Color codes (disabled if not a TTY)
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  RESET='\033[0m'
else
  GREEN=''
  RED=''
  RESET=''
fi

# Record a passing test
pass() {
  echo -e "  ${GREEN}PASS${RESET}: $1"
  ((PASS++)) || true
}

# Record a failing test
fail() {
  echo -e "  ${RED}FAIL${RESET}: $1"
  ((FAIL++)) || true
}

# Assert that output contains a string
# Usage: assert_contains "$output" "expected" ["test name"]
assert_contains() {
  local output="$1"
  local expected="$2"
  local name="${3:-contains '$expected'}"

  if echo "$output" | grep -qF "$expected"; then
    pass "$name"
  else
    fail "$name"
    echo "    Expected to contain: $expected" >&2
    echo "    Actual output: ${output:0:200}..." >&2
  fi
}

# Assert that output does NOT contain a string
# Usage: assert_not_contains "$output" "unexpected" ["test name"]
assert_not_contains() {
  local output="$1"
  local unexpected="$2"
  local name="${3:-not contains '$unexpected'}"

  if ! echo "$output" | grep -qF "$unexpected"; then
    pass "$name"
  else
    fail "$name"
    echo "    Expected NOT to contain: $unexpected" >&2
  fi
}

# Assert that output matches a regex pattern
# Usage: assert_matches "$output" "pattern" ["test name"]
assert_matches() {
  local output="$1"
  local pattern="$2"
  local name="${3:-matches '$pattern'}"

  if echo "$output" | grep -qE "$pattern"; then
    pass "$name"
  else
    fail "$name"
    echo "    Expected to match: $pattern" >&2
    echo "    Actual output: ${output:0:200}..." >&2
  fi
}

# Assert equality
# Usage: assert_equals "$actual" "$expected" ["test name"]
assert_equals() {
  local actual="$1"
  local expected="$2"
  local name="${3:-equals '$expected'}"

  if [ "$actual" = "$expected" ]; then
    pass "$name"
  else
    fail "$name"
    echo "    Expected: $expected" >&2
    echo "    Actual: $actual" >&2
  fi
}

# Create a temporary test directory and cd into it
# Sets TEST_DIR global variable
setup_test_dir() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR" || exit 1
  # Initialize as a git repo (many tests need this)
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
}

# Clean up the test directory
teardown_test_dir() {
  cd / || exit 1
  [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"
}

# Print test summary and exit with appropriate code
summary() {
  echo ""
  echo "=== Results: $PASS passed, $FAIL failed ==="
  [ "$FAIL" -eq 0 ]
}

# Skip a test with a message
skip() {
  echo "  SKIP: $1"
}

# Check if Docker is available and running
require_docker() {
  if ! command -v docker &>/dev/null; then
    echo "SKIP: Docker not installed"
    exit 0
  fi
  if ! docker info &>/dev/null; then
    echo "SKIP: Docker daemon not running"
    exit 0
  fi
}

# Check if the claudebox image exists
require_image() {
  if ! docker image inspect claudebox &>/dev/null; then
    echo "SKIP: claudebox image not built"
    echo "Run: docker build -t claudebox ."
    exit 0
  fi
}

# Check if jq is installed
require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "SKIP: jq not installed"
    exit 0
  fi
}
