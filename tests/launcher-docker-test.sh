#!/usr/bin/env bash
# Behavioral checks cross the actual installed launcher interface.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! docker info >/dev/null 2>&1; then echo 'SKIP: Docker daemon unavailable'; exit 0; fi
docker image inspect agentbox agentbox-broker >/dev/null
initial_volumes=$(docker volume ls -q --filter label=agentbox.managed=true | sort)
export DOCKER_HOST="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
test_root=$(mktemp -d /tmp/agentbox-launch-docker.XXXXXXXX)
test_root=$(cd "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/home/.agentbox/bin" "$test_root/project"
export HOME="$test_root/home"
cp "$repo_dir/scripts/seccomp.json" "$HOME/.agentbox/seccomp.json"
cp "$repo_dir/entrypoint.sh" "$HOME/.agentbox/entrypoint.sh"
cp "$repo_dir/scripts/workspace.py" "$HOME/.agentbox/bin/workspace.py"
"$repo_dir/scripts/render-cli.sh" agentbox > "$HOME/.agentbox/bin/agentbox"
chmod 755 "$HOME/.agentbox/bin/agentbox"
cli="$HOME/.agentbox/bin/agentbox"
cd "$test_root/project"
git init -q
printf 'original\n' > file.txt
"$cli" trust
export OPENAI_API_KEY=agentbox-provider-canary
"$cli" --codex review --broker shell -c '
  set -eu
  [ "$(id -u)" != 0 ]
  grep -q "NoNewPrivs:.*1" /proc/self/status
  grep -q "CapEff:.*0000000000000000" /proc/self/status
  if touch /opt/forbidden 2>/dev/null; then exit 1; fi
  if touch "$PWD/file.txt" 2>/dev/null; then exit 1; fi
  if touch "$PWD/.git/forbidden" 2>/dev/null; then exit 1; fi
  if env | grep -q agentbox-provider-canary; then exit 1; fi
  [ -r /home/claude ] && [ -x /home/claude ]
  credential_scan_status=0
  rg --hidden --no-ignore -l agentbox-provider-canary /home/claude || credential_scan_status=$?
  [ "$credential_scan_status" = 1 ]
  python3 - <<"PY"
import socket
for family, address in [(socket.AF_INET,"1.1.1.1"), (socket.AF_INET,"169.254.169.254"), (socket.AF_INET,"172.17.0.1"), (socket.AF_INET6,"2606:4700:4700::1111")]:
    s=socket.socket(family,socket.SOCK_STREAM)
    s.settimeout(1)
    try:
        s.connect((address,443))
    except OSError:
        pass
    else:
        raise SystemExit("direct network access succeeded")
    finally:
        s.close()
try:
    socket.getaddrinfo("example.com",443)
except OSError:
    pass
else:
    raise SystemExit("external DNS resolution succeeded")
PY
  /opt/agentbox/agentbox-broker relay /run/agentbox/api.sock &
  for _ in $(seq 1 50); do
    /opt/agentbox/agentbox-broker probe 127.0.0.1:18080 >/dev/null 2>&1 && break
    sleep 0.1
  done
  status=$(curl --max-time 2 -s -o /tmp/denied -w "%{http_code}" http://127.0.0.1:18080/shutdown)
  [ "$status" = 403 ]
'
# Exercise normal entrypoint startup as well as the shell override, using
# canary keys and version queries that never request provider inference.
export ANTHROPIC_API_KEY=agentbox-provider-canary
"$cli" --claude review --broker --version
"$cli" --codex review --broker --version
[ -z "$(ls -A "$HOME/.agentbox/sessions")" ]
# Confirm real staged mounts cannot edit the source checkout before apply.
printf 'private-source-secret\n' > .env
"$cli" --codex offline --staged shell -c '
  set -eu
  [ ! -e "$1/file.txt" ]
  [ ! -e .env ]
  if touch .git/forbidden 2>/dev/null; then exit 1; fi
  printf "edited\n" > file.txt
' -- agentbox-stage-check "$PWD"
[ "$(cat file.txt)" = original ]
staged_sessions=("$HOME/.agentbox/sessions"/session.*)
[ "${#staged_sessions[@]}" -eq 1 ]
"$cli" apply "${staged_sessions[0]##*/}"
[ "$(cat file.txt)" = edited ]
[ "$(cat .env)" = private-source-secret ]
[ -z "$(ls -A "$HOME/.agentbox/sessions")" ]
[ "$(docker volume ls -q --filter label=agentbox.managed=true | sort)" = "$initial_volumes" ]
echo 'PASS: actual launcher enforces read-only mounts, non-root, capabilities, auth separation, network isolation, broker startup/routes, staged edits/apply, and cleanup'
