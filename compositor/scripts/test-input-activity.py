#!/usr/bin/env python3
"""Private input-activity protocol/ingress regression; never uses the host display."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--xwayland', action='store_true', help='also verify activity with a focused X11 client')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-activity-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    for name in ('runtime', 'config', 'home', 'state', 'cache'):
        (work / name).mkdir(mode=0o700)
    env.update(XDG_RUNTIME_DIR=str(work / 'runtime'), XDG_CONFIG_HOME=str(work / 'config'),
               HOME=str(work / 'home'), XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'), XDG_CONFIG_DIRS=str(work / 'config'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
    generated = []
    for name, xml in {
        'activity': ROOT / 'protocol/aqueous-input-activity-v1.xml',
        'xdg-shell': Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml'),
        'session-lock': Path('/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml'),
    }.items():
        subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
        code = work / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True)
        generated.append(code)
    client_binary = work / 'client'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}',
                    ROOT / 'scripts/fixtures/input-activity-client.c', *generated,
                    '-lwayland-client', '-o', client_binary], check=True)
    if args.xwayland:
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', ROOT / 'scripts/fixtures/input-activity-x11.c',
                        '-lX11', '-o', work / 'x11'], check=True)
    control, child_control = socket.socketpair()
    control.settimeout(5)
    logs, clients = [], []
    log = (work / 'compositor.log').open('w')
    compositor = subprocess.Popen([args.compositor.resolve(), *([] if args.xwayland else ['-no-xwayland']), '-log-level', 'error',
                                   '-input-activity-test-fd', str(child_control.fileno()), '-c', 'printf %s "$DISPLAY" > "$XDG_RUNTIME_DIR/x-display"'],
                                  env=env, pass_fds=[child_control.fileno()], stdout=log, stderr=log)
    child_control.close()

    def wait(predicate, message, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert compositor.poll() is None, f'compositor exited: {(work / "compositor.log").read_text()}'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(message)

    def inject(command):
        control.sendall((command + '\n').encode())
        assert control.recv(64) == b'ok\n', command

    def events(name, kind=None):
        result = []
        for line in (work / f'{name}.jsonl').read_text().splitlines():
            try:
                event = json.loads(line)
                if kind is None or event['event'] == kind:
                    result.append(event)
            except ValueError:
                pass
        return result

    def launch(name):
        out, err = (work / f'{name}.jsonl').open('w'), (work / f'{name}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([client_binary], env=env, stdin=subprocess.PIPE, stdout=out, stderr=err)
        clients.append(child)
        wait(lambda: events(name, 'connected'), f'{name} did not connect')
        return child

    def command(child, name, value):
        before = len(events(name, 'command'))
        child.stdin.write((value + '\n').encode()); child.stdin.flush()
        wait(lambda: len(events(name, 'command')) > before, f'{name}: {value}: {(work / (name + ".log")).read_text()}')

    def status(name):
        return events(name, 'state')[-1]['status']

    def quiet(name, duration=.22):
        before = len(events(name, 'activity'))
        time.sleep(duration)
        assert len(events(name, 'activity')) == before, f'{name}: unexpected activity'

    def press(category, code, device=0):
        inject(f'{category} {device} {code} 1')
        inject(f'{category} {device} {code} 0')

    def activity(name, category, code, expected, device=0):
        before = len(events(name, 'activity'))
        press(category, code, device=device)
        wait(lambda: len(events(name, 'activity')) > before, f'missing {category} activity')
        event = events(name, 'activity')[-1]
        assert event['categories'] == expected, event
        assert set(event) == {'event', 'generation', 'sequence', 'categories'}, event
        return event

    try:
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        ipc = wait(lambda: next((p for p in (work / 'runtime').glob('aqueous/*/ipc.sock')), None), 'no IPC')
        env['AQUEOUS_SOCKET'] = str(ipc)
        wait(lambda: (ipc.parent / 'activity.sock').exists(), 'no bootstrap')
        owner = launch('owner')
        denied = launch('denied')
        command(denied, 'denied', 'window')
        wait(lambda: events('denied', 'mapped'), 'other application did not map')
        command(denied, 'denied', 'cap')
        assert events('denied', 'proof')[-1]['ok'] is False
        command(denied, 'denied', 'forge')
        assert events('denied', 'authorization')[-1]['status'] == 1
        command(denied, 'denied', 'subscribe')
        assert status('denied') == 1
        command(denied, 'denied', 'sync')
        inject(f'owner {owner.pid}')
        command(owner, 'owner', 'cap')
        assert events('owner', 'proof')[-1]['ok'] is True
        command(owner, 'owner', 'authorize')
        assert events('owner', 'authorization')[-1]['status'] == 0
        command(owner, 'owner', 'replay')
        assert events('owner', 'authorization')[-1]['status'] == 1
        command(owner, 'owner', 'subscribe')
        assert status('owner') == 3
        command(owner, 'owner', 'ready 1')
        assert status('owner') == 0
        activity('owner', 'key', 30, 1)
        activity('owner', 'key', 28, 1)
        wait(lambda: events('denied', 'key-delivered'), 'normal Wayland keyboard delivery stopped')
        activity('owner', 'button', 272, 2)
        activity('owner', 'button', 273, 2)
        command(owner, 'owner', 'sync')
        before = len(events('owner', 'activity'))
        inject('burst')
        wait(lambda: len(events('owner', 'activity')) > before, 'mixed burst missing')
        assert events('owner', 'activity')[-1]['categories'] == 3
        quiet('owner')
        inject('remove 0')
        activity('owner', 'key', 30, 1)
        if args.xwayland:
            display_file = work / 'runtime/x-display'
            env['DISPLAY'] = wait(lambda: display_file.read_text() if display_file.exists() else None, 'no Xwayland display')
            out, err = (work / 'x11.jsonl').open('w'), (work / 'x11.log').open('w')
            logs.extend((out, err))
            x11 = subprocess.Popen([work / 'x11'], env=env, stdout=out, stderr=err)
            clients.append(x11)
            wait(lambda: events('x11', 'mapped'), 'X11 fixture did not map')
            ctl = args.compositor.resolve().parent / 'aqueousctl'
            def xwindow():
                windows = json.loads(subprocess.check_output([ctl, 'windows', '--json'], env=env, text=True))
                return next((w for w in windows if w.get('class') == 'aqueous-activity-x11'), None)
            window = wait(xwindow, 'Xwayland window was not managed')
            result = subprocess.run([ctl, 'window', 'activate', '--id', str(window['id']), '--seat', 'default', '--json'], env=env, check=True, capture_output=True, text=True)
            assert json.loads(result.stdout)['ok'], result.stdout
            wait(lambda: events('x11', 'focused'), 'Xwayland window did not receive focus')
            activity('owner', 'key', 30, 1)
            wait(lambda: events('x11', 'key-delivered'), 'normal Xwayland keyboard delivery stopped')
        quiet('denied')
        press('key', 30, device=1)
        press('button', 272, device=1)
        quiet('owner')
        # Held keys and duplicate down must not create new activity.
        before = len(events('owner', 'activity'))
        inject('key 0 30 1')
        wait(lambda: len(events('owner', 'activity')) > before, 'held initial press')
        inject('key 0 30 1'); quiet('owner')
        activity('owner', 'key', 30, 1, device=2)
        inject('remove 2')
        inject('key 0 30 0'); quiet('owner')
        command(owner, 'owner', 'inhibit 0')
        generation = events('owner', 'state')[-1]['generation']
        assert status('owner') == 3
        press('key', 30); quiet('owner')
        command(owner, 'owner', 'inhibit 1')
        command(owner, 'owner', 'release 0')
        command(owner, 'owner', 'ready 1')
        assert status('owner') == 3
        command(owner, 'owner', 'release 1')
        assert events('owner', 'state')[-1]['generation'] > generation
        command(owner, 'owner', 'stale')
        assert status('owner') == 3
        command(owner, 'owner', 'ready 1'); quiet('owner')
        activity('owner', 'key', 30, 1)
        # Session loss and return invalidate pending input/readiness.
        inject('active 0'); press('key', 30); quiet('owner')
        inject('active 1')
        command(owner, 'owner', 'ready 1'); quiet('owner')
        activity('owner', 'key', 30, 1)
        # Exercise real ext-session-lock preparation and completion.
        command(denied, 'denied', 'lock')
        press('key', 30); quiet('owner')
        wait(lambda: events('denied', 'locked'), 'lock was not acknowledged')
        command(denied, 'denied', 'unlock')
        command(owner, 'owner', 'ready 1'); quiet('owner')
        activity('owner', 'key', 30, 1)
        # Backpressure suspends only activity, never the shared display.
        command(owner, 'owner', 'autoack 0')
        activity('owner', 'key', 30, 1)
        press('button', 272)
        wait(lambda: status('owner') == 3, 'missing ack timeout', timeout=2)
        command(owner, 'owner', 'sync')
        command(owner, 'owner', 'autoack 1')
        command(owner, 'owner', 'ready 1'); quiet('owner')
        activity('owner', 'key', 30, 1)
        command(owner, 'owner', 'unsubscribe')
        press('key', 30); quiet('owner')
        command(owner, 'owner', 'subscribe')
        command(owner, 'owner', 'ready 1'); quiet('owner')
        activity('owner', 'key', 30, 1)
        inject('revoke')
        wait(lambda: status('owner') == 1, 'missing revocation')
        command(owner, 'owner', 'sync')
        press('key', 30); quiet('owner')
        command(owner, 'owner', 'destroy-manager')
        command(owner, 'owner', 'sync')
        print('PASS: authorization, payload privacy, physical ingress, virtual/repeat exclusion, inhibits, session/lock, backpressure and shared display', flush=True)
    finally:
        for child in clients:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
        compositor.terminate()
        compositor.wait(timeout=10)
        control.close()
        for stream in logs + [log]:
            stream.close()


if __name__ == '__main__':
    main()
