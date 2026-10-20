#!/usr/bin/env python3
"""Native blur wire/lifecycle and pixel regressions in an isolated compositor."""
import os
from pathlib import Path
import queue
import shlex
import shutil
import json
import socket as socket_module
import subprocess
import tempfile
import threading
import time

from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUS_CTL_BIN', BIN.parent / 'aqueousctl'))
ARTIFACTS = Path(tempfile.mkdtemp(prefix='aqueous-background-effect-'))
print(f'Artifacts: {ARTIFACTS}', flush=True)


def wait_for(check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.04)
    raise AssertionError('condition timed out')


def build_fixture():
    protocol_dir = Path(subprocess.check_output(
        ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    protocols = {
        'background-effect': protocol_dir / 'staging/ext-background-effect/ext-background-effect-v1.xml',
        'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
        'xdg-shell': protocol_dir / 'stable/xdg-shell/xdg-shell.xml',
    }
    sources = []
    for name, xml in protocols.items():
        subprocess.run(['wayland-scanner', 'client-header', str(xml), str(ARTIFACTS / f'{name}-client-protocol.h')], check=True)
        source = ARTIFACTS / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', str(xml), str(source)], check=True)
        sources.append(str(source))
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    executable = ARTIFACTS / 'client'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-I' + str(ARTIFACTS),
                    str(ROOT / 'scripts/fixtures/background-effect-client.c'), *sources, *flags, '-o', str(executable)], check=True)
    return executable


class Client:
    def __init__(self, fixture, env, mode='layer', initial='empty'):
        self.proc = subprocess.Popen([str(fixture), mode, initial], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=(ARTIFACTS / f'client-{mode}-{time.time_ns()}.log').open('w'), text=True, bufsize=1)
        self.lines = queue.Queue()
        threading.Thread(target=lambda: [self.lines.put(line.strip()) for line in self.proc.stdout], daemon=True).start()
        assert self.lines.get(timeout=10) == 'READY'

    def send(self, command):
        self.proc.stdin.write(command + '\n')
        self.proc.stdin.flush()
        response = self.lines.get(timeout=10)
        assert response.startswith('OK') or response == 'EXPECTED_ERROR', (command, response)
        return response

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.write('quit\n')
            self.proc.stdin.flush()
        assert self.proc.wait(timeout=10) == 0


