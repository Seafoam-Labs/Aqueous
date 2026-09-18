#!/usr/bin/env python3
"""Issue #69 regression in an isolated headless compositor/Xwayland session."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(sys.argv[2] if len(sys.argv) > 2 else os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))
SCALING = os.environ.get('AQUEOUS_UNMANAGED_SCALING', 'legacy')
SCALED = os.environ.get('AQUEOUS_UNMANAGED_SCALED') == '1'


def wait_for(check, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(.04)
    raise AssertionError('condition timed out')


with tempfile.TemporaryDirectory(prefix='aqueous-unmanaged-') as tmp:
    base = Path(tmp)
    runtime = base / 'runtime'
    runtime.mkdir(mode=0o700)
    config = base / 'config'
    config.mkdir()
    rules = config / 'rules.toml'
    rules.write_text('')
    env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
    env.update(XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(config), HOME=str(base),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman',
               AQUEOUS_CONFIG=str(ROOT / 'scripts/fixtures/overview-wm.toml'), AQUEOUS_RULES=str(rules))
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(ROOT / 'scripts/fixtures/unmanaged-x11.c'), '-lX11', '-o', str(base / 'fixture')], check=True)
    xml = str(ROOT / 'protocol/aqueous-shell-v1.xml')
    subprocess.run(['wayland-scanner', 'client-header', xml, str(base / 'aqueous-shell-client-protocol.h')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(base / 'shell.c')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', str(ROOT / 'protocol/upstream/ext-workspace-v1.xml'), str(base / 'workspace.c')], check=True)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(base), str(ROOT / 'scripts/fixtures/shell-legacy-observer.c'), str(base / 'shell.c'), str(base / 'workspace.c'), '-lwayland-client', '-o', str(base / 'legacy')], check=True)
    if SCALED:
        outputs = config / 'outputs.toml'
        outputs.write_text('[[output]]\nname = "HEADLESS-1"\nposition = [-640, 0]\nscale = 1.25\n\n[[output]]\nname = "HEADLESS-2"\nposition = [0, 0]\nscale = 1.5\n')
        env['AQUEOUS_OUTPUTS'] = str(outputs)
    children = []
    log = (base / 'compositor.log').open('w+')
    compositor = subprocess.Popen([str(BIN), '-xwayland-scaling', SCALING, '-c', 'printf %s "$DISPLAY" > "$XDG_RUNTIME_DIR/test-display"; printenv AQUEOUS_SOCKET > "$XDG_RUNTIME_DIR/test-ipc"'], env=env, stdout=log, stderr=log)
    children.append(compositor)
    ipc = None
    try:
        def socket_path():
            assert compositor.poll() is None, 'compositor exited'
            return next((p for p in runtime.glob('wayland-*') if p.is_socket()), None)
        env['WAYLAND_DISPLAY'] = wait_for(socket_path).name
        env['DISPLAY'] = wait_for(lambda: (runtime / 'test-display').read_text().strip() if (runtime / 'test-display').exists() else None)
        ipc = Client(wait_for(lambda: (runtime / 'test-ipc').read_text().strip() if (runtime / 'test-ipc').exists() else None))
        assert ipc.capabilities['capabilities']['unmanaged_windows']
        def ctl(*args):
            return json.loads(subprocess.check_output([str(CTL), *args], env=env, text=True, timeout=10))
        def popups():
            return [w for w in ctl('windows', '--json') if w.get('managed') is False and w.get('class') == 'aq-notification-test']
        def popup():
            rows = popups()
            return rows[0] if len(rows) == 1 else None
        watch = subprocess.Popen([str(CTL), 'shell', 'watch', '--json'], env=env, stdout=subprocess.PIPE, text=True)
        children.append(watch)
        events = queue.Queue()
        def read_watch():
            for line in watch.stdout:
                events.put(json.loads(line))
        threading.Thread(target=read_watch, daemon=True).start()
        assert events.get(timeout=10)['type'] == 'snapshot'
        fixture = subprocess.Popen([str(base / 'fixture')], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        children.append(fixture)
        assert fixture.stdout.readline().strip() == 'ready'
        def command(text):
            fixture.stdin.write(text + '\n'); fixture.stdin.flush()
            return fixture.stdout.readline().strip()
        original = wait_for(popup)
        identifier = original['id']
        assert original['title'] == 'notification' and 'notification' in original['window_types'], original
        if not SCALED:
            assert original['geometry'] == dict(x=80, y=90, width=160, height=80), original
        assert original['owner'], original
        def watch_until(check):
            end = time.monotonic() + 10
            while time.monotonic() < end:
                batch = events.get(timeout=max(.01, end - time.monotonic()))
                if check(batch):
                    return batch
            raise AssertionError('missing watch event')
        watch_until(lambda b: any(w['kind'] == 'unmanaged_window' and w['id'] == identifier for w in b['upsert']))
        # Existing clients and default socket consumers keep their old entity set.
        legacy = json.loads(subprocess.check_output([str(base / 'legacy')], env=env, text=True, timeout=10))
        assert all(w['kind'] != 'unmanaged_window' for w in legacy['upsert'])
        assert all(w['kind'] != 'unmanaged_window' for w in ipc.snapshot()['upsert'])
        extended = ipc.call('snapshot', {'include_unmanaged': True})['result']['batch']
        assert any(w['id'] == identifier for w in extended['upsert'])
        ipc.call('snapshot', {'include_unmanaged': 'true'}, ok=False)
        inspected = subprocess.check_output([str(CTL), 'inspect', '--rule'], env=env, text=True, timeout=10)
        assert 'scope = "override_redirect"' in inspected
        def reload_rule(text):
            rules.write_text(text)
            ctl('session', 'reload', '--json')
        reload_rule('[[window]]\nclass = "aq-notification-test"\nopacity = 0.2\n')
        assert popup()['matched_rule'] is None  # managed rule doesn't match the popup
        rule = '[[window]]\nscope = "override_redirect"\nclass = "aq-notification-test"\nwindow_type = "notification"\nopacity = 0.4\nfocus = false\nx = 25\ny = 35\n'
        if SCALED:
            rule += 'output = "HEADLESS-1"\n'
        reload_rule(rule)
        changed = wait_for(lambda: p if (p := popup()) and abs(p['opacity'] - .4) < .001 else None)
        assert changed['geometry']['x'] == (25 - 640 if SCALED else 25) and changed['geometry']['y'] == 35, changed
        expected_x11 = ['31', '44'] if SCALED and SCALING == 'native' else ['25', '35']
        if SCALED:
            assert changed['output_name'] == 'HEADLESS-1'
            assert changed['geometry']['width'] == (128 if SCALING == 'native' else 160), changed
        assert changed['focus_suppressed'] and changed['matched_rule']
        command('grab')
        seats = [w for w in ctl('shell', 'snapshot', '--json')['upsert'] if w['kind'] == 'seat']
        assert all(w['focus_kind'] != 'override_redirect' for w in seats), seats
        command('ungrab')
        assert command('geometry').split()[:2] == expected_x11
        command('move 110 120')
        wait_for(lambda: command('geometry').split()[:2] == expected_x11)
        command('resize 200 100')
        wait_for(lambda: command('geometry').split()[2:4] == ['200', '100'])
        command('type _NET_WM_WINDOW_TYPE_POPUP_MENU')
        restored = wait_for(lambda: p if (p := popup()) and p['matched_rule'] is None else None)
        assert command('geometry').split()[:2] == ['110', '120']
        if not SCALED:
            assert restored['geometry']['x'] == 110 and restored['geometry']['y'] == 120, restored
        command('type _NET_WM_WINDOW_TYPE_NOTIFICATION')
        wait_for(lambda: popup()['matched_rule'])
        command('title renamed notification')
        watch_until(lambda b: any(w.get('title') == 'renamed notification' and w['kind'] == 'unmanaged_window' for w in b['upsert']))
        assert popup()['id'] == identifier
        command('unmap')
        wait_for(lambda: not popups())
        command('map')
        wait_for(popup)
        reload_rule('')
        restored = popup()
        assert command('geometry').split()[:2] == ['110', '120']
        if not SCALED:
            assert restored['geometry']['x'] == 110 and restored['geometry']['y'] == 120, restored
        assert not restored['focus_suppressed'] and restored['matched_rule'] is None
        command('unmap')
        wait_for(lambda: not popups())
        watch_until(lambda b: 'unmanaged_window:' + identifier in b['removed'])
        command('map')
        wait_for(popup)
        command('managed')
        wait_for(lambda: not popups())
        wait_for(lambda: any(w.get('title') == 'renamed notification' and w['managed'] for w in ctl('windows', '--json')))
        command('unmanaged')
        recreated = wait_for(popup)
        assert recreated['id'] != identifier
        assert len([w for w in ctl('windows', '--json') if w.get('title') == 'renamed notification']) == 1
        command('destroy-owner')
        wait_for(lambda: popup()['owner'] is None)
        command('quit')
        fixture.wait(timeout=5)
        wait_for(lambda: not popups())
        print(f'PASS: unmanaged discovery, negotiated shell state, scoped rules, reload, X11 placement and lifecycle (scaling={SCALING}, scaled={SCALED})')
    except BaseException:
        log.flush(); log.seek(0); print(log.read()[-6000:])
        if compositor.poll() is None:
            print('WINDOWS:', ctl('windows', '--json'))
        raise
    finally:
        if ipc:
            ipc.close()
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()
        log.close()
