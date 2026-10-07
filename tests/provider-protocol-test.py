#!/usr/bin/env python3
"""Run inside the development image with --network none; never call providers."""
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading


seen = []
received = threading.Event()


class Capture(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        seen.append((self.path, json.loads(body)))
        response = json.dumps({'type': 'error', 'error': {
            'type': 'authentication_error', 'message': 'test provider'}}).encode()
        self.send_response(401)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)
        received.set()

    def log_message(self, *args):
        pass


def check_client(runtime, command, env, allowed_paths):
    seen.clear()
    received.clear()
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(command, cwd='/tmp', env=env,
                                   stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=output, start_new_session=True)
        try:
            ready = received.wait(20)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        output.seek(0)
        diagnostic = output.read().decode(errors='replace')
    assert ready and seen, runtime + ' did not reach the local API: ' + diagnostic
    assert all(path in allowed_paths for path, body in seen), seen
    assert all(isinstance(body, dict) for path, body in seen)
    assert 'Code Mode is unavailable' not in diagnostic, diagnostic
    print('PASS:', runtime, 'native request protocol:', seen[0][0], flush=True)


server = HTTPServer(('127.0.0.1', 18080), Capture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, ANTHROPIC_BASE_URL='http://127.0.0.1:18080',
               ANTHROPIC_API_KEY='agentbox-test-canary',
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1')
    check_client('claude', ['/opt/claude-code/claude', '--dangerously-skip-permissions',
                 '-p', 'Reply OK', '--max-turns', '1'], env,
                 {'/v1/messages', '/v1/messages?beta=true'})
    config = Path('/home/claude/.codex')
    config.mkdir(exist_ok=True)
    (config / 'config.toml').write_text('model_provider="capture"\n'
        '[model_providers.capture]\nname="capture"\n'
        'base_url="http://127.0.0.1:18080/v1"\nwire_api="responses"\n')
    check_client('codex', ['/opt/codex/codex', '--dangerously-bypass-approvals-and-sandbox',
                 'exec', '--skip-git-repo-check', 'Reply OK'], dict(os.environ),
                 {'/v1/responses'})
finally:
    server.shutdown()