def run(fixture, uncached=False):
    case = ARTIFACTS / ('uncached' if uncached else 'cached')
    case.mkdir()
    runtime = case / 'runtime'
    runtime.mkdir(mode=0o700)
    config = case / 'wm.toml'
    config.write_text('[blur]\nenabled = true\nradius = 8\npasses = 2\n[workspace_transition]\nenabled = false\n')
    rules = case / 'rules.toml'
    rules.write_text('')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'DMS_'))}
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(case / 'config'), HOME=str(case),
               XDG_STATE_HOME=str(case / 'state'), XDG_CACHE_HOME=str(case / 'cache'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman' if os.environ.get('AQUEOUS_TEST_NO_EFFECTS') == '1' else 'vulkan',
               AQUEOUS_CONFIG=str(config), AQUEOUS_RULES=str(rules))
    for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    if uncached:
        env['AQUEOUS_VULKAN_BLUR_UNCACHED'] = '1'
    log = (case / 'compositor.log').open('w+')
    compositor = subprocess.Popen([str(BIN), '-no-xwayland', '-policy', 'internal', '-log-level', 'debug', '-c', 'true'], env=env, stdout=log, stderr=log)
    clients = []
    try:
        def socket():
            if compositor.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            return next((p for p in runtime.glob('wayland-*') if p.is_socket()), None)
        env['WAYLAND_DISPLAY'] = wait_for(socket).name
        probe = subprocess.check_output([str(fixture), 'probe'], env=env, text=True).strip()
        def capture(name):
            # Multiple captures synchronize with completed output frames.
            path = case / f'{name}.png'
            for _ in range(3):
                subprocess.run(['grim', str(path)], env=env, check=True, capture_output=True, timeout=10)
            return Image.open(path).convert('RGB')

        def difference(a, b, box):
            return sum(ImageStat.Stat(ImageChops.difference(a.crop(box), b.crop(box))).mean) / 3

        if os.environ.get('AQUEOUS_TEST_NO_EFFECTS') == '1':
            assert probe == 'unsupported 0', probe
            if os.environ.get('DMS_SOURCE'):
                test_dms(fixture, env, case, capture, difference, clients)
            print('PASS no-effects global absent', flush=True)
            return
        assert probe == 'supported 1', probe

        if os.environ.get('AQUEOUS_TEST_DMS_ONLY') == '1':
            test_dms(fixture, env, case, capture, difference, clients)
            return
        test_ownership(fixture, env, case, capture, difference, clients)
        test_gtk(fixture, env, case, capture, difference, clients)
        rules.write_text('')
        client = Client(fixture, env)
        clients.append(client)
        baseline = capture('baseline')
        client.send('set hole')
        pending = capture('pending')
        assert difference(baseline, pending, (0, 0, 320, 240)) < .1
        client.send('commit')
        hole = capture('hole')
        assert difference(baseline, hole, (30, 30, 70, 160)) > 20, 'mask did not blur'
        assert difference(baseline, hole, (85, 65, 135, 115)) < 1, 'hole was blurred'
        assert difference(baseline, hole, (270, 0, 315, 220)) < 1, 'outside mask was blurred'
        client.send('commit')
        assert difference(hole, capture('unrelated-commit'), (0, 0, 320, 240)) < 1
        client.send('background')
        source_changed = capture('source-changed')
        assert difference(hole, source_changed, (85, 65, 135, 115)) > 100
        client.send('clear'); client.send('commit')
        source_baseline = capture('source-baseline')
        assert difference(source_baseline, source_changed, (30, 30, 70, 160)) > 20
        client.send('background'); client.send('set hole'); client.send('commit')
        client.send('set shift'); client.send('commit')
        shifted = capture('shift')
        assert difference(baseline, shifted, (85, 65, 135, 115)) > 20, 'same-bounds change not applied'
        assert difference(baseline, shifted, (165, 65, 215, 115)) < 1
        client.send('clear')
        assert difference(shifted, capture('clear-pending'), (0, 0, 320, 240)) < 1
        client.send('commit')
        assert difference(baseline, capture('clear'), (0, 0, 320, 240)) < 1, 'clear left trails'
        client.send('set outside'); client.send('commit')
        outside = capture('surface-clipped')
        assert difference(baseline, outside, (280, 30, 310, 160)) > 20
        assert difference(baseline, outside, (330, 30, 370, 160)) < 1
        client.send('set split'); client.send('commit')
        split = capture('split')
        assert difference(baseline, split, (30, 30, 70, 160)) > 20
        assert difference(baseline, split, (100, 30, 180, 160)) < 1
        client.send('destroy')
        assert difference(split, capture('destroy-pending'), (0, 0, 320, 240)) < 1
        client.send('commit')
        assert difference(baseline, capture('destroyed'), (0, 0, 320, 240)) < 1
        client.send('create'); client.send('set empty'); client.send('commit')
        assert difference(baseline, capture('empty'), (0, 0, 320, 240)) < 1
        client.send('destroy'); client.send('create'); client.send('set hole'); client.send('commit')
        assert difference(hole, capture('recreated'), (0, 0, 320, 240)) < 1
        client.send('manager-destroy'); client.send('set rounded'); client.send('commit')
        capture('rounded')
        rounded = capture('rounded-stable')
        client.send('unmap'); capture('unmapped'); client.send('remap')
        assert difference(rounded, capture('remapped'), (0, 0, 320, 240)) < 1
        client.send('set hole'); client.send('commit')
        config.write_text(config.read_text().replace('enabled = true', 'enabled = false', 1))
        wait_for(lambda: client.send('caps') == 'OK 0')
        assert difference(baseline, capture('disabled'), (0, 0, 320, 240)) < 1
        config.write_text(config.read_text().replace('enabled = false', 'enabled = true', 1))
        wait_for(lambda: client.send('caps') == 'OK 1')
        assert difference(hole, capture('enabled'), (0, 0, 320, 240)) < 1
        rules.write_text('[[layer]]\nnamespace = "aqueous.blur.client"\nblur = false\n')
        wait_for(lambda: difference(baseline, capture('denied'), (30, 30, 70, 160)) < 1)
        rules.write_text('')
        wait_for(lambda: difference(baseline, capture('allowed'), (30, 30, 70, 160)) > 20)
        for transform in ('normal', '90', '180', '270', 'flipped', 'flipped-90', 'flipped-180', 'flipped-270'):
            request = {'op': 'set', 'changes': [{'name': 'HEADLESS-1', 'scale': 1.25, 'transform': transform}]}
            with socket_module.socket(socket_module.AF_UNIX) as connection:
                connection.connect(str(runtime / 'aqueous/outputd.sock'))
                connection.sendall(json.dumps(request).encode() + b'\n')
                response = json.loads(connection.makefile().readline())
                assert response['ok'], response
            client.send('clear'); client.send('commit')
            transformed_baseline = capture(f'{transform}-baseline')
            client.send('set hole'); client.send('commit')
            transformed = capture(f'{transform}-hole')
            assert difference(transformed_baseline, transformed, (38, 38, 87, 200)) > 20, transform
            assert difference(transformed_baseline, transformed, (107, 82, 168, 143)) < 1, transform
        with socket_module.socket(socket_module.AF_UNIX) as connection:
            connection.connect(str(runtime / 'aqueous/outputd.sock'))
            connection.sendall(json.dumps({'op': 'set', 'changes': [{'name': 'HEADLESS-1', 'scale': 1, 'transform': 'normal'}]}).encode() + b'\n')
            assert json.loads(connection.makefile().readline())['ok']
        assert client.send('duplicate') == 'EXPECTED_ERROR' 
        client.close()
        client = Client(fixture, env)
        clients.append(client)
        assert client.send('dead-surface') == 'EXPECTED_ERROR'
        client.close()
        rules.write_text('[[window]]\napp_id = "aqueous.blur.client"\nfloating = true\nwidth = 320\nheight = 240\nx = 0\ny = 0\n')
        subprocess.run([str(CTL), 'session', 'reload', '--json'], env=env,
                       check=True, capture_output=True, timeout=10)
        for mode in ('toplevel', 'geometry', 'popup', 'app-popup', 'nested-popup'):
            role_client = Client(fixture, env, mode)
            clients.append(role_client)
            def role_settled():
                scene = subprocess.check_output([str(CTL), 'scene'], env=env, text=True)
                return all(' disabled' in line for line in scene.splitlines() if 'window animation snapshot [tree]' in line)
            wait_for(role_settled)
            dx = dy = 0
            if mode in ('toplevel', 'geometry', 'app-popup'):
                windows = json.loads(subprocess.check_output([str(CTL), 'windows', '--json'], env=env, text=True))
                geometry = next(w['geometry'] for w in windows if w['app_id'] == 'aqueous.blur.client')
                dx, dy = geometry['x'], geometry['y']
                if mode == 'geometry':
                    dx -= 10
                    dy -= 15
            def role_box(box):
                return (box[0]+dx, box[1]+dy, box[2]+dx, box[3]+dy)
            role_baseline = capture(f'{mode}-baseline')
            role_client.send('set hole'); role_client.send('commit')
            wait_for(role_settled)
            role_blur = capture(f'{mode}-blur')
            (case / f'{mode}-scene.txt').write_text(subprocess.check_output([str(CTL), 'scene'], env=env, text=True))
            (case / f'{mode}-windows.json').write_text(subprocess.check_output([str(CTL), 'windows', '--json'], env=env, text=True))
            assert difference(role_baseline, role_blur, role_box((30, 30, 70, 160))) > 20, mode
            assert difference(role_baseline, role_blur, role_box((85, 65, 135, 115))) < 1, mode
            role_client.send('clear'); role_client.send('commit')
            assert difference(role_baseline, capture(f'{mode}-clear'), role_box((5, 5, 315, 235))) < 1, mode
            role_client.close()
        rules.write_text('')
        client = Client(fixture, env, 'subsurface')
        clients.append(client)
        baseline = capture('sub-baseline')
        client.send('set hole'); client.send('commit')
        assert difference(baseline, capture('sub-cached'), (0, 0, 320, 240)) < 1
        client.send('set shift'); client.send('commit'); client.send('parent')
        shifted = capture('sub-applied')
        assert difference(baseline, shifted, (85, 65, 135, 115)) > 20
        assert difference(baseline, shifted, (165, 65, 215, 115)) < 1
        client.send('above'); capture('sub-reordered')
        client.send('desync'); client.send('clear'); client.send('commit')
        assert difference(baseline, capture('sub-clear'), (0, 0, 320, 240)) < 1
        client.close()
        if os.environ.get('DMS_SOURCE') and not uncached:
            test_dms(fixture, env, case, capture, difference, clients)
        print(f'PASS {case.name}: protocol lifecycle, commit synchronization, exact masks, rules, reload, subsurfaces', flush=True)
        return hole
    finally:
        for client in clients:
            if client.proc.poll() is None:
                client.proc.terminate()
                client.proc.wait(timeout=5)
        compositor.terminate()
        compositor.wait(timeout=10)
        log.flush()
        text = (case / 'compositor.log').read_text()
        assert compositor.returncode == 0, text[-6000:]
        assert not any(s in text for s in ('panic:', 'Vulkan backdrop blur failed', 'Validation Error', 'cleaning up ')), text[-6000:]


