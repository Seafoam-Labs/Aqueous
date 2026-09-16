#!/usr/bin/env python3
"""Negative output origins: config reload, output management, X11 clicks/popups."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))


def wait_for(check):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('timed out waiting for ' + repr(check))


with tempfile.TemporaryDirectory(prefix='aqueous-negative-position-') as tmp:
    base = Path(tmp)
    fixture = base / 'x11-client'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror',
                    str(ROOT / 'scripts/fixtures/xwayland-negative-position.c'),
                    '-o', str(fixture), '-lX11'], check=True)
    for mode in ('legacy', 'native'):
        case = base / mode
        case.mkdir()
        for name in ('runtime', 'config', 'home', 'state'):
            (case / name).mkdir(mode=0o700)
        runtime = case / 'runtime'
        wm = case / 'wm.toml'
        initial = (ROOT / 'scripts/fixtures/new-window-focus-on-wm.toml').read_text()
        wm.write_text(initial + '''
[[output]]
name = "HEADLESS-1"
position = [0, 0]
[[output]]
name = "HEADLESS-2"
transform = "90"
scale = 1.25
position = [1280, -200]
''')
        env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(case / 'config'),
                   XDG_STATE_HOME=str(case / 'state'), HOME=str(case / 'home'),
                   AQUEOUS_CONFIG=str(wm), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                   WLR_RENDERER='pixman')
        for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        log = (case / 'compositor.log').open('w+')
        client_log = case / 'client.log'
        display_file = case / 'display'
        process = subprocess.Popen([str(BIN), '-policy', 'internal', '-log-level', 'debug',
                                    '-xwayland-scaling', mode, '-c',
                                    f'echo "$DISPLAY" > {display_file}'],
                                   env=env, stdout=log, stderr=log)
        client = None
        try:
            wait_for(lambda: (runtime / 'aqueous/outputd.sock').exists())
            env['WAYLAND_DISPLAY'] = wait_for(lambda: next(
                (p.name for p in runtime.glob('wayland-*') if p.is_socket()), None))
            env['DISPLAY'] = wait_for(lambda: display_file.read_text().strip()
                                     if display_file.exists() else None)

            def request(op, **fields):
                with socket.socket(socket.AF_UNIX) as s:
                    s.settimeout(5)
                    s.connect(str(runtime / 'aqueous/outputd.sock'))
                    s.sendall(json.dumps(dict(op=op, **fields)).encode() + b'\n')
                    with s.makefile() as reader:
                        return json.loads(reader.readline())

            def ctl(*args):
                return json.loads(subprocess.check_output([str(CTL), *args, '--json'], env=env))

            outputs = sorted(wait_for(lambda: request('list')['outputs']), key=lambda o: o['name'])
            first, second = [o['name'] for o in outputs]
            assert (outputs[1]['x'], outputs[1]['y'], outputs[1]['transform']) == (1280, -200, '90'), outputs
            with client_log.open('w') as out:
                client = subprocess.Popen([str(fixture)], env=env, stdout=out, stderr=out)
            window = wait_for(lambda: next(iter(ctl('windows')), None))
            ctl('window', 'move', '--id', window['id'], '--output', second)

            # Reload a second output block with a negative Y and a rotation.
            # The existing X11 window must be reconfigured to the new origin.
            wm.write_text(initial + f'''
[[output]]
name = "{first}"
position = [0, 0]
[[output]]
name = "{second}"
transform = "90"
scale = 1.25
position = [1280, -400]
''')

            def second_at(x, y):
                return next((o for o in request('list')['outputs'] if o['name'] == second
                             and (o['x'], o['y']) == (x, y) and o['transform'] == '90'), None)

            wait_for(lambda: second_at(1280, -400))

            def click_window():
                target = next(o for o in request('list')['outputs'] if o['name'] == second)
                win = wait_for(lambda: next((w for w in ctl('windows') if w['output'] == second
                    and (w['geometry']['x'], w['geometry']['y']) == (target['x'], target['y'])), None))
                box = win['geometry']
                assert box['y'] < 0
                target_x, target_y = box['x'] + 80, box['y'] + 80
                cursor = request('cursor_state')
                subprocess.run(['wlrctl', 'pointer', 'move', str(target_x - cursor['x']),
                                str(target_y - cursor['y'])], env=env, check=True)
                before = client_log.read_text().count('click ')
                subprocess.run(['wlrctl', 'pointer', 'click', 'right'], env=env, check=True)
                wait_for(lambda: client_log.read_text().count('click ') > before)
                click = [line for line in client_log.read_text().splitlines() if line.startswith('click ')][-1].split()
                expected_local = 100 if mode == 'native' else 80
                assert abs(int(click[1]) - expected_local) <= 1 and abs(int(click[2]) - expected_local) <= 1, click
                assert int(click[4]) >= 0 and int(click[5]) >= 0, click
                wait_for(lambda: client_log.read_text().count('popup-mapped') > before)
                time.sleep(.1)
                subprocess.run(['wlrctl', 'pointer', 'move', '30', '30'], env=env, check=True)
                subprocess.run(['wlrctl', 'pointer', 'click', 'left'], env=env, check=True)
                wait_for(lambda: client_log.read_text().count('popup-click') > before)

            click_window()
            # Exercise the separate wlr-output-management apply path with both
            # negative axes; the negative logical geometry must remain visible.
            subprocess.run(['wlr-randr', '--output', second, '--pos=-720,-400'], env=env, check=True)
            wait_for(lambda: second_at(-720, -400))
            click_window()
            # Moving another output changes the shared X11 origin even though
            # the tested output stays in place.
            subprocess.run(['wlr-randr', '--output', first, '--pos=-1600,-800'], env=env, check=True)
            click_window()
            # A negative position may still make the translated desktop too
            # large for X11. Reject that transaction and retain the last state.
            rejected = request('set', changes=[dict(name=second, position=[-40000, -400])])
            assert not rejected['ok'] and rejected['rejected'] == 1, rejected
            assert second_at(-720, -400)
            assert process.poll() is None
            print(f'PASS {mode}: negative startup/reload, rotation, output management, X11 clicks/popups and bounds', flush=True)
        except BaseException:
            log.flush()
            print((case / 'compositor.log').read_text()[-14000:])
            if client_log.exists():
                print(client_log.read_text())
            raise
        finally:
            for child in (client, process):
                if child is None:
                    continue
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            log.close()
