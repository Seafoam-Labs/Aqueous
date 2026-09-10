#!/usr/bin/env python3
"""Exercise xdg-toplevel-drag against an isolated compositor and real DnD clients.

Build with -Dtoplevel-drag-testing=true for the required touch scenarios.
"""
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
    parser.add_argument('--external-policy-only', action='store_true', help='Check the global is hidden in legacy external WM mode')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-toplevel-drag-'))
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

    def press(id=0):
        focus(id)
        g = window(id)['geometry']
        command(f'move {g["x"] + 30} {g["y"] + 20}')
        before = len(events('source', 'press'))
        command('press')
        wait(lambda: len(events('source', 'press')) > before, 'no valid pointer serial')

    def at(x, y, id=0):
        return (w := window(id)) and abs(w['geometry']['x'] - x) <= 2 and abs(w['geometry']['y'] - y) <= 2

    def request(**payload):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(str(work / 'runtime/aqueous/outputd.sock'))
            sock.sendall((json.dumps(payload) + '\n').encode())
            with sock.makefile('r') as stream:
                reply = json.loads(stream.readline())
            assert reply.get('ok'), reply
            return reply

    def move_global(x, y):
        position = request(op='cursor_state')
        command(f'relative {round(x-position["x"])} {round(y-position["y"])}')

    def touch(action, x=200, y=150, id=0, device=0):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(str(work / 'runtime/aqueous/outputd.sock'))
            sock.sendall((json.dumps(dict(op='test_toplevel_drag_touch', action=action, device=device,
                                        x=x/1280, y=y/720, id=id)) + '\n').encode())
            reply = json.loads(sock.recv(4096))
            assert reply.get('ok'), f'touch injection requires -Dtoplevel-drag-testing=true: {reply}'

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-toplevel-drag': protocols / 'staging/xdg-toplevel-drag/xdg-toplevel-drag-v1.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-toplevel-drag.c', *generated,
             '-lwayland-client', '-o', work / 'client'])
        shell_generated = [generated[0]]
        for name, xml in {
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': protocols / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': protocols / 'staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
            'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
            'pointer-constraints': protocols / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            shell_generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/shell-client.c',
             *shell_generated, '-lwayland-client', '-lxkbcommon', '-o', work / 'shell-client'])
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        for name in ('home', 'config', 'cache', 'state'):
            (work / name).mkdir()
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\n')
        (work / 'outputs.toml').write_text('[[output]]\nname = "HEADLESS-2"\nenabled = false\n')
        (work / 'layout.toml').write_text('[layout.options.float]\nresistance = 0\nsnap_threshold = 0\n')
        (work / 'rules.toml').write_text('''[[window]]
app_id = "source-3"
fixed_position = true
floating = true
x = 100
y = 100
width = 320
height = 240
[[window]]
app_id = "source-4"
floating = false
[[window]]
app_id = "second-*"
floating = true
x = 200
y = 450
width = 240
height = 180
[[window]]
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
width = 500
height = 400
''')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-policy',
                             'external' if args.external_policy_only else 'internal', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        if args.external_policy_only:
            probe = launch([work / 'client', 'probe-absent'], 'probe')
            assert probe.wait(timeout=5) == 0
            assert 'unavailable' in (work / 'probe.jsonl').read_text()
            print('PASS external WM mode leaves toplevel-drag unadvertised', flush=True)
            return
        client('source')
        client('target')
        create(label='target')
        create()
        command('sandbox')
        display = env['WAYLAND_DISPLAY']
        env['WAYLAND_DISPLAY'] = 'drag-sandbox'
        client('sandbox')
        command('quit', 'sandbox', error=True)
        env['WAYLAND_DISPLAY'] = display

        # Existing attached window covers the pointer but target still receives DnD.
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0 0 1')
        before = len(events('target', 'enter'))
        command('move 650 300')
        wait(lambda: at(620, 280), 'attached window did not follow pointer')
        wait(lambda: len(events('target', 'enter')) > before, 'dragged window blocked target')
        command('release')
        wait(lambda: events('source', 'dropped'), 'no drop event')
        wait(lambda: events('source', 'sent'), 'MIME transfer did not run')
        assert not events('source', 'finished'), 'transfer finished before target requested it'
        command('destroy-drag')
        geometry = window()['geometry']
        command('move 850 450')
        assert window()['geometry'] == geometry, 'window still moving after drop'
        command('finish', 'target')
        wait(lambda: events('source', 'finished'), 'no transfer completion')
        command('destroy-source')
        command('destroy-icon')
        print('PASS pointer movement, drag icon, underlying target, MIME transfer, drop before finish', flush=True)

        # Attach during an active operation, before mapping, then replace it.
        press()
        command('prepare')
        command('start 0')
        create(1, delay=1)
        command('attach 1 30 20')
        command('move 700 350')
        command('map 1')
        wait(lambda: at(670, 330, 1), 'unmapped attachment not positioned on map')
        command('unmap 1')
        create(2, delay=1, inset=8)
        command('attach 2 30 20')
        command('map 2')
        command('move 750 400')
        wait(lambda: at(720, 380, 2), 'replacement attachment/geometry offset failed')
        before = len(events('source', 'cancelled'))
        command('move 30 650')
        command('release')
        wait(lambda: len(events('source', 'cancelled')) > before, 'empty-space release did not cancel')
        command('destroy-drag')
        command('destroy-source')
        command('destroy-top 1')
        command('destroy-top 2')
        print('PASS late attachment, map, detach/replace, geometry inset, cancellation', flush=True)

        # Real touch serial and focus transfer to another client.
        touch('add')
        focus()
        g = window()['geometry']
        before = len(events('source', 'touch'))
        touch('down', g['x'] + 30, g['y'] + 20)
        wait(lambda: len(events('source', 'touch')) > before, 'no touch serial')
        command('prepare')
        command('attach 0 30 20')
        enters = len(events('source', 'enter'))
        before = len(events('target', 'enter'))
        command('start 0')
        assert len(events('source', 'enter')) == enters, 'touch origin became a drag target'
        touch('motion', 700, 350)
        wait(lambda: at(670, 330), 'touch did not move window')
        wait(lambda: len(events('target', 'enter')) > before, 'touch did not enter target')
        geometry = window()['geometry']
        touch('down', 100, 600, id=1)
        touch('motion', 200, 650, id=1)
        assert window()['geometry'] == geometry, 'secondary touch moved window'
        touch('up', id=1)
        before = len(events('source', 'dropped'))
        touch('up')
        wait(lambda: len(events('source', 'dropped')) > before, 'touch drop failed')
        wait(lambda: len(events('source', 'sent')) >= 2, 'touch transfer missing')
        command('finish', 'target')
        command('destroy-drag')
        command('destroy-source')
        print('PASS touch movement, target focus, secondary touch isolation, transfer', flush=True)

        # Ordinary DnD continues to transfer data without moving its origin.
        press()
        command('prepare 1')
        command('start 0')
        geometry = window()['geometry']
        dropped = len(events('source', 'dropped'))
        sent = len(events('source', 'sent'))
        command('move 950 250')
        assert window()['geometry'] == geometry
        command('release')
        wait(lambda: len(events('source', 'dropped')) > dropped, 'ordinary DnD drop failed')
        wait(lambda: len(events('source', 'sent')) > sent, 'ordinary transfer failed')
        command('finish', 'target')
        command('destroy-source')

        # A mapped attachment may disappear and return, but needs a new attach.
        press()
        command('prepare')
        command('start 0')
        create(5)
        command('attach 5 30 20')
        command('move 700 350')
        wait(lambda: at(670, 330, 5), 'initial attachment failed')
        command('unmap 5')
        wait(lambda: window(5) is None, 'unmap not observed')
        command('remap 5')
        wait(lambda: window(5), 'window failed to remap')
        geometry = window(5)['geometry']
        command('move 850 400')
        assert window(5)['geometry'] == geometry, 'remap silently reattached window'
        command('attach 5 30 20')
        wait(lambda: at(820, 380, 5), 'explicit reattach failed')
        command('destroy-top 5')
        command('destroy-source')
        command('destroy-drag')
        command('release')

        # Existing move restrictions apply while DnD itself remains usable.
        create(3)
        create(4)
        ctl('layout', '--output', 'HEADLESS-1', '--set', 'tile')
        for id in (3, 4):
            press(id)
            command('prepare')
            command(f'attach {id} 30 20')
            command(f'start {id}')
            geometry = window(id)['geometry']
            command('move 1000 600')
            assert window(id)['geometry'] == geometry, f'window {id} violated move policy'
            command('destroy-source')
            command('destroy-drag')
            command('release')
        command('destroy-top 3')
        command('destroy-top 4')
        ctl('layout', '--output', 'HEADLESS-1', '--set', 'floating')

        command('maximize 0 1')
        wait(lambda: 'maximized' in window()['states'], 'maximize failed')
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        command('move 500 300')
        wait(lambda: at(470, 280) and 'maximized' not in window()['states'], 'maximized move restore failed')
        command('destroy-source')
        command('destroy-drag')
        command('release')

        command('fullscreen 0 1')
        wait(lambda: 'fullscreen' in window()['states'], 'fullscreen setup failed')
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        geometry = window()['geometry']
        command('move 800 300')
        assert window()['geometry'] == geometry, 'fullscreen window moved'
        command('destroy-source')
        command('destroy-drag')
        command('release')
        command('fullscreen 0 0')
        wait(lambda: 'fullscreen' not in window()['states'], 'fullscreen exit failed')

        # A target that declines the MIME type cancels rather than completing a drop.
        command('accept 0', 'target')
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        before = len(events('source', 'cancelled'))
        command('move 900 300')
        command('release')
        wait(lambda: len(events('source', 'cancelled')) > before, 'rejected target did not cancel')
        command('destroy-drag')
        command('destroy-source')
        command('accept 1', 'target')

        # Touch cancellation must terminate the source, without destroying a window.
        focus()
        g = window()['geometry']
        before = len(events('source', 'touch'))
        touch('down', g['x'] + 30, g['y'] + 20)
        wait(lambda: len(events('source', 'touch')) > before, 'touch cancel setup failed')
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        before = len(events('source', 'cancelled'))
        touch('cancel')
        wait(lambda: len(events('source', 'cancelled')) > before, 'touch cancellation did not end source')
        command('destroy-drag')
        command('destroy-source')
        print('PASS ordinary DnD, remap/reattach, attached destruction, fixed/tiled policy, maximized restore, fullscreen, rejected drop, touch cancellation', flush=True)

        # Source-less touch drags must not dereference a missing data source.
        focus()
        g = window()['geometry']
        before = len(events('source', 'touch'))
        touch('down', g['x'] + 30, g['y'] + 20)
        wait(lambda: len(events('source', 'touch')) > before, 'source-less touch setup failed')
        command('prepare 2')
        command('start 0')
        touch('motion', g['x'] + 50, g['y'] + 30)
        touch('up')

        # Cross a fractional-scale output at negative logical coordinates.
        request(op='set', changes=[{'name': 'HEADLESS-2', 'enabled': True,
                                   'scale': 1.25, 'position': [-1024, 0]}])
        focus()
        g = window()['geometry']
        move_global(g['x'] + 30, g['y'] + 20)
        before = len(events('source', 'press'))
        command('press')
        wait(lambda: len(events('source', 'press')) > before, 'multi-output press failed')
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        move_global(-500, 250)
        wait(lambda: at(-530, 230) and window()['output'] == 'HEADLESS-2',
             'fractional-scale/negative-coordinate output transfer failed')
        request(op='set', changes=[{'name': 'HEADLESS-2', 'enabled': False}])
        wait(lambda: window()['output'] == 'HEADLESS-1', 'removed output did not recover window')
        command('destroy-source')
        command('destroy-drag')
        command('release')
        print('PASS source-less touch, fractional scale, negative coordinates, output transfer/removal', flush=True)

        # Independent seats own independent movement records and input grabs.
        touch('add', device=1)
        env['DRAG_TEST_SEAT'] = 'drag-second'
        client('second')
        env.pop('DRAG_TEST_SEAT')
        create(label='second')
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        command('move 700 250')
        wait(lambda: at(670, 230), 'default seat drag did not move aside')
        second = window(label='second')['geometry']
        touch('down', second['x'] + 80, second['y'] + 60, device=1)
        wait(lambda: events('second', 'touch'), 'second seat did not receive serial')
        command('prepare', 'second')
        command('attach 0 30 20', 'second')
        command('start 0', 'second')
        command('move 700 250')
        wait(lambda: at(670, 230), 'default seat drag stopped')
        geometry = window()['geometry']
        touch('motion', 350, 550, device=1)
        wait(lambda: (w := window(label='second')) and w['geometry']['x'] == 320 and
             w['geometry']['y'] == 530, 'second seat drag stopped')
        assert window()['geometry'] == geometry, 'second seat moved default seat window'
        touch('remove-seat', device=1)
        wait(lambda: events('second', 'cancelled'), 'seat destruction failed to cancel drag')
        command('destroy-drag', 'second')
        command('quit', 'second', error=True)
        command('move 800 300')
        wait(lambda: at(770, 280), 'second seat destruction broke default drag')
        command('destroy-source')
        command('destroy-drag')
        command('release')
        print('PASS simultaneous seats and seat destruction', flush=True)

        # Session lock interrupts the protocol drag before exposing lock input.
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        before = len(events('source', 'cancelled'))
        locker = launch([work / 'shell-client', 'lock'], 'locker')
        wait(lambda: 'locked' in (work / 'locker.jsonl').read_text().splitlines(), 'session did not lock')
        wait(lambda: len(events('source', 'cancelled')) > before, 'lock did not cancel toplevel drag')
        command('destroy-drag')
        command('destroy-source')
        command('release')
        locker.stdin.write(b'unlock\n')
        locker.stdin.flush()
        assert locker.wait(timeout=5) == 0

        # Drop can precede grab teardown when a second pointer button is held.
        # Lock must not cancel the transfer once dnd_drop_performed was sent.
        press()
        command('prepare')
        command('attach 0 30 20')
        command('start 0')
        command('button 273 1')
        command('move 900 300')
        dropped = len(events('source', 'dropped'))
        sent = len(events('source', 'sent'))
        cancelled = len(events('source', 'cancelled'))
        command('release')
        wait(lambda: len(events('source', 'dropped')) > dropped, 'held-button drop failed')
        wait(lambda: len(events('source', 'sent')) > sent, 'held-button transfer missing')
        locker = launch([work / 'shell-client', 'lock'], 'post-drop-locker')
        wait(lambda: 'locked' in (work / 'post-drop-locker.jsonl').read_text().splitlines(), 'post-drop lock failed')
        assert len(events('source', 'cancelled')) == cancelled, 'lock cancelled an already dropped source'
        command('finish', 'target')
        command('destroy-drag')
        locker.stdin.write(b'unlock\n')
        locker.stdin.flush()
        assert locker.wait(timeout=5) == 0
        command('button 273 0')
        command('destroy-source')

        # Client exit during an active drag releases all compositor references.
        client('disconnect')
        create(label='disconnect')
        ctl('window', 'activate', '--id', str(window(label='disconnect')['id']))
        g = window(label='disconnect')['geometry']
        command(f'move {g["x"] + 30} {g["y"] + 20}', 'disconnect')
        command('press', 'disconnect')
        wait(lambda: events('disconnect', 'press'), 'disconnect drag setup failed')
        command('prepare', 'disconnect')
        command('attach 0 30 20', 'disconnect')
        command('start 0', 'disconnect')
        command('quit', 'disconnect', error=True)
        wait(lambda: window(label='disconnect') is None, 'disconnected window remained')
        command('release')
        print('PASS session lock, transfer after drop with held button, and client disconnect during drag', flush=True)

        # Fatal errors run in separate clients so every case also checks survival.
        for label, commands, interface, code in [
            ('duplicate', ['prepare', 'duplicate'], 'xdg_toplevel_drag_manager_v1', 0),
            ('selection', ['prepare', 'selection'], 'xdg_toplevel_drag_manager_v1', 0),
            ('used-selection', ['prepare 1', 'selection', 'duplicate'], 'xdg_toplevel_drag_manager_v1', 0),
            ('premature', ['prepare', 'destroy-ongoing'], 'xdg_toplevel_drag_v1', 1),
            ('attached', ['create 0', 'create 1', 'prepare', 'attach 0 0 0', 'attach 1 0 0'], 'xdg_toplevel_drag_v1', 0),
        ]:
            client(label)
            for value in commands[:-1]:
                command(value, label)
            command(commands[-1], label, error=True)
            error = wait(lambda: events(label, 'error'), f'{label}: expected protocol error')[-1]
            assert error['code'] == code, error
            assert error['interface'] == interface, error
        # Invalid serial cancels; manager destruction does not kill children.
        press()
        command('prepare')
        command('attach 0 30 20')
        command('destroy-manager')
        geometry = window()['geometry']
        before = len(events('source', 'cancelled'))
        command('start 0 1')
        wait(lambda: len(events('source', 'cancelled')) > before, 'invalid serial did not cancel source')
        command('destroy-drag')
        command('move 900 500')
        command('release')
        assert window()['geometry'] == geometry
        print('PASS protocol errors, invalid serial, manager lifetime, sandbox visibility', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
        for child in reversed(children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