def scene(env):
    return subprocess.check_output([str(CTL), 'scene'], env=env, text=True, timeout=10)


def settled(env):
    return all(' disabled' in line for line in scene(env).splitlines()
               if 'window animation snapshot [tree]' in line)


def wait_settled(env):
    previous = None
    since = time.monotonic()

    def stable():
        nonlocal previous, since
        text = scene(env)
        if text != previous or any('window animation snapshot [tree]' in line and ' disabled' not in line
                                   for line in text.splitlines()):
            previous, since = text, time.monotonic()
        return time.monotonic() - since > .15

    wait_for(stable)


def marker_enabled(text, label):
    return any(line.lstrip(' │├─└').split(' [rect]')[0] == label and ' disabled' not in line
               for line in text.splitlines() if ' [rect]' in line)


def window_geometry(env, app_id):
    windows = json.loads(subprocess.check_output([str(CTL), 'windows', '--json'], env=env, text=True))
    return next((w['geometry'] for w in windows if w['app_id'] == app_id), None)


def settle_fixture_window(client, env):
    # The fixture has no continuously drawing event loop. Drive the commits
    # needed to finish initial placement before taking a pixel reference.
    def placed():
        client.send('commit')
        geometry = window_geometry(env, 'aqueous.blur.client')
        return geometry and geometry['x'] == 32 and geometry['y'] == 32
    wait_for(placed)
    wait_settled(env)


