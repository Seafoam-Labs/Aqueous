#!/usr/bin/env python3
"""Opt-in GTK integration with fake Shelly, real helper, and a private compositor."""
import os, pathlib, subprocess, tempfile, time
root=pathlib.Path(__file__).resolve().parents[2]
work=pathlib.Path(tempfile.mkdtemp(prefix='aqueous-welcome-smoke-'))
print('Isolated artifacts:',work,flush=True)
for name in ('run','home','config','state','cache'):(work/name).mkdir(mode=0o700)
(work/'wm.toml').write_text('[layout]\ndefault="tile"\n')
env=dict(os.environ, HOME=str(work/'home'), XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'), XDG_RUNTIME_DIR=str(work/'run'), XDG_CACHE_HOME=str(work/'cache'), XDG_CURRENT_DESKTOP='Aqueous',XDG_SESSION_TYPE='wayland', WLR_BACKENDS='headless',WLR_HEADLESS_OUTPUTS='1',WLR_RENDERER='pixman', LIBGL_ALWAYS_SOFTWARE='1', AQUEOUS_CONFIG=str(work/'wm.toml'),AQUEOUS_WELCOME_TEST_CLOSE_MS='1800', GSK_RENDERER='cairo',GTK_A11Y='none',GTK_USE_PORTAL='0', AQUEOUS_WELCOME_TEST_CHOOSE_INDEX='1')
for name in ('DISPLAY','WAYLAND_DISPLAY','LD_PRELOAD','AQUEOUS_SOCKET','DBUS_SESSION_BUS_ADDRESS'):env.pop(name,None)
for name in ('INPUT','LAYOUT','OUTPUTS','RULES'):env['AQUEOUS_'+name]=str(work/('missing-'+name))
fixtures=work/'bin';fixtures.mkdir()
helper=pathlib.Path(os.environ.get('AQUEOUS_CONFIG_BINARY', str(root/'settingsApplication/zig-out/bin/aqueous-config')))
welcome=pathlib.Path(os.environ.get('AQUEOUS_WELCOME_BINARY', str(root/'welcome/zig-out/bin/aqueous-welcome')))
assert helper.is_file(), 'Build settingsApplication first'
(fixtures/'aqueous-config').symlink_to(helper)
for name in ('pearl','dms','noctalia'):
 (fixtures/name).write_text('#!/bin/sh\nexit 0\n');(fixtures/name).chmod(0o755)
(fixtures/'sudo').write_text(r'''#!/usr/bin/env bash
set -euo pipefail
[[ $1 == -p && $2 == '[sudo] password for %p: ' && $3 == -- && $4 == shelly ]]
shift 3
exec 3<> /dev/tty
case " $(stty -a <&3) " in *' -echo '*) ;; *) exit 91;; esac
printf '[sudo] password for fixture: ' >&3
IFS= read -r secret <&3
[[ $secret == fixture-secret ]] || exit 92
unset secret
printf '\n' >&3
exec 3>&-
export FIXTURE_ELEVATED=1
exec "$@"
''')
(fixtures/'sudo').chmod(0o755)
(fixtures/'shelly').write_text(r'''#!/usr/bin/env python3
import os, sys, json, base64, pathlib, termios
state=pathlib.Path(os.environ['XDG_STATE_HOME'])/'fixture-packages.json'
names=json.loads(state.read_text()) if state.exists() else []
if sys.argv[1]=='list':
 print(json.dumps([{'Name':name} for name in names]));sys.exit(0)
assert sys.argv[1:3]==['install','standard']
assert os.environ.get('FIXTURE_ELEVATED')=='1'
assert '--no-confirm' not in sys.argv and '--ui-mode' in sys.argv
package=sys.argv[3]
def emit(v):
 print('[JSON]'+base64.b64encode(json.dumps(v).encode()).decode()+'[/JSON]',flush=True)
def reply():
 line=sys.stdin.buffer.readline();return json.loads(base64.b64decode(line[6:line.index(b'[/JSON]')]))
emit({'$kind':'q.optdeps','QuestionId':'1','Options':[{'Index':0,'Name':'optional-one'},{'Index':3,'Name':'optional-two'}]})
assert reply()=={'$kind':'a.optdeps','QuestionId':'1','SelectedIndices':[0,3]}
emit({'$kind':'q.transaction','QuestionId':'2','QuestionText':'Install shell and optional dependencies?','Packages':[{'Name':package},{'Name':'optional-one'},{'Name':'optional-two'}]})
assert reply()=={'$kind':'a.transaction','QuestionId':'2','Accept':True}
state.write_text(json.dumps(list(set(names+[package]))))
emit({'$kind':'alpm.info','EventType':'TransactionDone','Message':'Fixture installation complete'})
''')
(fixtures/'shelly').chmod(0o755)
env['PATH']=str(fixtures)+':'+env['PATH']
env['GSETTINGS_BACKEND']='memory'
processes=[]
try:
 dbus=subprocess.Popen(['dbus-daemon','--session','--nofork','--print-address=1'],env=env,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True);processes.append(dbus)
 env['DBUS_SESSION_BUS_ADDRESS']=dbus.stdout.readline().strip()
 with (work/'compositor.log').open('w') as log:
  wm=subprocess.Popen([os.environ.get('AQUEOUS_COMPOSITOR_BIN', str(root/'compositor/zig-out/bin/aqueous')),'-no-xwayland','-c','true'],env=env,stdout=log,stderr=log);processes.append(wm)
  until=time.monotonic()+10
  while not [p for p in (work/'run').glob('wayland-*') if not p.name.endswith('.lock')]:
   if wm.poll() is not None:raise RuntimeError((work/'compositor.log').read_text())
   if time.monotonic()>until:raise RuntimeError('compositor start timeout')
   time.sleep(.05)
  env['WAYLAND_DISPLAY']=next(p.name for p in (work/'run').glob('wayland-*') if not p.name.endswith('.lock'))
  for args,source in [([],None),(['--choose'],'Monitor: HEADLESS-1\nWindow: Test\n')]:
   proc=subprocess.Popen([str(welcome),*args],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
   processes.append(proc)
   if source:
    proc.stdin.write(source);proc.stdin.close();proc.stdin=None
   time.sleep(.7)
   screenshot=work/('chooser.png' if args else 'welcome.png')
   capture=subprocess.run(['grim',str(screenshot)],env=env,capture_output=True)
   assert capture.returncode==0, capture.stderr
   out,err=proc.communicate(timeout=15)
   result=subprocess.CompletedProcess(proc.args,proc.returncode,out,err)
   print('MODE',args,'EXIT',result.returncode,'STDOUT',result.stdout,'STDERR',result.stderr)
   assert result.returncode==0
   if args:assert result.stdout=='Window: Test\n'
  env.pop('AQUEOUS_WELCOME_TEST_CLOSE_MS',None)
  for shell in ('pearl','dms','noctalia','none'):
   env['AQUEOUS_WELCOME_TEST_SETUP']=shell
   result=subprocess.run([str(welcome)],env=env,text=True,capture_output=True,timeout=20)
   selection=work/'config/aqueous/session.toml'
   assert result.returncode==0, result.stderr
   assert selection.exists() and ('shell = "'+shell+'"') in selection.read_text(), (shell,result.stderr,selection.read_text() if selection.exists() else 'no selection')
   assert (work/'state/aqueous/welcome-v1').exists()
   print('GTK + Shelly password + optional dependencies + helper:',shell,'passed',flush=True)
finally:
 for proc in reversed(processes):
  proc.terminate()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
 print('Smoke artifacts:',work)
