#!/usr/bin/env python3
"""Output keybindings warp the pointer in an isolated two-output compositor."""
import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))


def wait_for(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aqueous-output-focus-') as temporary:
    base = Path(temporary)
    protocols = {
        'xdg-shell': '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml',
        'xdg-activation': '/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml',
        'shortcuts': '/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
        'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
        'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
        'session-lock': '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',
        'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
        'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
        'pointer-constraints': '/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
    }
    generated = []
    for name, xml in protocols.items():
        subprocess.run(['wayland-scanner', 'client-header', str(xml), str(base / f'{name}-client-protocol.h')], check=True)
        code = base / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', str(xml), str(code)], check=True)
        generated.append(str(code))
    fixture = base / 'shell-client'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(base),
                    str(ROOT / 'scripts/fixtures/shell-client.c'), *generated,
                    '-lwayland-client', '-lxkbcommon', '-o', str(fixture)], check=True)

    for follows_mouse in (False, True):
        case = base / str(follows_mouse)
        runtime = case / 'runtime'
        runtime.mkdir(parents=True, mode=0o700)
        (case / 'config').mkdir()
        (case / 'home').mkdir()
        wm = case / 'wm.toml'
        wm.write_text((ROOT / 'scripts/fixtures/new-window-focus-on-wm.toml').read_text().replace(
            'focus_follows_mouse = false', f'focus_follows_mouse = {str(follows_mouse).lower()}') + '''
[keybinds]
focus_output_left = "Super+Ctrl+Left"
focus_output_right = "Super+Ctrl+Right"
move_to_output_left = "Super+Ctrl+Alt+Left"
move_to_output_right = "Super+Ctrl+Alt+Right"
''')
        env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(case / 'config'),
                   HOME=str(case / 'home'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                   WLR_RENDERER='pixman', AQUEOUS_CONFIG=str(wm))
        for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        children = []
        log = (case / 'compositor.log').open('w+')
        compositor = subprocess.Popen([str(BIN), '-no-xwayland', '-log-level', 'debug', '-c', 'true'],
                                      env=env, stdout=log, stderr=log)
        children.append(compositor)
        try:
            def ready():
                assert compositor.poll() is None, 'compositor exited'
                return next((p for p in runtime.glob('wayland-*') if p.is_socket()), None)
            env['WAYLAND_DISPLAY'] = wait_for(ready).name
            wait_for(lambda: (runtime / 'aqueous/outputd.sock').is_socket())

            def request(op, **kwargs):
                with socket.socket(socket.AF_UNIX) as client:
                    client.settimeout(5)
                    client.connect(str(runtime / 'aqueous/outputd.sock'))
                    client.sendall(json.dumps(dict(op=op, **kwargs)).encode() + b'\n')
                    with client.makefile('r') as response:
                        result = json.loads(response.readline())
                assert result['ok'], result
                return result

            def ctl(*args):
                return json.loads(subprocess.check_output([str(CTL), *args, '--json'], env=env, timeout=5))

            def records(kind):
                return [r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == kind]

            def probe(role):
                process = subprocess.Popen([str(fixture), role], env=env, stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=log, text=True)
                children.append(process)
                messages = queue.Queue()
                def read():
                    for line in process.stdout:
                        messages.put(line.strip())
                threading.Thread(target=read, daemon=True).start()
                expect(messages, 'ready')
                return process, messages

            def expect(messages, wanted):
                deadline = time.monotonic() + 5
                seen = []
                while time.monotonic() < deadline:
                    try:
                        line = messages.get(timeout=.1)
                        seen.append(line)
                        if line == wanted:
                            return
                    except queue.Empty:
                        pass
                raise AssertionError((wanted, seen))

            def send(process, command):
                process.stdin.write(command + '\n')
                process.stdin.flush()

            def center(output):
                box = output['bounds']
                return box['x'] + box['width'] // 2, box['y'] + box['height'] // 2

            def at_center(output):
                state = request('cursor_state')
                x, y = center(output)
                return abs(state['x'] - x) < .01 and abs(state['y'] - y) < .01

            def selected(output):
                return records('seat')[0]['output'] == output['id']

            inputs, _ = probe('input')
            def navigate(direction, output, move=False):
                send(inputs, f'chord {105 if direction == "left" else 106} {76 if move else 68}')
                wait_for(lambda: selected(output) and at_center(output))
                # Check subsequent manage cycles do not restore an old constraint/focus.
                time.sleep(.15)
                assert at_center(output)

            outputs = sorted(wait_for(lambda: records('output') if len(records('output')) == 2 else None), key=lambda o: o['name'])
            # Negative origins, gaps, fractional scaling and a rotated output.
            request('set', changes=[
                dict(name=outputs[0]['name'], scale=1.25, transform='normal', position=[-1200, -100]),
                dict(name=outputs[1]['name'], scale=1.5, transform='90', position=[200, 50]),
            ])
            left, right = sorted(records('output'), key=lambda o: o['bounds']['x'])
            ctl('workspace', 'activate', '--id', left['active_workspace'])
            navigate('right', right)
            assert records('seat')[0]['window'] is None
            navigate('left', left)
            navigate('right', right)
            # An edge press and a move without a focused window must not warp.
            before = request('cursor_state')
            send(inputs, 'chord 106 68')
            send(inputs, 'chord 105 76')
            time.sleep(.15)
            after = request('cursor_state')
            assert (before['x'], before['y']) == (after['x'], after['y'])
            assert selected(right)

            first, first_messages = probe('window')
            first_window = wait_for(lambda: next(iter(records('window')), None))
            assert first_window['output'] == right['id'], first_window
            wait_for(lambda: records('seat')[0]['window'] == first_window['id'])
            navigate('left', left, move=True)
            wait_for(lambda: records('window')[0]['output'] == left['id'])
            navigate('right', right, move=True)
            wait_for(lambda: records('window')[0]['output'] == right['id'])

            for kind in ('lock', 'confine'):
                send(first, 'pointer-' + kind)
                expect(first_messages, 'pointer ' + ('locked' if kind == 'lock' else 'confined'))
                navigate('left', left)
                expect(first_messages, 'pointer ' + ('unlocked' if kind == 'lock' else 'unconfined'))
                assert records('seat')[0]['window'] is None
                send(first, 'pointer-release')
                navigate('right', right)
                wait_for(lambda: records('seat')[0]['window'] == first_window['id'])
                # Moving a constrained window also changes its scene geometry;
                # constraint restoration must not overwrite the output warp.
                send(first, 'pointer-' + kind)
                expect(first_messages, 'pointer ' + ('locked' if kind == 'lock' else 'confined'))
                navigate('left', left, move=True)
                wait_for(lambda: records('window')[0]['output'] == left['id'])
                send(first, 'pointer-release')
                navigate('right', right, move=True)
                wait_for(lambda: records('window')[0]['output'] == right['id'])

            second, _ = probe('window')
            wait_for(lambda: len(records('window')) == 2)
            x, y = center(right)
            def away_from_center(window):
                g = window['geometry']
                return not (g['x'] <= x < g['x'] + g['width'] and g['y'] <= y < g['y'] + g['height'])
            remembered = wait_for(lambda: next((w for w in records('window') if w['visible'] and away_from_center(w)), None))
            ctl('window', 'activate', '--id', remembered['id'])
            wait_for(lambda: records('seat')[0]['window'] == remembered['id'])
            navigate('left', left)
            navigate('right', right)
            assert records('seat')[0]['window'] == remembered['id'], 'warp stole keyboard focus'
            print(f'PASS: output warps, empty outputs, placement, window moves, constraints and focus history (focus_follows_mouse={follows_mouse})', flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-16000:])
            raise
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
            for child in reversed(children):
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            log.close()