def test_ownership(fixture, env, case, capture, difference, clients):
    rules = Path(env['AQUEOUS_RULES'])
    window_rule = ('[[window]]\napp_id = "aqueous.blur.client"\nfloating = true\n'
                   'width = 320\nheight = 240\nx = 32\ny = 32\n')
    layer_rule = '[[layer]]\nnamespace = "aqueous.blur.client"\nblur = true\nblur_popups = true\n'
    rules.write_text(window_rule + layer_rule)
    time.sleep(.3)
    for mode, label in (('toplevel', 'backdrop blur marker'),
                        ('layer', 'layer backdrop blur marker'),
                        ('popup', 'layer popup backdrop blur marker')):
        client = Client(fixture, env, mode, 'none')
        clients.append(client)
        if mode == 'toplevel':
            settle_fixture_window(client, env)
        else:
            wait_settled(env)
        dx = dy = 0
        if mode == 'toplevel':
            geometry = window_geometry(env, 'aqueous.blur.client')
            dx, dy = geometry['x'], geometry['y']
        bounds = (dx + 20, dy + 20, dx + 300, dy + 200)

        def state(name, fallback, native, reference=None):
            wait_settled(env)
            image = capture(f'ownership-{mode}-{name}')
            text = scene(env)
            (case / f'ownership-{mode}-{name}.txt').write_text(text)
            assert marker_enabled(text, label) == fallback, (mode, name, 'fallback', text)
            assert marker_enabled(text, 'native background blur marker') == native, (mode, name, 'native', text)
            if reference is not None:
                assert difference(reference, image, bounds) < 1, (mode, name, 'pixels changed')
            return image

        fallback = state('no-object', True, False)
        client.send('create')
        state('create-pending', True, False, fallback)
        client.send('commit')
        state('unused', True, False, fallback)
        client.send('set hole')
        state('region-pending', True, False, fallback)
        client.send('commit')
        native = state('region', False, True)
        client.send('set empty')
        state('empty-pending', False, True, native)
        client.send('commit')
        sharp = state('empty', False, False)
        assert difference(fallback, sharp, bounds) > 20, (mode, 'fallback must visibly blur')
        assert difference(native, sharp, (dx+30, dy+30, dx+70, dy+160)) > 20
        assert difference(native, sharp, (dx+85, dy+65, dx+135, dy+115)) < 1
        client.send('clear'); client.send('commit')
        state('null', False, False, sharp)
        client.send('destroy')
        state('destroy-pending', False, False, sharp)
        client.send('commit')
        state('destroyed', True, False, fallback)
        client.send('create'); client.send('commit')
        state('recreated-unused', True, False, fallback)
        client.send('set hole'); client.send('commit')
        state('recreated-region', False, True, native)
        denied = (window_rule + 'blur = false\n' + layer_rule if mode == 'toplevel'
                  else window_rule + layer_rule.replace('blur = true', 'blur = false'))
        rules.write_text(denied)
        wait_for(lambda: not marker_enabled(scene(env), 'native background blur marker'))
        state('rule-denied', False, False, sharp)
        rules.write_text(window_rule + layer_rule)
        wait_for(lambda: marker_enabled(scene(env), 'native background blur marker'))
        state('rule-restored', False, True, native)
        client.send('destroy'); client.send('create')
        state('recreate-pending', False, True, native)
        client.send('commit')
        state('recreate-committed', True, False, fallback)
        if mode == 'toplevel':
            test_snapshot_ownership(client, env, case, rules, window_rule, layer_rule)
        client.close()

    early = Client(fixture, env, 'toplevel', 'early')
    clients.append(early)
    settle_fixture_window(early, env)
    text = scene(env)
    (case / 'ownership-before-map.txt').write_text(text)
    assert marker_enabled(text, 'backdrop blur marker'), text
    assert not marker_enabled(text, 'native background blur marker'), text
    early.close()
    print('PASS blur ownership: unused objects, explicit regions, empty/null, destroy/recreate and first map', flush=True)


