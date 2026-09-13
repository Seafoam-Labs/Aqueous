#!/usr/bin/env python3
"""Exercise pointer-warp with real clients in an isolated headless compositor."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--policy', choices=('internal', 'external', 'compare'), default='internal')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-pointer-warp-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    clients = {}
    compositor = None

    def run(command):
        try:
            return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                           stderr=subprocess.STDOUT, timeout=30)
        except subprocess.CalledProcessError as error:
            print(error.output, flush=True)
            raise

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, description):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, f'compositor exited: {(work / "compositor.log").read_text()[-3000:]}'
            value = predicate()
            if value:
                return value
            time.sleep(.02)
        raise AssertionError(f'{description}; windows={ctl("windows")}')

    def events(label, kind):
        result = []
        for line in (work / f'{label}.jsonl').read_text().splitlines():
            try:
                value = json.loads(line)
                if value.get('event') == kind:
                    result.append(value)
            except ValueError:
                pass
        return result

    def command(value, label='source', error=False):
        child = clients[label]
        before = len(events(label, 'command'))
        child.stdin.write((value + '\n').encode())
        child.stdin.flush()
        if not error:
            wait(lambda: len(events(label, 'command')) > before, f'{label}: command {value}')

    def client(label):
        clients[label] = launch([work / 'client', label], label)
        wait(lambda: events(label, 'ready'), f'{label} not ready')
        assert events(label, 'global') == [{'event': 'global', 'version': 1}]

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(id=0, label='source'):
        return next((w for w in ctl('windows') if w.get('app_id') == f'{label}-{id}'), None)

    def create(id=0, label='source', delay=0, inset=0):
        command(f'create {id} {delay} {inset}', label)
        if not delay:
            wait(lambda: window(id, label), f'{label}-{id} did not map')

    def focus(id=0, label='source'):
        ctl('window', 'activate', '--id', str(window(id, label)['id']), '--seat', 'default')

    def request(**payload):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(str(work / 'runtime/aqueous/outputd.sock'))
            sock.sendall((json.dumps(payload) + '\n').encode())
            with sock.makefile('r') as stream:
                reply = json.loads(stream.readline())
            assert reply.get('ok'), reply
            return reply

    def position():
        p = request(op='cursor_state')
        return p['x'], p['y']

    def move(x, y):
        px, py = position()
        command(f'relative {round(x-px)} {round(y-py)}')
        wait(lambda: abs(position()[0]-x)<1 and abs(position()[1]-y)<1, 'physical move')

    def point(id=0, x=30, y=20, label='source'):
        focus(id, label)
        g = window(id, label)['geometry']
        move(g['x']+x, g['y']+y)
        wait(lambda: events(label, 'enter') and events(label, 'enter')[-1]['id']==id, 'pointer focus')

    def warp(id, x, y, serial='enter', pointer=0, label='source', accept=True):
        before = position()
        motion = len(events(label, 'motion'))
        frame = len(events(label, 'frame'))
        relative = len(events(label, 'relative'))
        snapshot = ctl('shell', 'snapshot')
        focus_before = [(r['id'], r.get('window')) for r in snapshot['upsert'] if r['kind']=='seat']
        command(f'warp {id} {x} {y} {serial} {pointer}', label)
        if accept:
            wait(lambda: len(events(label, 'motion'))>motion, 'warp motion')
            m = events(label, 'motion')[-1]
            assert abs(m['x']-x)<.005 and abs(m['y']-y)<.005, m
            assert len(events(label, 'frame'))>frame, 'missing protocol-only frame'
        else:
            assert position()==before, (before, position())
            assert len(events(label, 'motion'))==motion, 'rejected warp sent motion'
        assert len(events(label, 'relative'))==relative, 'warp synthesized relative motion'
        after = ctl('shell', 'snapshot')
        assert [(r['id'], r.get('window')) for r in after['upsert'] if r['kind']=='seat']==focus_before

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'pointer-warp': protocols / 'staging/pointer-warp/pointer-warp-v1.xml',
            'pointer-constraints': protocols / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
            'relative-pointer': protocols / 'unstable/relative-pointer/relative-pointer-unstable-v1.xml',
            'aqueous-input': ROOT / 'protocol/aqueous-input-management-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'aqueous-window-management-v1': ROOT / 'protocol/aqueous-window-management-v1.xml',
            'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
            'viewporter': protocols / 'stable/viewporter/viewporter.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        flags = run(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon']).split()
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/pointer-warp.c', *generated, *flags, '-o', work / 'client'])
        policy_codes = [work / 'aqueous-window-management-v1.c', work / 'ext-workspace.c']
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/pointer-warp-policy.c', *policy_codes, *flags, '-o', work / 'policy'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/exit-session.c', *policy_codes, *flags, '-o', work / 'exit-session'])
        shell_generated = [work / 'xdg-shell.c', work / 'pointer-constraints.c', work / 'virtual-keyboard.c', work / 'ext-workspace.c']
        for name, xml in {
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': protocols / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': protocols / 'staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            shell_generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/shell-client.c',
             *shell_generated, *flags, '-o', work / 'shell-client'])
        runtime = work / 'runtime'
        for name in ('runtime', 'home', 'config', 'cache', 'state'):
            (work / name).mkdir(mode=0o700)
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\n')
        (work / 'outputs.toml').write_text('[[output]]\nname = "HEADLESS-2"\nenabled = false\n')
        (work / 'rules.toml').write_text('''[[window]]
app_id = "source-*"
floating = true
x = 100
y = 100
width = 320
height = 240
[[window]]
app_id = "target-*"
floating = true
x = 550
y = 150
width = 400
height = 300
''')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-policy', args.policy, '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        if args.policy != 'internal':
            policy = launch([work / 'policy'], 'policy')
            client('source')
            create()
            move(130, 120)
            wait(lambda: events('source', 'enter'), 'external policy pointer focus')
            warp(0,60.25,70.5)
            assert position()==(160.25,170.5), position()
            warp(0,-1,20,accept=False)
            command('press')
            warp(0,80,90)
            command('release')
            command('quit',error=True)
            wait(lambda: not window(), 'external window destruction')
            policy.terminate()
            policy.wait(timeout=5)
            run([work / 'exit-session'])
            assert compositor.wait(timeout=10)==0
            print(f'PASS {args.policy} policy registry, surface coordinates, bounds, implicit grab and teardown', flush=True)
            return
        client('source')
        client('target')
        create(label='target')
        create()
        point()
        g = window()['geometry']
        warp(0, 60.25, 40.75)
        assert position()==(g['x']+60.25, g['y']+40.75), position()
        for x,y in [(0,0),(319+255/256,0),(0,239+255/256),(319+255/256,239+255/256)]:
            warp(0,x,y)
        for x,y in [(-1/256,20),(20,-1/256),(320,20),(20,240),(8388607,20)]:
            warp(0,x,y,accept=False)
        for serial in ['0','4294967295']:
            warp(0,50,50,serial,accept=False)
        command('save')
        command('pointer')
        warp(0,52,53,'saved',0)
        warp(0,54,55,'enter',1)
        command('create-seat')
        wait(lambda: events('source','second-seat'), 'second seat pointer capability')
        warp(0,70,80,'saved',7,accept=False)
        command('destroy-seat')
        warp(0,70,80,'saved',7,accept=False) # now an inert pointer resource
        command('rebind')
        warp(0,56,57,'saved',0)
        print('PASS registry, fractions/edges, invalid serials/bounds, late pointer binding and manager lifecycle', flush=True)

        # A retained enter from another surface of this client is valid.
        create(1)
        point(1)
        warp(1,60,70,'saved')
        warp(0,60,70,'saved',accept=False)
        point(label='target')
        foreign=events('target','enter')[-1]['serial']
        warp(1,70,80,'saved',accept=False)
        point(1)
        warp(1,70,80,str(foreign),accept=False)
        command('press')
        wait(lambda: events('source','button')[-1]['state']==1, 'button press')
        warp(1,90,90,'button',accept=False)
        warp(1,100.5,110.25)
        before = position()
        command('relative 5 6')
        wait(lambda: position()==(before[0]+5,before[1]+6), 'motion after grabbed warp')
        m=events('source','motion')[-1]
        assert abs(m['x']-105.5)<.01 and abs(m['y']-116.25)<.01, m
        command('release')
        command('destroy 1')
        point()
        print('PASS cross-surface enter provenance, unfocused targets, implicit grab and subsequent motion', flush=True)

        command('press')
        create(1) # this new window occludes the grabbed source
        warp(0,50,60)
        command('release')
        command('destroy 1')
        point()
        command('press')
        command('drag 0')
        warp(0,80,80,accept=False)
        command('release')
        command('end-drag')
        point()
        ctl('overview','show','--output',window()['output'])
        warp(0,80,80,accept=False)
        ctl('overview','hide')
        point()
        locker=launch([work / 'shell-client','lock'],'locker')
        wait(lambda: 'locked' in (work / 'locker.jsonl').read_text(), 'session lock')
        warp(0,80,80,accept=False)
        locker.stdin.write(b'unlock\n')
        locker.stdin.flush()
        assert locker.wait(timeout=5)==0
        point()
        command('keyboard')
        wait(lambda: events('source','keyboard') and events('source','keyboard')[-1]['serial']>0, 'keyboard enter serial')
        point()
        warp(0,80,80,'keyboard',accept=False)
        command('lock 0')
        wait(lambda: events('source','locked'), 'pointer lock')
        warp(0,80,80,accept=False)
        command('unconstrain')
        time.sleep(.06) # let the existing pointer-lock transition guard expire
        point()
        command('confine 0 80 100')
        wait(lambda: events('source','confined'), 'pointer confinement')
        warp(0,60,60)
        warp(0,90,60,accept=False)
        warp(0,150,60,accept=False) # endpoint in disconnected rectangle
        assert not events('source','unconfined')
        command('unconstrain')
        time.sleep(.06) # let the existing pointer-lock transition guard expire
        point()
        command('input 0 80 100')
        warp(0,150,150,accept=False)
        command('press')
        warp(0,150,150) # input holes do not terminate an implicit grab
        command('release')
        command('input 0 320 240')
        point()
        command('child 2 0 120')
        warp(0,130,130,accept=False) # child owns the destination
        g=window()['geometry']
        move(g['x']+140,g['y']+140)
        wait(lambda: events('source','enter')[-1]['id']==2, 'subsurface focus')
        warp(2,30.25,40.5)
        assert position()==(g['x']+150.25,g['y']+160.5)
        command('destroy 2')
        point()
        command('child 2 0 20')
        move(g['x']+25,g['y']+25)
        wait(lambda: events('source','enter')[-1]['id']==2, 'child focus for ancestor constraint')
        command('confine 0 80 100')
        warp(2,30,30)
        warp(2,70,30,accept=False)
        command('unconstrain')
        command('destroy 2')
        point()
        command('popup 3 0')
        wait(lambda: events('source','popup'), 'popup map')
        popup=events('source','popup')[-1]
        move(g['x']+popup['x']+10,g['y']+popup['y']+10)
        wait(lambda: events('source','enter')[-1]['id']==3, 'popup focus')
        warp(3,30.25,40.5)
        assert position()==(g['x']+popup['x']+30.25,g['y']+popup['y']+40.5)
        command('destroy 3')
        point()
        for scale,transform in [(2,0),(2,1),(1,3),(1,0)]:
            command(f'scale 0 {scale} {transform}')
            warp(0,60.25,70.5)
            warp(0,61.25,71.5)
        command('viewport 0 160 120')
        warp(0,90.25,80.5)
        print('PASS locks, path-sensitive confinement, input holes, subsurfaces, buffer scale/transform and viewport', flush=True)

        command('unmap 0')
        wait(lambda: not window(), 'unmap')
        warp(0,40,40,accept=False)
        command('destroy 0')
        create()
        point()
        command('sandbox')
        display=env['WAYLAND_DISPLAY']
        env['WAYLAND_DISPLAY']='warp-sandbox'
        client('sandbox')
        env['WAYLAND_DISPLAY']=display
        create(label='sandbox')
        point(label='sandbox')
        warp(0,80,90,label='sandbox')
        command('quit','sandbox',error=True)
        wait(lambda: not window(label='sandbox'), 'sandbox disconnect')
        point()
        for i in range(50):
            warp(0,40+i/4,60+i/4)
        print('PASS unmap/destruction, security-context warp and repeated requests', flush=True)
        # Nonzero xdg geometry is surface-local, not the window's origin.
        command('destroy 0')
        create(0,inset=8)
        point()
        g=window()['geometry']
        warp(0,60.25,70.5)
        assert position()==(g['x']-8+60.25,g['y']-8+70.5)
        # Reconfigure the live output with a negative origin, fractional scale
        # and rotation; the surface-local request must still round-trip.
        command('press')
        request(op='set',changes=[dict(name='HEADLESS-1',scale=1.25,transform='90',position=[-500,-100])])
        warp(0,80.25,90.5,accept=False) # mapped surface point is off every output
        command('release')
        request(op='set',changes=[dict(name='HEADLESS-1',scale=1.25,transform='90',position=[-100,-100])])
        point()
        warp(0,80.25,90.5)
        warp(0,81.25,91.5)
        print('PASS lock/overview/DnD isolation, ancestor confinement, popups, geometry inset and transformed fractional output', flush=True)
        command('quit',error=True)
        command('quit','target',error=True)
        compositor.terminate()
        assert compositor.wait(timeout=10)==0
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
