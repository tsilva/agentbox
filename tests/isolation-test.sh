#!/bin/bash
# =============================================================================
# isolation-test.sh - Container boundary verification tests
#
# These tests verify that container isolation mechanisms are working correctly
# and that the sandbox boundaries prevent escape.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"

echo "=== Container Isolation Tests ==="
echo ""

# These tests require Docker and the built image
require_docker
require_image

# --- Test: Capabilities are dropped ---
echo "--- Capability Tests ---"

# All capability fields should be zero (no capabilities)
caps=$(docker run --rm --cap-drop=ALL --entrypoint /bin/bash \
  claudebox -c "cat /proc/self/status | grep '^Cap' | awk '{print \$2}'")

all_zero=true
for cap in $caps; do
  if [ "$cap" != "0000000000000000" ]; then
    all_zero=false
    break
  fi
done

if [ "$all_zero" = true ]; then
  pass "all capabilities dropped (all zeros)"
else
  fail "some capabilities remain"
  echo "    Caps: $caps" >&2
fi

# Test that ping fails (requires CAP_NET_RAW)
ping_result=$(docker run --rm --cap-drop=ALL --entrypoint /bin/bash \
  claudebox -c "ping -c 1 127.0.0.1 2>&1" || true)

assert_contains "$ping_result" "Operation not permitted" "ping blocked (CAP_NET_RAW dropped)"

# --- Test: Filesystem isolation ---
echo ""
echo "--- Filesystem Isolation ---"

# Host paths should not be accessible
host_path_result=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "ls /Users 2>&1" || true)
assert_contains "$host_path_result" "No such file" "/Users not accessible"

# /etc/passwd inside container should NOT contain host users
passwd_content=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "cat /etc/passwd")
assert_not_contains "$passwd_content" "$(whoami)" "host user not in container /etc/passwd"

# Test read-only root filesystem
readonly_result=$(docker run --rm --read-only --entrypoint /bin/bash \
  claudebox -c "touch /usr/test 2>&1" || true)
assert_contains "$readonly_result" "Read-only file system" "root filesystem is read-only"

# Test that /opt is read-only (where claude binary lives)
opt_result=$(docker run --rm --read-only --entrypoint /bin/bash \
  claudebox -c "touch /opt/test 2>&1" || true)
assert_contains "$opt_result" "Read-only file system" "/opt is read-only"

# --- Test: Process isolation (PID namespace) ---
echo ""
echo "--- Process Isolation ---"

# PID 1 should be our process, not the host init
pid1_cmdline=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "cat /proc/1/cmdline | tr '\0' ' '")

# In a proper PID namespace, PID 1 is the container's entrypoint
# Not systemd, init, or launchd from the host
assert_not_contains "$pid1_cmdline" "systemd" "PID 1 is not host systemd"
assert_not_contains "$pid1_cmdline" "launchd" "PID 1 is not host launchd"
assert_not_contains "$pid1_cmdline" "/sbin/init" "PID 1 is not host init"

# Container should only see its own processes
ps_count=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "ps aux | wc -l")
# Should be small number (ps header + bash + ps itself)
if [ "$ps_count" -lt 10 ]; then
  pass "container sees limited processes ($ps_count lines)"
else
  fail "container sees too many processes ($ps_count lines)"
fi

# --- Test: Network isolation with --network none ---
echo ""
echo "--- Network Isolation ---"

# With --network none, only loopback interface should exist
interfaces=$(docker run --rm --network none --entrypoint /bin/bash \
  claudebox -c "ip -o link show | awk '{print \$2}' | tr -d ':'")

# Should only see "lo" (loopback)
if [ "$interfaces" = "lo" ]; then
  pass "network none: only loopback interface"
else
  fail "network none: unexpected interfaces"
  echo "    Found: $interfaces" >&2
fi

# External DNS should fail with --network none
dns_result=$(docker run --rm --network none --entrypoint /bin/bash \
  claudebox -c "getent hosts google.com 2>&1" || true)
# Should fail or timeout
if echo "$dns_result" | grep -qE "(not found|No address|failure|error|timed out)" || [ -z "$dns_result" ]; then
  pass "network none: external DNS blocked"
else
  fail "network none: external DNS unexpectedly works"
  echo "    Result: $dns_result" >&2
fi

# --- Test: User namespace (non-root) ---
echo ""
echo "--- User Namespace ---"

# Verify we can't write to root-owned directories
root_write_result=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "touch /root/test 2>&1" || true)
assert_contains "$root_write_result" "Permission denied" "cannot write to /root"

# Verify we can't change ownership
chown_result=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "chown root:root /tmp 2>&1" || true)
assert_contains "$chown_result" "Operation not permitted" "cannot chown (no CAP_CHOWN)"

# --- Test: Tmpfs security ---
echo ""
echo "--- Tmpfs Security ---"

# Verify tmpfs mounts are present and writable
tmpfs_write=$(docker run --rm --read-only \
  --tmpfs "/tmp:rw,nosuid,size=64m" \
  --entrypoint /bin/bash claudebox -c "touch /tmp/test && echo ok")
assert_equals "$tmpfs_write" "ok" "tmpfs /tmp is writable"

# Verify nosuid is enforced on tmpfs (setuid binaries won't work)
# We can't easily test setuid without a setuid binary, but we can verify
# the mount options
mount_opts=$(docker run --rm --read-only \
  --tmpfs "/tmp:rw,nosuid,size=64m" \
  --entrypoint /bin/bash claudebox -c "mount | grep '/tmp' | head -1")
assert_contains "$mount_opts" "nosuid" "tmpfs has nosuid mount option"

# --- Test: No privileged mode ---
echo ""
echo "--- Privileged Mode Check ---"

# Even with explicit --privileged flag in our test (which the real script doesn't use),
# verify the default container behavior. This test confirms our non-privileged baseline.

# In a non-privileged container, /dev should have limited devices
dev_count=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "ls /dev | wc -l")
if [ "$dev_count" -lt 30 ]; then
  pass "limited /dev entries ($dev_count devices)"
else
  fail "too many /dev entries ($dev_count devices) - may indicate privileged mode"
fi

# /sys should be read-only
sys_write_result=$(docker run --rm --entrypoint /bin/bash \
  claudebox -c "echo test > /sys/test 2>&1" || true)
# Should fail with permission denied or read-only
if echo "$sys_write_result" | grep -qE "(Permission denied|Read-only|No such file)"; then
  pass "/sys is protected"
else
  fail "/sys is writable (potential privilege escalation)"
fi

# --- Summary ---
summary