def test_snapshot_ownership(client, env, case, rules, window_rule, layer_rule):
    # Moving a floating window through a rule produces a frozen moving snapshot.
    # Repeat after explicit requests and committed destruction;
    # the latter leaves a live attachment allocated but no longer authoritative.
    for request in ('empty', 'hole', 'destroyed'):
        owned = request != 'destroyed'
        client.send('set hole' if request == 'hole' else 'clear'); client.send('commit')
        if not owned:
            client.send('destroy'); client.send('commit')
        rules.write_text(layer_rule + window_rule.replace('x = 32', 'x = 400'))
        observed = []

        def moving():
            text = scene(env)
            active = any('window animation snapshot [tree]' in line and ' disabled' not in line
                         for line in text.splitlines())
            if active:
                observed.append(text)
            return active

        wait_for(moving)
        text = observed[-1]
        (case / f'ownership-animation-{request}.txt').write_text(text)
        assert marker_enabled(text, 'animation backdrop blur marker') == (not owned), text
        assert marker_enabled(text, 'native background blur marker') == (request == 'hole'), text
        # Change live ownership while the old pixels are still moving. The
        # snapshot keeps its captured policy until it hands back to live content.
        if owned:
            client.send('destroy')
        else:
            client.send('create'); client.send('clear')
        client.send('commit')
        text = scene(env)
        (case / f'ownership-animation-{request}-live-change.txt').write_text(text)
        assert any('window animation snapshot [tree]' in line and ' disabled' not in line
                   for line in text.splitlines()), 'live ownership change missed the animation'
        assert marker_enabled(text, 'animation backdrop blur marker') == (not owned), text
        assert marker_enabled(text, 'native background blur marker') == (request == 'hole'), text
        wait_settled(env)
        assert marker_enabled(scene(env), 'backdrop blur marker') == owned
        rules.write_text(window_rule + layer_rule)
        time.sleep(.3)
        wait_settled(env)
        if not owned:
            client.send('destroy')
        client.send('create'); client.send('commit')
    print('PASS frozen blur ownership: empty, nonempty, destruction and live changes during animation', flush=True)


