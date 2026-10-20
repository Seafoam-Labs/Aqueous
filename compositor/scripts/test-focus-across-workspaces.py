#!/usr/bin/env python3
"""Directional focus continues across workspaces in an isolated compositor."""
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))
KEY_H, KEY_L, SUPER = 35, 38, 64


def wait_for(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aqueous-focus-workspaces-') as temporary:
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

    for crosses in (True, False):
        case = base / str(crosses)
        runtime = case / 'runtime'
        runtime.mkdir(parents=True, mode=0o700)
        (case / 'config').mkdir()
        (case / 'home').mkdir()
        wm = case / 'wm.toml'
        wm.write_text((ROOT / 'scripts/fixtures/new-window-focus-on-wm.toml').read_text() +
                      f'focus_crosses_workspaces = {str(crosses).lower()}\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(case / 'config'),
                   HOME=str(case / 'home'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
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

            def ctl(*args):
                result = subprocess.run([str(CTL), *args, '--json'], env=env, timeout=5,
                                        stdout=subprocess.PIPE, stderr=log, check=True)
                return json.loads(result.stdout)

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
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try:
                        if messages.get(timeout=.1) == 'ready':
                            return process
                    except queue.Empty:
                        pass
                raise AssertionError(f'{role} probe not ready')

            def workspace(number):
                return next(w for w in records('workspace') if w['number'] == number)

            def activate(number):
                ctl('workspace', 'activate', '--id', workspace(number)['id'])
                wait_for(lambda: workspace(number)['active'])

            def focused():
                return records('seat')[0]['window']

            def spawn():
                known = {w['id'] for w in records('window')}
                probe('window')
                window = wait_for(lambda: next((w for w in records('window') if w['id'] not in known), None))
                wait_for(lambda: focused() == window['id'])
                return window['id']

            def ordered(number):
                # Left-to-right order of the windows on a workspace.
                ws = workspace(number)['id']
                windows = wait_for(lambda: [w for w in records('window') if w['workspace'] == ws
                                            and w['geometry']['width'] > 0] or None)
                return [w['id'] for w in sorted(windows, key=lambda w: w['geometry']['x'])]

            inputs = probe('input')

            def press(code, number, window):
                send = f'chord {code} {SUPER}\n'
                inputs.stdin.write(send)
                inputs.stdin.flush()
                wait_for(lambda: workspace(number)['active'] and focused() == window)
                time.sleep(.15)
                assert workspace(number)['active'] and focused() == window, (number, window, focused())

            spawn(), spawn()
            activate(3)
            spawn(), spawn()
            one, three = ordered(1), ordered(3)
            assert len(one) == 2 and len(three) == 2, (one, three)
            activate(1)
            ctl('window', 'activate', '--id', one[1])
            wait_for(lambda: focused() == one[1])

            if crosses:
                press(KEY_L, 2, None)        # past the right edge enters the next workspace, even empty
                press(KEY_L, 3, three[0])    # leftmost window when entering from the left
                press(KEY_L, 3, three[1])    # ordinary focus inside the workspace
                for number in range(4, 10):
                    press(KEY_L, number, None)
                press(KEY_L, 1, one[0])      # the last workspace wraps to workspace 1
                press(KEY_H, 9, None)        # and workspace 1 wraps to the last
                for number in range(8, 3, -1):
                    press(KEY_H, number, None)
                press(KEY_H, 3, three[1])    # rightmost window when entering from the right
                press(KEY_H, 3, three[0])
                press(KEY_H, 2, None)
                press(KEY_H, 1, one[1])
                print('PASS: focus crosses and wraps workspaces', flush=True)
            else:
                press(KEY_L, 1, one[1])
                press(KEY_H, 1, one[0])
                press(KEY_H, 1, one[0])
                print('PASS: focus stays on the workspace when disabled', flush=True)
        except BaseException:
            log.seek(0)
            print(log.read()[-6000:])
            raise
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
            for child in children:
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            log.close()
