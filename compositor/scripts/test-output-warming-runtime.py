#!/usr/bin/env python3
"""Native warming on private headless outputs; never connects to the host display."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import socket as sockets
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--compositor', type=Path, required=True)
p.add_argument('--prefix', type=Path, required=True)
p.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
p.add_argument('--pearl', type=Path)
p.add_argument('--pearl-source', type=Path)
args = p.parse_args()
work = Path(tempfile.mkdtemp(prefix='aqueous-warming-runtime-'))
print(f'Artifacts: {work}', flush=True)
env = {k: v for k, v in os.environ.items() if not k.startswith(('WLR_', 'AQUEOUS_'))}
for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
    env.pop(key, None)
for name in ('runtime', 'config', 'home', 'state', 'cache'):
    (work / name).mkdir(mode=0o700)
env.update(XDG_RUNTIME_DIR=str(work/'runtime'), XDG_CONFIG_HOME=str(work/'config'),
           HOME=str(work/'home'), XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
           XDG_CONFIG_DIRS=str(work/'config'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
           WLR_RENDERER=args.renderer, LD_LIBRARY_PATH=str(args.prefix/'lib'))
children, files = [], []

def compile_client(name, fixture, definitions):
    codes = []
    for stem, xml in definitions.items():
        subprocess.run(['wayland-scanner', 'client-header', xml, work/f'{stem}-client-protocol.h'], check=True)
        code = work/f'{stem}.c'
        subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True)
        codes.append(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}',
                    ROOT/'scripts/fixtures'/fixture, *codes, '-lwayland-client', '-o', work/name], check=True)

def launch(name, command):
    out, err = (work/f'{name}.jsonl').open('w'), (work/f'{name}.log').open('w')
    files.extend((out,err))
    child = subprocess.Popen([str(x) for x in command], env=env, stdin=subprocess.PIPE, stdout=out, stderr=err)
    children.append(child)
    return child

def events(name):
    values = []
    for line in (work/f'{name}.jsonl').read_text().splitlines():
        try: values.append(json.loads(line))
        except ValueError: pass
    return values

def wait(predicate, label, timeout=10):
    deadline = time.monotonic()+timeout
    while time.monotonic()<deadline:
        assert compositor.poll() is None, (work/'compositor.log').read_text()
        value = predicate()
        if value: return value
        time.sleep(.02)
    raise AssertionError(label)

def latest(name, event, output=None):
    return next((v for v in reversed(events(name)) if v.get('event')==event and (output is None or v.get('output')==output)), None)

def send(child, command):
    child.stdin.write((command+'\n').encode());child.stdin.flush()

def pixels(label):
    path=work/f'{label}.png'
    subprocess.run(['grim','-o',output_name,path],check=True,env=env,timeout=10)
    with Image.open(path) as image: return image.convert('RGB').getpixel((image.width//4,image.height//4))

try:
    compile_client('client','output-warming-client.c',{'aqueous-output-warming-v1':ROOT/'protocol/aqueous-output-warming-v1.xml'})
    compositor=launch('compositor',[args.compositor.resolve(),'-no-xwayland','-log-level','debug','-c','true'])
    socket=wait(lambda:next((x for x in (work/'runtime').glob('wayland-*') if x.is_socket()),None),'Wayland socket')
    env['WAYLAND_DISPLAY']=socket.name
    client=launch('client',[work/'client'])
    wait(lambda:latest('client','ready'),'client ready')
    states=[latest('client','state',i) for i in range(2)]
    assert all(states), states
    if args.renderer=='pixman':
        assert all(s['reason'] != 0 and s['qualification']==0 for s in states),states
        send(client,'acquire');wait(lambda:latest('client','denied'),'acquisition denied')
        print('PASS unqualified output snapshots and acquisition denial',flush=True)
    else:
        assert all(s['reason']==0 and s['qualification']==1 for s in states),states
        output_name=latest('client','name',0)['name']
        compile_client('target','output-retry.c',{
            'xdg-shell':Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml'),
            'presentation-time':Path('/usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml'),
        })
        target=launch('target',[work/'target','warming-target',output_name,'0'])
        wait(lambda:latest('target','sample') and latest('target','sample').get('presented',0)>0,'target presented')
        baseline=pixels('baseline')
        send(client,'acquire');wait(lambda:latest('client','acquired'),'acquired')
        send(client,'set 3500')
        applied=wait(lambda:(v:=latest('client','result')) and v,'application result')
        assert applied['status']==0 and applied['kelvin']==3500,applied
        warmed=pixels('warmed')
        assert warmed[2]<baseline[2] and warmed[1]<=baseline[1],(baseline,warmed)
        assert latest('client','state',1)['committed'] != 3500
        other=launch('other',[work/'client']);wait(lambda:latest('other','ready'),'other ready')
        send(other,'acquire');busy=wait(lambda:latest('other','denied'),'busy');assert busy['reason']==5,busy
        send(client,'release')
        wait(lambda:(v:=latest('client','result')) and v['id']==2 and v['status']==0,'restored result')
        restored=pixels('restored');assert restored==baseline,(baseline,restored)
        send(client,'acquire');time.sleep(.1);send(client,'set 4500')
        wait(lambda:(v:=latest('client','result')) and v['kelvin']==4500 and v['status']==0,'second application')
        client.kill();client.wait()
        wait(lambda:(s:=latest('other','state',0)) and s['owner']==0 and s['committed']==6500,'crash restoration')
        assert pixels('crash-restored')==baseline
        send(other,'acquire');wait(lambda:latest('other','acquired'),'reacquire after restoration')
        with sockets.socket(sockets.AF_UNIX) as control:
            control.connect(str(work/'runtime/aqueous/outputd.sock'))
            control.sendall(json.dumps({'op':'test_output_retry','name':output_name,'action':'arm','stage':'output_commit','count':1,'simulate_color_pipeline':True}).encode()+b'\n')
            with control.makefile('r') as response: assert json.loads(response.readline())['ok']
        send(other,'set 3000')
        wait(lambda:(v:=latest('other','result')) and v['status']==0 and v['kelvin']==3000,'fallback application')
        subprocess.run(['wlr-randr','--output',output_name,'--custom-mode','960x720@60Hz'],env=env,check=True,timeout=10)
        wait(lambda:latest('other','revoked'),'mode-change revocation')
        wait(lambda:(v:=latest('other','state',0)) and v['owner']==0 and v['committed']==6500,'mode-change baseline')
        previous=sum(v.get('event')=='acquired' for v in events('other'))
        send(other,'acquire')
        wait(lambda:sum(v.get('event')=='acquired' for v in events('other'))>previous,'acquire before mirror')
        send(other,'set 3300')
        wait(lambda:(v:=latest('other','result')) and v['status']==0 and v['kelvin']==3300,'warming before mirror')
        destination_name=latest('client','name',1)['name']
        def mirror(value):
            with sockets.socket(sockets.AF_UNIX) as control:
                control.connect(str(work/'runtime/aqueous/outputd.sock'))
                control.sendall(json.dumps({'op':'set','changes':[{'name':destination_name,'mirror_of':value}]}).encode()+b'\n')
                with control.makefile('r') as response:
                    reply=json.loads(response.readline());assert reply['ok'],reply
        mirror(output_name)
        wait(lambda:(v:=latest('other','state',0)) and v['reason']==9 and v['committed']==6500 and v['owner']==0,'mirror-source revocation and baseline')
        mirror('')
        wait(lambda:all(latest('other','state',i)['reason']==0 for i in range(2)),'unmirror eligibility')
        previous=sum(v.get('event')=='acquired' for v in events('other'))
        send(other,'output 1');send(other,'acquire')
        wait(lambda:sum(v.get('event')=='acquired' for v in events('other'))>previous,'destination acquire')
        send(other,'set 3400')
        wait(lambda:(v:=latest('other','result')) and v['status']==0 and v['kelvin']==3400,'destination warming')
        mirror(output_name)
        wait(lambda:(v:=latest('other','state',1)) and v['reason']==9 and v['committed']==6500 and v['owner']==0,'mirror-destination restoration')
        mirror('')
        wait(lambda:all(latest('other','state',i)['reason']==0 for i in range(2)),'destination unmirror')
        print('PASS native pixels/status, contention, release/crash, fallback, modeset and mirror transitions',flush=True)
    if args.pearl:
        assert args.renderer == 'vulkan', 'Pearl native application test needs private Vulkan qualification'
        preferences=work/'config/pearl/preferences.json'
        preferences.parent.mkdir(parents=True,exist_ok=True)
        preferences.write_text(json.dumps({'version':1,'night_light':{'enabled':True,'temperature_kelvin':4000,'schedule':'manual','start_minute':1200,'end_minute':420}}))
        bus=launch('bus',['dbus-daemon','--session','--nofork','--print-address','--address=unix:path='+str(work/'runtime/system-bus')])
        address=wait(lambda:(work/'bus.jsonl').read_text().strip(),'private bus')
        env['DBUS_SESSION_BUS_ADDRESS']=address
        env['DBUS_SYSTEM_BUS_ADDRESS']=address
        # The caller can supply a built Pearl from a separate checkout. Its
        # existing private logind fixture is staged, never pointed at host D-Bus.
        assert args.pearl_source, '--pearl-source is required with --pearl'
        power_source=args.pearl_source/'tests/fixtures/services/power.py'
        power_fixture=work/'power-fixture.py'
        power_fixture.write_text(power_source.read_text().replace("unix:path=/tmp/pearl-dev-", "unix:path=/tmp/aqueous-warming-runtime-"))
        env['PEARL_TEST_BACKLIGHT']=str(work/'backlight');(work/'backlight').mkdir()
        env['PEARL_TEST_POWER_LOG']=str(work/'power-events.jsonl')
        power=launch('power',['python3',power_fixture])
        wait(lambda:'event=ready' in (work/'power.jsonl').read_text(),'private logind fixture')
        env['AQUEOUS_SOCKET']=str(next((work/'runtime/aqueous').glob('*/ipc.sock')))
        pearl=launch('pearl',[args.pearl.resolve()])
        ctl=args.pearl.resolve().with_name('pearlctl')
        def night():
            reply=subprocess.run([ctl,'night-light','status'],env=env,text=True,capture_output=True,timeout=5)
            if reply.returncode: return None
            return json.loads(reply.stdout)['result']
        live=wait(lambda:(v:=night()) and v['state']=='active' and v,'Pearl active',timeout=20)
        (work/'pearl-active.json').write_text(json.dumps(live,indent=2))
        assert len(live['outputs'])==2 and all(o['state']=='committed' and o['committed_kelvin']==4000 for o in live['outputs']),live
        reply=subprocess.run([ctl,'night-light','off'],env=env,text=True,capture_output=True,timeout=5)
        assert reply.returncode==0,reply.stdout+reply.stderr
        wait(lambda:(v:=night()) and v['state']=='off','Pearl off after restoration')
        assert all(latest('other','state',i)['owner']==0 and latest('other','state',i)['committed']==6500 for i in range(2))
        subprocess.run([ctl,'night-light','on'],env=env,check=True,capture_output=True,timeout=5)
        wait(lambda:(v:=night()) and v['state']=='active','Pearl on')
        pearl.kill();pearl.wait()
        wait(lambda:all(latest('other','state',i)['owner']==0 and latest('other','state',i)['committed']==6500 for i in range(2)),'Pearl crash restoration')
        print('PASS Pearl saved policy, native per-output status, off/on and crash restoration',flush=True)
    (work/'result.json').write_text(json.dumps({'renderer':args.renderer,'status':'passed','physical_acceptance':False},indent=2))
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill();child.wait()
    for file in files: file.close()