def test_gtk(fixture, env, case, capture, difference, clients):
    if subprocess.run(['pkg-config', '--exists', 'gtk4']).returncode != 0:
        print('SKIP GTK4 smoke: GTK4 development files unavailable', flush=True)
        return
    executable = ARTIFACTS / 'gtk-background-effect'
    if not executable.exists():
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk4'], text=True))
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        str(ROOT / 'scripts/fixtures/gtk-background-effect.c'), *flags, '-o', str(executable)], check=True)
    rules = Path(env['AQUEOUS_RULES'])
    rules.write_text('[[window]]\napp_id = "org.aqueous.GtkBlurProbe"\nfloating = true\n'
                     'width = 320\nheight = 240\nx = 32\ny = 32\nopacity = 0.75\n')
    subprocess.run([str(CTL), 'session', 'reload', '--json'], env=env,
                   check=True, capture_output=True, timeout=10)
    background = Client(fixture, env)
    clients.append(background)
    images = []
    for disabled in (False, True):
        gtk_env = dict(env, GDK_BACKEND='wayland', GSK_RENDERER='cairo', GTK_A11Y='none',
                       GTK_THEME='Adwaita', WAYLAND_DEBUG='1',
                       GDK_WAYLAND_DISABLE='ext_background_effect_manager_v1' if disabled else '')
        log_path = case / f'gtk-{disabled}.log'
        with log_path.open('w') as log:
            proc = subprocess.Popen([str(executable)], env=gtk_env, stdout=log, stderr=log)
            try:
                def ready():
                    assert proc.poll() is None, log_path.read_text()
                    return 'GTK_BLUR_READY' in log_path.read_text() and settled(env)
                wait_for(ready)
                wait_settled(env)
                text = scene(env)
                (case / f'gtk-{disabled}-scene.txt').write_text(text)
                assert marker_enabled(text, 'backdrop blur marker'), text
                images.append(capture(f'gtk-{disabled}'))
            finally:
                proc.terminate(); proc.wait(timeout=5)
        trace = log_path.read_text()
        if disabled:
            assert '.get_background_effect(' not in trace
        elif '.get_background_effect(' not in trace:
            print('SKIP GTK native-object assertion: installed GTK does not create the object', flush=True)
        else:
            assert '.set_blur_region(' not in trace, 'plain GTK fixture unexpectedly requests native blur'
        wait_for(lambda: 'Aqueous GTK blur probe' not in scene(env))
    assert difference(images[0], images[1], (62, 62, 322, 242)) < 1, 'GTK native discovery changed fallback blur'
    background.close()
    print('PASS GTK4 opacity/fallback pixels with native protocol enabled and disabled', flush=True)


