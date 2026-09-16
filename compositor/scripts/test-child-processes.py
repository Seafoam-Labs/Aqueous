#!/usr/bin/env python3
"""Exercise spawn and application-profile reaping in a private headless session."""
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))


def wait_for(check, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.02)
    raise AssertionError('condition timed out')


def state(pid):
    try:
        return Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
    except FileNotFoundError:
        return None


# Adopt surviving test apps when the private compositor exits, so the test can
# clean them up itself without depending on the host's PID 1 behavior.
assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
with tempfile.TemporaryDirectory(prefix='aqueous-children-') as temporary:
    base = Path(temporary)
    for name in ('runtime', 'config', 'home'):
        (base / name).mkdir(mode=0o700)
    helper = base / 'child.sh'
    helper.write_text('''#!/bin/sh
printf '%s %s\\n' "$$" "$1" >> "$XDG_RUNTIME_DIR/children"
case "$1" in
    success|startup) exit 0;;
    failure) exit 7;;
    signal) kill -TERM "$$";;
    missing) exec /aqueous-test-missing-executable;;
    long) exec sleep 300;;
esac
''')
    helper.chmod(0o700)
    wm = base / 'wm.toml'
    wm.write_text(f'''[layout]
default = "tile"
[keybinds.custom]
"Ctrl+WheelUp" = "spawn:exec {helper} success"
"Ctrl+WheelDown" = "launch:failure"
"Ctrl+WheelLeft" = "launch:signal"
"Ctrl+WheelRight" = "launch:long"
[[exec]]
name = "startup-child"
command = "exec {helper} startup"
when = "startup"
[[exec]]
name = "failed-exec"
command = "exec {helper} missing"
when = "startup"
''' + ''.join(f'''[[application]]
name = "{mode}"
command = "/bin/sh"
args = [{json.dumps(str(helper))}, "{mode}"]
''' for mode in ('failure', 'signal', 'long')))

    generated = []
    for name, xml in (
        ('virtual-keyboard', ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml'),
        ('virtual-pointer', ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml'),
    ):
        subprocess.run(['wayland-scanner', 'client-header', xml, base / f'{name}-client-protocol.h'], check=True)
        code = base / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True)
        generated.append(code)
    fixture = base / 'input'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(base),
                    ROOT / 'scripts/fixtures/wheel-input.c', *generated,
                    '-lwayland-client', '-lxkbcommon', '-lm', '-o', fixture], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
    env.update(HOME=str(base / 'home'), XDG_CONFIG_HOME=str(base / 'config'),
               XDG_RUNTIME_DIR=str(base / 'runtime'), AQUEOUS_CONFIG=str(wm),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)

    def records():
        marker = base / 'runtime/children'
        return [(int(pid), mode) for pid, mode in
                (line.split() for line in marker.read_text().splitlines())] if marker.exists() else []

    processes = []
    ipc = None
    with (base / 'compositor.log').open('w+') as log:
        try:
            compositor = subprocess.Popen([BIN, '-no-xwayland', '-c',
                                           'printf %s "$AQUEOUS_SOCKET" > "$XDG_RUNTIME_DIR/ipc"'],
                                          env=env, stdout=log, stderr=log)
            processes.append(compositor)
            env['WAYLAND_DISPLAY'] = wait_for(lambda: next(
                (p for p in (base / 'runtime').glob('wayland-*') if p.is_socket()), None)).name
            endpoint = base / 'runtime/ipc'
            ipc = Client(wait_for(lambda: endpoint.read_text() if endpoint.exists() else None))
            wait_for(lambda: len(records()) == 2)
            wait_for(lambda: all(state(pid) is None for pid, _ in records()))
            injector = subprocess.Popen([fixture], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, text=True)
            processes.append(injector)

            def response(expected):
                assert select.select([injector.stdout], [], [], 5)[0], 'input fixture timed out'
                assert injector.stdout.readline().strip() == expected

            def send(command):
                injector.stdin.write(command + '\n')
                injector.stdin.flush()
                response('done')

            response('ready')
            send('move')
            send('mods 4')
            # Long-lived profile remains owned while other children finish.
            send('scroll 1 0 15 1')
            wait_for(lambda: any(mode == 'long' for _, mode in records()))
            long_pid = next(pid for pid, mode in records() if mode == 'long')
            for _ in range(2):
                before = len(records())
                for _ in range(16):
                    send('scroll 0 0 -15 -1')  # shell command, exit 0
                    send('scroll 0 0 15 1')    # application profile, exit 7
                    send('scroll 1 0 -15 -1')  # application profile, SIGTERM
                wait_for(lambda: len(records()) == before + 48)
                wait_for(lambda: all(state(pid) is None for pid, mode in records() if mode != 'long'))
                assert state(long_pid) not in (None, 'Z')
                ipc.snapshot()  # Reaping must not block the compositor.

            os.kill(long_pid, signal.SIGTERM)
            wait_for(lambda: state(long_pid) is None)
            # After the registry drains, a new launch must restart its timer.
            before = len(records())
            send('scroll 0 0 -15 -1')
            wait_for(lambda: len(records()) == before + 1)
            wait_for(lambda: state(records()[-1][0]) is None)

            send('scroll 1 0 15 1')
            wait_for(lambda: len(records()) == before + 2)
            survivor = records()[-1][0]
            ipc.command('session.exit')
            assert compositor.wait(timeout=5) == 0
            assert state(survivor) not in (None, 'Z'), 'teardown killed a launched app'
            print('PASS: startup commands, spawn/profile bursts, failed exec, nonzero/signal exits, timer restart, responsive IPC and shutdown')
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read()[-12000:])
            raise
        finally:
            if ipc:
                ipc.close()
            for process in reversed(processes):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=5)
            for pid, mode in records():
                if mode == 'long' and state(pid) is not None:
                    os.kill(pid, signal.SIGKILL)
            while True:
                try:
                    os.waitpid(-1, 0)
                except ChildProcessError:
                    break
