#!/usr/bin/env python3
"""Exercise the installed launcher interface with controlled Docker/auth adapters."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]

DOCKER = '''import json,os,pathlib,sys,time
args=sys.argv[1:]
root=pathlib.Path(os.environ['MOCK_CAPTURE'])
root.mkdir(exist_ok=True)
if args[:1] == ['run']:
 name=args[args.index('--name')+1] if '--name' in args else 'versions'
 mounts=[];env=[];content={}
 for i,a in enumerate(args):
  if a=='-v':
   spec=args[i+1];source,dest=spec.split(':')[:2];mounts.append(spec)
   p=pathlib.Path(source)
   if dest in ['/home/claude/.claude','/home/claude/.codex','/credentials'] and p.is_dir():
    for f in p.rglob('*'):
     if f.is_file() and not f.is_symlink() and f.stat().st_size<4096:
      content[dest+'/'+str(f.relative_to(p))]=f.read_text()
  if a=='-e': env.append(args[i+1])
 record={'args':args,'mounts':mounts,'env':env,'content':content}
 (root/(name+'.json')).write_text(json.dumps(record))
 if '--entrypoint' in args and args[-1].endswith('/VERSION'):
  print('rust-v1.0.0' if '/codex/' in args[-1] else '1.0.0')
 elif '--name' in args:
  time.sleep(float(os.environ.get('MOCK_HOLD','0')))
  print(name)
elif args[:1]==['logs']: print('session output')
elif args[:1]==['volume']:
 with (root/'volumes.jsonl').open('a') as f: f.write(json.dumps(args)+'\\n')
'''


class Launcher(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agentbox-launch-', dir='/tmp')
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / 'home'
        self.project = self.root / 'project'
        self.tools = self.root / 'tools'
        self.capture = self.root / 'capture'
        for p in [self.home, self.project, self.tools, self.capture]: p.mkdir()
        self.state = self.home / '.agentbox'
        self.bin = self.state / 'bin'
        self.bin.mkdir(parents=True)
        shutil.copy(REPO / 'scripts/seccomp.json', self.state / 'seccomp.json')
        shutil.copy(REPO / 'entrypoint.sh', self.state / 'entrypoint.sh')
        shutil.copy(REPO / 'scripts/workspace.py', self.bin / 'workspace.py')
        self.cli = self.bin / 'agentbox'
        self.cli.write_bytes(subprocess.check_output([str(REPO / 'scripts/render-cli.sh')]))
        self.cli.chmod(0o755)
        self.tool('docker', DOCKER, python=True)
        self.tool('security', 'echo checked >> "$MOCK_CAPTURE/keychain"\nif [ "${MOCK_KEYCHAIN:-}" = success ]; then echo \'{"claudeAiOauth":{"refreshToken":"keychain-canary"}}\'; else exit 44; fi')
        self.tool('curl', 'printf "%s" "${MOCK_CURL:-}"')
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.tools)+os.pathsep+os.environ['PATH'], MOCK_CAPTURE=str(self.capture))
        self.env.pop('OPENAI_API_KEY', None)
        self.env.pop('ANTHROPIC_API_KEY', None)
        subprocess.run(['git','init','-q',str(self.project)], check=True)
        subprocess.run(['git','-C',str(self.project),'config','user.email','test@example.com'],check=True)
        subprocess.run(['git','-C',str(self.project),'config','user.name','Test'],check=True)
        (self.home / '.claude').mkdir()
        (self.home / '.codex').mkdir()
        (self.home / '.claude/.credentials.json').write_text('{"claudeAiOauth":{"refreshToken":"claude-canary"}}')
        (self.home / '.codex/auth.json').write_text('{"OPENAI_API_KEY":"codex-canary"}')
        (self.home / '.codex/config.toml').write_text('model="example"')

    def tearDown(self): self.tmp.cleanup()

    def tool(self, name, text, python=False):
        path = self.tools / name
        path.write_text(('#!'+sys.executable+'\n' if python else '#!/bin/sh\n')+text+'\n')
        path.chmod(0o755)

    def run_cli(self, *args, code=0, env=None):
        result = subprocess.run([str(self.cli),*args],cwd=self.project,env=dict(self.env,**(env or {})),capture_output=True,text=True)
        self.assertEqual(result.returncode,code,result.stderr)
        return result

    def trusted(self): self.run_cli('trust')

    def records(self): return [json.loads(p.read_text()) for p in self.capture.glob('agentbox-*.json')]

    def test_preferences_and_no_shell_evaluation(self):
        self.run_cli('setup','--codex')
        out = self.run_cli('inspect').stdout
        self.assertIn('Runtime: codex',out)
        (self.state/'default-runtime').write_text('$(touch malicious)')
        self.run_cli('inspect',code=1)
        self.assertFalse((self.project/'malicious').exists())

    def test_preview_has_no_auth_or_state_side_effects(self):
        before = sorted(str(p.relative_to(self.state)) for p in self.state.rglob('*'))
        self.run_cli('--claude','--dry-run')
        self.run_cli('--codex','inspect')
        self.assertEqual(before,sorted(str(p.relative_to(self.state)) for p in self.state.rglob('*')))
        self.assertFalse((self.capture/'keychain').exists())
        self.assertEqual(self.records(),[])

    def test_review_keeps_required_controls(self):
        result=self.run_cli('--claude','review','--dry-run')
        for flag in ['--cap-drop=ALL','no-new-privileges','seccomp=','--read-only',':ro','--pids-limit 256']:
            self.assertIn(flag,result.stdout)

    def test_real_launch_selected_runtime_and_cleanup(self):
        self.trusted()
        self.run_cli('--codex','-p','hello')
        record=self.records()[0]
        self.assertIn('codex-canary',record['content']['/home/claude/.codex/auth.json'])
        self.assertNotIn('claude-canary',json.dumps(record))
        self.assertFalse(any((self.state/'sessions').iterdir()))
        self.assertEqual((self.home/'.codex/auth.json').read_text(),'{"OPENAI_API_KEY":"codex-canary"}')

    def test_offline_is_authless_even_when_trusted(self):
        self.trusted()
        self.run_cli('--claude','offline','shell','-c','true')
        record=self.records()[0]
        self.assertIn('none',record['args'])
        self.assertNotIn('canary',json.dumps(record))
        self.assertFalse((self.capture/'keychain').exists())

    def test_untrusted_gate_precedes_keychain(self):
        (self.home/'.claude/.credentials.json').unlink()
        self.run_cli('--claude','-p','hello',code=1)
        self.assertFalse((self.capture/'keychain').exists())
        self.assertEqual(self.records(),[])

    def test_keychain_selected_auth_and_missing_auth(self):
        self.trusted()
        (self.home/'.claude/.credentials.json').unlink()
        self.run_cli('--claude','-p','hello',code=1)
        self.run_cli('--claude','-p','hello',env={'MOCK_KEYCHAIN':'success'})
        self.assertIn('keychain-canary',json.dumps(self.records()))

    def test_parallel_sessions_do_not_share_paths(self):
        self.trusted()
        processes=[subprocess.Popen([str(self.cli),'--codex','-p','hello'],cwd=self.project,env=dict(self.env,MOCK_HOLD='0.5'),stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(2)]
        for process in processes:
            _,err=process.communicate(timeout=10);self.assertEqual(process.returncode,0,err)
        records=self.records()
        self.assertEqual(len(records),2)
        paths=[next(m.split(':')[0] for m in r['mounts'] if m.split(':')[1]=='/home/claude/.codex') for r in records]
        self.assertNotEqual(*paths)
        self.assertFalse(any((self.state/'sessions').iterdir()))

    def test_cleanup_handles_temporary_failure_and_reports_permanent_failure(self):
        self.trusted()
        rm_adapter = '''import os,pathlib,sys
path=pathlib.Path(sys.argv[-1])
if path.name.startswith('session.') and path.parent.name=='sessions':
 flag=pathlib.Path(os.environ['MOCK_CAPTURE'])/'cleanup-failed'
 if not flag.exists() or os.environ.get('MOCK_CLEANUP_FAIL')=='always':
  flag.touch();sys.exit(1)
os.execv('/bin/rm',['rm',*sys.argv[1:]])
'''
        self.tool('rm',rm_adapter,python=True)
        self.run_cli('--codex','-p','hello')
        self.assertTrue((self.capture/'cleanup-failed').exists())
        self.assertFalse(any((self.state/'sessions').iterdir()))
        result=self.run_cli('--codex','-p','hello',code=1,env={'MOCK_CLEANUP_FAIL':'always'})
        self.assertIn('Could not remove private session state',result.stderr)
        remaining=next((self.state/'sessions').iterdir())
        self.assertEqual(remaining.stat().st_mode & 0o777,0o700)

    def test_plugins_explicit_readonly_and_never_synced_for_codex(self):
        plugin=self.home/'.claude/plugins/cache/example'
        plugin.mkdir(parents=True)
        (plugin/'plugin.js').write_text('plugin-canary')
        self.trusted()
        self.run_cli('--codex','-p','hello')
        self.assertFalse((self.state/'plugin-snapshots').exists())
        self.run_cli('plugins','refresh')
        out=self.run_cli('--claude','--plugins','--dry-run').stdout
        self.assertIn('plugin-snapshots',out)
        self.assertIn('/home/claude/.claude/plugins:ro',out)
        self.run_cli('--codex','--plugins','--dry-run',code=1)
        self.run_cli('--claude','offline','--plugins','--dry-run',code=1)

    def test_broker_secrets_outside_agent_and_network_none(self):
        self.trusted()
        self.run_cli('--codex','--broker','-p','hello',env={'OPENAI_API_KEY':'provider-secret'})
        records=self.records()
        broker=next(r for r in records if '/credentials/credentials.json' in r['content'])
        agent=next(r for r in records if '/credentials/credentials.json' not in r['content'])
        self.assertIn('provider-secret',json.dumps(broker))
        self.assertNotIn('provider-secret',json.dumps(agent))
        self.assertIn('--network',agent['args']);self.assertIn('none',agent['args'])
        self.assertNotIn('OPENAI_API_KEY',agent['env'])
        self.assertIn('wire_api = "responses"',agent['content']['/home/claude/.codex/config.toml'])
        self.assertTrue(any(m.startswith('agentbox-socket-session.') and m.endswith('/run/agentbox:ro') for m in agent['mounts']))
        volume_calls=[json.loads(line) for line in (self.capture/'volumes.jsonl').read_text().splitlines()]
        self.assertEqual([a[1] for a in volume_calls],['create','rm'])
        self.assertIn('type=tmpfs',volume_calls[0])
        self.assertFalse(any((self.state/'sessions').iterdir()))

    def test_broker_missing_key_and_conflicts_fail_closed(self):
        self.trusted()
        self.run_cli('--codex','--broker','-p','hello',code=1)
        self.assertEqual(self.records(),[])
        self.run_cli('--codex','--broker','-p','hello',code=1,env={'OPENAI_API_KEY':'invalid\nkey'})
        self.assertEqual(self.records(),[])
        self.run_cli('--codex','offline','--broker','--dry-run',code=1)
        (self.project/'.agentbox.json').write_text('{"dev":{"ports":[{"host":3000,"container":3000}]}}')
        self.run_cli('--codex','--broker','--dry-run',code=1)

    def test_schema_failure_before_auth_or_state(self):
        for config in ['{"dev":{"network":false}}','{"dev":{"audit_log":"yes"}}','{"dev":{"memroy":"1g"}}','{"dev":{"mounts":[{"path":"/tmp","readonly":"false"}]}}']:
            (self.project/'.agentbox.json').write_text(config)
            self.run_cli('--codex','-p','hello',code=1)
            self.assertFalse((self.state/'sessions').exists())
        self.assertEqual(self.records(),[])

    def test_staged_edits_and_apply_with_conflict_protection(self):
        (self.project/'file.txt').write_text('original')
        (self.project/'.env').write_text('secret')
        self.trusted()
        self.run_cli('--codex','--staged','-p','hello')
        session=next((self.state/'sessions').iterdir())
        self.assertFalse((session/'workspace/.env').exists())
        self.assertFalse((session/'codex-config').exists())
        (session/'workspace/file.txt').write_text('edited')
        (session/'workspace/file.txt').chmod(0o760)
        (self.project/'file.txt').write_text('concurrent')
        self.run_cli('apply',session.name,code=1)
        self.assertEqual((self.project/'file.txt').read_text(),'concurrent')
        (self.project/'file.txt').write_text('original')
        self.run_cli('apply',session.name)
        self.assertEqual((self.project/'file.txt').read_text(),'edited')
        self.assertEqual((self.project/'file.txt').stat().st_mode & 0o777,0o760)
        self.assertEqual((self.project/'.env').read_text(),'secret')
        self.assertFalse(session.exists())

    def test_codex_version_warning_uses_codex_cache(self):
        self.trusted()
        (self.state/'version-codex').write_text('rust-v1.0.0')
        (self.state/'.latest-version-codex').write_text('rust-v2.0.0')
        out=self.run_cli('--codex','shell','-c','true').stderr
        self.assertIn('rust-v1.0.0 → rust-v2.0.0',out)

    def test_update_preserves_explicit_runtime_selection(self):
        self.run_cli('setup','--codex')
        source = self.root/'source'
        source.mkdir()
        installer = source/'install.sh'
        installer.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$MOCK_CAPTURE/update-args"\n')
        installer.chmod(0o755)
        (self.state/'.repo-path').write_text(str(source))
        self.tool('git','printf "%s\\n" unchanged')
        self.tool('curl','import sys\nprint(\'{"tag_name":"rust-v2.0.0"}\' if "api.github.com" in sys.argv[-1] else "2.0.0")',python=True)
        self.run_cli('--claude','update')
        self.assertEqual((self.capture/'update-args').read_text().splitlines(),['--update','--runtime','claude'])

    def test_pipe_installer_ignores_project_style_and_preserves_args(self):
        (self.project/'style.sh').write_text('touch "$MOCK_CAPTURE/project-style-executed"')
        stub = '#!/bin/sh\nprintf "%s\\n" "$@"\n'
        git_code = "import pathlib,sys\np=pathlib.Path(sys.argv[3]);p.mkdir(parents=True)\nf=p/'install.sh';f.write_text(" + repr(stub) + ");f.chmod(0o755)"
        self.tool('git', git_code, python=True)
        result=subprocess.run(['bash','-s','--','--runtime','codex'],input=(REPO/'install.sh').read_text(),cwd=self.project,env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('--runtime',result.stdout)
        self.assertIn('codex',result.stdout)
        self.assertFalse((self.capture/'project-style-executed').exists())

    def test_signed_installer_verifies_identity_and_refuses_bad_signatures(self):
        manifest={"schemaVersion":1,"images":{name:{"reference":"ghcr.io/tsilva/agentbox-"+name+"@sha256:"+"a"*64} for name in ["codex","broker"]}}
        fixture=self.root/'images.json'
        fixture.write_text(json.dumps(manifest))
        self.tool('curl', 'import os,pathlib,sys\na=sys.argv\nif "-o" in a: pathlib.Path(a[a.index("-o")+1]).write_text(pathlib.Path(os.environ["MOCK_MANIFEST"]).read_text());print("200",end="")', python=True)
        self.tool('cosign', 'printf "%s\\n" "$*" >> "$MOCK_CAPTURE/signatures"\nexit "${MOCK_SIGN_STATUS:-0}"')
        env=dict(self.env,MOCK_MANIFEST=str(fixture),MOCK_SIGN_STATUS='1')
        result=subprocess.run([str(REPO/'install.sh'),'--runtime','codex','--prebuilt'],env=env,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('signature verification failed',result.stderr)
        self.assertFalse((self.state/'images/codex').exists())
        env['MOCK_SIGN_STATUS']='0'
        result=subprocess.run([str(REPO/'install.sh'),'--runtime','codex','--prebuilt'],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.state/'images/codex').read_text(),manifest['images']['codex']['reference'])
        self.assertIn('release-images.yml@refs/heads/main',(self.capture/'signatures').read_text())
        self.assertEqual((self.state/'version-codex').read_text(),'rust-v1.0.0')

    def test_staged_apply_rejects_symlink_and_new_secret_files(self):
        (self.project/'file.txt').write_text('original')
        self.trusted()
        self.run_cli('--codex','--staged','-p','hello')
        session=next((self.state/'sessions').iterdir())
        (session/'workspace/link').symlink_to(self.project/'file.txt')
        self.run_cli('apply',session.name,code=1)
        (session/'workspace/link').unlink()
        (session/'workspace/.env').write_text('do not apply')
        self.run_cli('apply',session.name,code=1)
        self.assertFalse((self.project/'.env').exists())

    def test_doctor_reports_unavailable_daemon_without_keychain(self):
        self.tool('docker','exit 1')
        out=self.run_cli('doctor',code=1).stdout
        self.assertIn('MISSING: Docker daemon',out)
        self.assertFalse((self.capture/'keychain').exists())


if __name__=='__main__': unittest.main()