def test_dms(fixture, env, case, capture, difference, clients):
    source = Path(os.environ['DMS_SOURCE'])
    supported = os.environ.get('AQUEOUS_TEST_NO_EFFECTS') != '1'
    helper_bin = case / 'helper-bin'
    helper_bin.mkdir()
    helper_calls = case / 'helper-calls'
    helper = helper_bin / 'aqueous-config'
    helper.write_text('#!/bin/sh\nprintf \'called\\n\' >> ' + shlex.quote(str(helper_calls)) + '\nexit 1\n')
    helper.chmod(0o755)
    qml_root = case / 'dms' / 'quickshell'
    shutil.copytree(source / 'quickshell', qml_root, ignore=shutil.ignore_patterns('.qmlls.ini'))
    shutil.copytree(source / 'dank-qml-common', qml_root.parent / 'dank-qml-common')
    (qml_root / '.qmlls.ini').touch()
    qml = qml_root / 'NativeBlurTest.qml'
    shutil.copyfile(ROOT / 'scripts/fixtures/dms-background-effect.qml', qml)
    qml_env = dict(env, QT_QPA_PLATFORM='wayland', QT_QUICK_BACKEND='software',
                   DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(case / 'no-session-bus'),
                   XDG_CACHE_HOME=str(case / 'cache'), XDG_STATE_HOME=str(case / 'state'),
                   DMS_DISABLE_MATUGEN='1',
                   PATH=str(helper_bin) + os.pathsep + str(ROOT / 'zig-out/bin') + os.pathsep + env.get('PATH', ''))
    settings = Path(env['XDG_CONFIG_HOME']) / 'DankMaterialShell'
    settings.mkdir(parents=True, exist_ok=True)
    (settings / 'settings.json').write_text(json.dumps({'blurEnabled': True}))
    assert subprocess.check_output(['dms', 'blur', 'check'], env=qml_env, text=True).strip() == ('supported' if supported else 'unsupported')
    rules = Path(env['AQUEOUS_RULES'])
    user_rules = '# Preserve this user rule\n[[layer]]\nnamespace = "user-panel"\nblur = true\n'
    rules.write_text(user_rules)
    config_paths = [rules, Path(env['AQUEOUS_CONFIG'])]
    unchanged = [(path, path.read_bytes(), path.stat().st_mtime_ns) for path in config_paths]
    log_path = case / 'dms-qml.log' 
    background = Client(fixture, env) if supported else None
    if background:
        clients.append(background)
    proc = subprocess.Popen(['qs', '-p', str(qml)], env=qml_env, stdout=log_path.open('w'), stderr=subprocess.STDOUT)
    try:
        def ipc(function, *args):
            return subprocess.check_output(['qs', 'ipc', '-p', str(qml), 'call', 'nativeBlurTest', function, *args], env=qml_env, text=True, timeout=10).strip()
        def ready():
            assert proc.poll() is None, log_path.read_text()
            result = subprocess.run(['qs', 'ipc', '-p', str(qml), 'call', 'nativeBlurTest', 'status'], env=qml_env, capture_output=True, text=True, timeout=5)
            (case / 'dms-status.txt').write_text(result.stdout + result.stderr)
            if result.returncode != 0:
                return False
            status = json.loads(result.stdout)
            return status.get('loaded') and status.get('supported') == supported and status.get('enabled') == supported
        wait_for(ready, 30)
        status = json.loads(ipc('status'))
        assert status['supported'] == supported and status['enabled'] == supported and status['loaded'], status
        baseline = capture('dms-disabled')
        ipc('enabled', 'true')
        if supported:
            wait_for(lambda: difference(baseline, capture('dms-enabled'), (45, 45, 75, 155)) > 20)
            rounded = capture('dms-rounded')
            assert difference(baseline, rounded, (20, 20, 24, 24)) < 1
            ipc('preference', 'false')
            wait_for(lambda: not json.loads(ipc('status'))['enabled'])
            wait_for(lambda: difference(baseline, capture('dms-preference-off'), (0, 0, 320, 240)) < 1)
            ipc('preference', 'true')
            wait_for(lambda: json.loads(ipc('status'))['enabled'])
            wait_for(lambda: difference(baseline, capture('dms-preference-on'), (45, 45, 75, 155)) > 20)
            ipc('clipped', 'true')
            wait_for(lambda: difference(baseline, capture('dms-clipped'), (45, 45, 75, 155)) < 1)
            assert difference(baseline, capture('dms-clipped-visible'), (120, 45, 240, 155)) > 20
            ipc('shown', 'false')
            wait_for(lambda: difference(baseline, capture('dms-hidden'), (0, 0, 320, 240)) < 1)
            ipc('shown', 'true')
            wait_for(lambda: difference(baseline, capture('dms-remapped'), (120, 45, 240, 155)) > 20)
        else:
            ipc('preference', 'false')
            ipc('preference', 'true')
            assert not json.loads(ipc('status'))['enabled']
            assert difference(baseline, capture('dms-unsupported'), (0, 0, 320, 240)) < 1
        ipc('enabled', 'false')
        wait_for(lambda: difference(baseline, capture('dms-cleared'), (0, 0, 320, 240)) < 1)
        time.sleep(.4)
        for path, contents, mtime in unchanged:
            assert path.read_bytes() == contents and path.stat().st_mtime_ns == mtime, f'DMS changed {path}'
        assert not helper_calls.exists(), 'DMS invoked aqueous-config for native blur'
        print('PASS actual DMS WindowBlur: discovery, regions, preferences, lifecycle and no helper/config writes', flush=True)
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        if background:
            background.close()


if __name__ == '__main__':
    fixture = build_fixture()
    cached = run(fixture)
    if os.environ.get('AQUEOUS_TEST_NO_EFFECTS') == '1' or os.environ.get('AQUEOUS_TEST_DMS_ONLY') == '1':
        raise SystemExit(0)
    uncached = run(fixture, True)
    assert max(ImageStat.Stat(ImageChops.difference(cached, uncached)).mean) < 1
    print('PASS cached/uncached image equivalence', flush=True)
