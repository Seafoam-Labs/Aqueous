#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
"""Regression: a focused client keeps receiving keys across virtual-keyboard churn.

In a headless session the virtual keyboard is the seat's *only* keyboard, so every
injector that connects and disconnects drops and re-adds WL_SEAT_CAPABILITY_KEYBOARD.
That churn can clear wlroots' keyboard delivery focus while the logical seat focus
still names the window; without Seat.resyncKeyboardFocus the focused client then
silently stops receiving keys even though IPC reports it focused.

This test cycles create -> inject -> destroy of a virtual keyboard many times and
asserts that every injected key reaches the focused window and that focus never
leaves it. Run several instances in parallel to stress the timing-sensitive path.
"""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))
CYCLES = int(sys.argv[1]) if len(sys.argv) > 1 else 50
KEY = 30  # evdev code for 'a'; the window probe prints "key 30 1" on press


def wait_for(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aqueous-keyboard-churn-') as temporary:
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

    runtime = base / 'runtime'
    runtime.mkdir(parents=True, mode=0o700)
    (base / 'config').mkdir()
    (base / 'home').mkdir()
    for name in ('state', 'cache', 'data'):
        (base / name).mkdir(mode=0o700)
    wm = base / 'wm.toml'
    wm.write_text((ROOT / 'scripts/fixtures/new-window-focus-on-wm.toml').read_text())
    env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(base / 'config'),
               XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
               XDG_DATA_HOME=str(base / 'data'),
               HOME=str(base / 'home'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
               WLR_RENDERER='pixman', AQUEOUS_CONFIG=str(wm))
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children = []
    log = (base / 'compositor.log').open('w+')
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

        def seat():
            return next(r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == 'seat')

        def spawn(role):
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
                        return process, messages
                except queue.Empty:
                    pass
            raise AssertionError(f'{role} probe not ready')

        window, window_messages = spawn('window')
        window_id = wait_for(lambda: next((w['id'] for w in ctl('shell', 'snapshot')['upsert']
                                           if w['kind'] == 'window'), None))
        wait_for(lambda: seat()['window'] == window_id)

        received = [0]
        lock = threading.Lock()

        def count_keys():
            while True:
                try:
                    line = window_messages.get(timeout=.1)
                except queue.Empty:
                    if window.poll() is not None:
                        return
                    continue
                if line == f'key {KEY} 1':
                    with lock:
                        received[0] += 1
        threading.Thread(target=count_keys, daemon=True).start()

        for cycle in range(CYCLES):
            # Make the focused client busy (blocked main loop, like a GVfs mount)
            # so keyboard churn lands while it is slow to process Wayland events.
            window.stdin.write('busy 120\n')
            window.stdin.flush()
            # A fresh injector creates a new virtual keyboard (and a new keymap);
            # terminating it destroys the keyboard and drops the seat capability.
            injector, _ = spawn('input')
            try:
                injector.stdin.write(f'key {KEY}\n')
                injector.stdin.flush()
                target = cycle + 1
                try:
                    wait_for(lambda: received[0] >= target, timeout=4)
                except AssertionError:
                    raise AssertionError(
                        f'cycle {cycle}: focused window received {received[0]}/{target} keys '
                        f'(seat={seat()})') from None
                assert seat()['window'] == window_id, f'cycle {cycle}: focus left the window: {seat()}'
            finally:
                injector.terminate()
                try:
                    injector.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    injector.kill()
                    injector.wait()
        assert received[0] >= CYCLES, received
        assert seat()['window'] == window_id, seat()
        print(f'PASS: {CYCLES} virtual-keyboard churn cycles delivered every key to the focused window', flush=True)
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