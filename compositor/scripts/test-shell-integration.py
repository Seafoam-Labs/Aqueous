#!/usr/bin/env python3
"""Isolated shell protocol/CLI regression; never connects to the user's display."""
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


def wait_for(check, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aqueous-shell-') as tmp:
    base = Path(tmp)
    runtime = base / 'runtime'
    runtime.mkdir(mode=0o700)
    config = base / 'config'
    config.mkdir()
    home = base / 'home'
    home.mkdir()
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(config),
               HOME=str(home), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
               WLR_RENDERER='pixman', GDK_BACKEND='wayland',
               AQUEOUS_CONFIG=str(ROOT / 'scripts/fixtures/overview-wm.toml'))
    env.pop('WAYLAND_DISPLAY', None)
    env.pop('DISPLAY', None)
    env.pop('LD_PRELOAD', None)
    env.pop('DBUS_SESSION_BUS_ADDRESS', None)
    protocols = {
        'xdg-shell': '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml',
        'shortcuts': '/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
        'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
        'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
        'session-lock': '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',
        'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
        'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
    }
    generated = []
    for name, xml in protocols.items():
        subprocess.run(['wayland-scanner', 'client-header', str(xml), str(base / (name + '-client-protocol.h'))], check=True)
        code = base / (name + '.c')
        subprocess.run(['wayland-scanner', 'private-code', str(xml), str(code)], check=True)
        generated.append(str(code))
    fixture = base / 'shell-client'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(base),
                    str(ROOT / 'scripts/fixtures/shell-client.c'), *generated,
                    '-lwayland-client', '-lxkbcommon', '-o', str(fixture)], check=True)
    children = []
    log = (base / 'compositor.log').open('w+')
    compositor = subprocess.Popen([str(BIN), '-no-xwayland', '-c', 'true'], env=env,
                                  stdout=log, stderr=log)
    children.append(compositor)
    try:
        def socket():
            if compositor.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            return next((p for p in runtime.glob('wayland-*') if p.is_socket()), None)
        env['WAYLAND_DISPLAY'] = wait_for(socket).name

        def ctl(*args, ok=True):
            p = subprocess.run([str(CTL), *args, '--json'], env=env,
                               capture_output=True, text=True, timeout=8)
            assert (p.returncode == 0) == ok, (args, p.returncode, p.stdout, p.stderr)
            return json.loads(p.stdout)

        def snapshot():
            return ctl('shell', 'snapshot')['upsert']

        def records(kind):
            return [r for r in snapshot() if r['kind'] == kind]

        caps = ctl('shell', 'capabilities')
        assert caps['schema'] == 1 and caps['commands']
        initial = snapshot()
        outputs = [r for r in initial if r['kind'] == 'output']
        assert len(outputs) == 2 and len({r['id'] for r in outputs}) == 2
        workspaces = [r for r in initial if r['kind'] == 'workspace']
        assert len(workspaces) >= 2
        seat = records('seat')[0]['id']

        watch = subprocess.Popen([str(CTL), 'shell', 'watch', '--json'], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        children.append(watch)
        updates = queue.Queue()
        def read_watch():
            for line in watch.stdout:
                updates.put(json.loads(line))
        threading.Thread(target=read_watch, daemon=True).start()
        baseline = updates.get(timeout=5)
        assert baseline['type'] == 'snapshot'
        time.sleep(.2)
        while not updates.empty():
            baseline = updates.get_nowait()
        # No polling or heartbeat events on a quiet desktop.
        time.sleep(.3)
        assert updates.empty()
        ws = workspaces[0]
        result = ctl('workspace', 'rename', '--id', ws['id'], '--name', 'same "name"')
        assert result['status'] == 'applied'
        update = updates.get(timeout=5)
        assert update['base_sequence'] == baseline['sequence']
        assert any(r['kind'] == 'workspace' and r['id'] == ws['id'] and r['name'] == 'same "name"' for r in update['upsert'])
        ctl('workspace', 'activate', '--id', ws['id'], '--seat', seat)
        assert records('seat')[0]['output'] == ws['output']
        failure = ctl('workspace', 'rename', '--id', '4294967295', '--name', 'missing', ok=False)
        assert failure['status'] == 'not_found'
        # Existing diagnostics retain their old JSON shape.
        assert isinstance(ctl('windows'), list)
        assert len(ctl('outputs')) == 2

        def probe(role):
            log_file = (base / (role + '-probe.log')).open('w+')
            process = subprocess.Popen([str(fixture), role], env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=log_file, text=True)
            children.append(process)
            messages = queue.Queue()
            def read():
                for line in process.stdout:
                    messages.put(line.strip())
            threading.Thread(target=read, daemon=True).start()
            return process, messages

        def send(process, command):
            process.stdin.write(command + '\n')
            process.stdin.flush()

        def expect(messages, text):
            deadline = time.monotonic() + 5
            seen = []
            while time.monotonic() < deadline:
                try:
                    line = messages.get(timeout=.1)
                    seen.append(line)
                    if line == text:
                        return
                except queue.Empty:
                    pass
            raise AssertionError((text, seen))

        window, window_messages = probe('window')
        wins = wait_for(lambda: records('window'))
        win = wins[0]
        ctl('window', 'activate', '--id', win['id'], '--seat', seat)
        assert wait_for(lambda: next((r for r in records('window') if r['id'] == win['id'] and r['focused']), None))
        assert ctl('window', 'state', '--id', win['id'], '--minimized', 'true', ok=False)['status'] == 'unsupported'
        owner = next(o for o in outputs if o['id'] == win['output'])
        ctl('layout', '--output', owner['name'], '--set', 'float')
        for field in ['minimized', 'maximized', 'fullscreen']:
            ctl('window', 'state', '--id', win['id'], '--' + field, 'true')
            try:
                wait_for(lambda: next((r for r in records('window') if r['id'] == win['id'] and r[field]), None))
            except AssertionError:
                raise AssertionError((field, records('window')))
            ctl('window', 'state', '--id', win['id'], '--' + field, 'false')
        # Effective group changes originate from both CLI and physical-client events.
        kb = wait_for(lambda: next((k for k in records('keyboard') if len(k['layouts']) == 2), None))
        ctl('keyboard', 'set', '--seat', seat, '--group', kb['id'], '--index', '1')
        assert next(k for k in records('keyboard') if k['id'] == kb['id'])['index'] == 1
        ctl('keyboard', 'next', '--seat', seat, '--group', kb['id'])
        assert next(k for k in records('keyboard') if k['id'] == kb['id'])['index'] == 0
        send(window, 'layout')
        wait_for(lambda: next(k for k in records('keyboard') if k['id'] == kb['id'])['index'] == 1)
        ctl('keyboard', 'set', '--seat', seat, '--group', kb['id'], '--index', '0')
        assert ctl('keyboard', 'set', '--seat', seat, '--group', kb['id'], '--index', '99', ok=False)['status'] == 'invalid'

        # Inhibiting while focused delivers the chord as normal input; releasing
        # after destroying the inhibitor retains the original press consumer.
        ctl('window', 'activate', '--id', win['id'], '--seat', seat)
        send(window, 'inhibit')
        expect(window_messages, 'inhibit active')
        send(window, 'press')
        expect(window_messages, 'key 17 1')
        assert records('session')[0]['overview_output'] is None
        send(window, 'uninhibit')
        send(window, 'release')
        expect(window_messages, 'key 17 0')
        send(window, 'press')
        send(window, 'release')
        wait_for(lambda: records('session')[0]['overview_output'] is not None)
        ctl('overview', 'hide')

        # Flow control sends nothing more until the client acknowledges its batch.
        slow, slow_messages = probe('watch')
        expect(slow_messages, 'batch')
        expect(slow_messages, 'ready')
        for name in ['one', 'two', 'three']:
            ctl('workspace', 'rename', '--id', ws['id'], '--name', name)
        time.sleep(.15)
        assert slow_messages.empty()
        send(slow, 'ack')
        expect(slow_messages, 'batch')
        send(slow, 'quit')
        assert slow.wait(timeout=3) == 0

        # DMS FrameExclusions uses four layer surfaces, one per edge. Verify
        # normal exclusive zones reserve all edges and are released on crash.
        before_frame = records('output')
        frame, frame_messages = probe('frame')
        for _ in range(4):
            expect(frame_messages, 'frame configured')
        def reserved():
            for o in records('output'):
                original = next(v for v in before_frame if v['id'] == o['id'])
                if o['usable_bounds']['width'] == original['usable_bounds']['width'] - 40 and o['usable_bounds']['height'] == original['usable_bounds']['height'] - 40:
                    return True
            return False
        wait_for(reserved)
        frame.kill()
        frame.wait(timeout=3)
        wait_for(lambda: all(next(o for o in records('output') if o['id'] == old['id'])['usable_bounds'] == old['usable_bounds'] for old in before_frame))

        # Lock state is observable but shell mutation is rejected until unlock.
        locker, lock_messages = probe('lock')
        expect(lock_messages, 'locked')
        wait_for(lambda: records('session')[0]['locked'])
        assert ctl('session', 'exit', ok=False)['status'] == 'locked'
        assert ctl('window', 'close', '--id', win['id'], ok=False)['status'] == 'locked'
        send(locker, 'unlock')
        assert locker.wait(timeout=3) == 0
        wait_for(lambda: not records('session')[0]['locked'])

        target = next(o for o in outputs if o['id'] != win['output'])
        ctl('window', 'move', '--id', win['id'], '--output', target['name'])
        assert wait_for(lambda: next((r for r in records('window') if r['id'] == win['id'] and r['output'] == target['id']), None))
        ctl('window', 'activate', '--id', win['id'], '--seat', seat)
        ctl('overview', 'show', '--output', target['name'])
        assert records('session')[0]['overview_output'] == target['id']
        ctl('overview', 'show', '--output', target['name'])
        ctl('overview', 'hide')
        assert records('session')[0]['overview_output'] is None
        ctl('overview', 'hide')
        ctl('window', 'close', '--id', win['id'])
        wait_for(lambda: not records('window'))
        assert ctl('window', 'activate', '--id', win['id'], '--seat', seat, ok=False)['status'] == 'not_found'
        assert ctl('session', 'exit')['status'] == 'accepted'
        assert compositor.wait(timeout=5) == 0
        print('PASS: shell state/actions, keyboard, inhibition, flow control, frame cleanup, lock, overview and exit')
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-12000:])
        raise
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for child in reversed(children):
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
