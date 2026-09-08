#!/usr/bin/env python3
"""Pixel regression for #53 in an isolated two-output headless compositor.

Requires Pillow, grim, wlrctl, a C compiler and Wayland development tools.
Use --renderer pixman with a -Dvulkan-effects=false diagnostic build, or vulkan
with a production build and GPU access. Graphical tests must run serially.
Artifacts, including failures, remain in the printed /tmp directory.
"""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=['pixman', 'vulkan'], default='pixman')
    parser.add_argument('--xwayland', action='store_true', help='Use the existing X11 fixture for the red fullscreen client')
    parser.add_argument('--rate', type=float, default=0, help='0 selects the default rate (7)')
    parser.add_argument('--disabled', action='store_true', help='Disable transitions in config')
    parser.add_argument('--no-animations', action='store_true', help='Expect a build with animations compiled out')
    parser.add_argument('--scale', type=float, default=1)
    parser.add_argument('--transform', default='normal', choices=['normal', '90', '180', '270'])
    args = parser.parse_args()
    assert args.rate >= 0 and args.scale > 0
    work = Path(tempfile.mkdtemp(prefix='aqueous-fullscreen-transition-'))
    print(f'Artifacts: {work}', flush=True)
    runtime = work / 'runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
    for key, filename in [('AQUEOUS_CONFIG', 'wm.toml'), ('AQUEOUS_RULES', 'rules.toml'),
                          ('AQUEOUS_LAYOUT', 'layout.toml'), ('AQUEOUS_INPUT', 'input.toml'),
                          ('AQUEOUS_OUTPUTS', 'outputs.toml')]:
        env[key] = str(work / filename)
        (work / filename).write_text('')
    (work / 'wm.toml').write_text(f'''[opacity]
enabled = false
[blur]
enabled = false
[input]
focus_follows_mouse = false
mouse_follows_focus = false
[workspace_transition]
enabled = {str(not args.disabled).lower()}
rate = {args.rate}
[keybinds]
focus_workspace_1 = "Super+1"
focus_workspace_2 = "Super+2"
focus_workspace_3 = "Super+3"
focus_workspace_4 = "Super+4"
''')
    processes, logs, results = [], [], []

    def run(command):
        p = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                           text=True, timeout=15)
        assert p.returncode == 0, f'{command}: {p.stderr}'
        return p.stdout

    def launch(command, name):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        child_env = env if name == 'compositor' else dict(env, WAYLAND_DEBUG='1')
        p = subprocess.Popen(list(map(str, command)), env=child_env, stdin=subprocess.PIPE,
                             stdout=log, stderr=log)
        processes.append(p)
        return p

    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert server.poll() is None, (work / 'compositor.log').read_text()[-5000:]
            result = predicate()
            if result:
                return result
            time.sleep(.025)
        raise AssertionError(message)

    def ctl(*arguments):
        return run([args.ctl, *arguments])

    def windows():
        return json.loads(ctl('windows', '--json'))

    def identity(w):
        return w['app_id'] or w['class']

    def window(name):
        return next((w for w in windows() if identity(w) == name), None)

    def state(w, fullscreen):
        ctl('window', 'state', '--id', w['id'], '--fullscreen', str(fullscreen).lower(), '--json')
        wait_for(lambda: ('fullscreen' in window(identity(w))['states']) == fullscreen,
                 'Fullscreen state did not change')

    def activate(w):
        ctl('window', 'activate', '--id', w['id'], '--json')

    def key(number):
        run(['wlrctl', 'keyboard', 'type', str(number), 'modifiers', 'SUPER'])

    def outputs(request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(request).encode() + b'\n')
            return json.loads(client.makefile().readline())

    def capture(label, output):
        path = work / f'{label}.png'
        run(['grim', '-o', output, path])
        with Image.open(path) as image:
            return image.convert('RGB')

    def row_counts(image):
        row = image.crop((0, image.height // 2, image.width, image.height // 2 + 1))
        return Counter(row.get_flattened_data() if hasattr(row, 'get_flattened_data') else row.getdata())

    def no_snapshots(label):
        scene = ctl('scene')
        (work / f'{label}-scene.txt').write_text(scene)
        assert not any('window animation snapshot [tree]' in line and 'disabled' not in line
                       for line in scene.splitlines()), 'Enabled snapshot after settling'

    def spawn(name, color):
        if args.xwayland and name == 'issue53-red':
            launch([work / 'x11-client', name, color[-6:]], name)
        else:
            launch([work / 'client', name, color, '1'], name)
        return wait_for(lambda: window(name), f'{name} did not map')

    def configure_sizes(name):
        if args.xwayland and name == 'issue53-red':
            return re.findall(r'CONFIGURE (\d+) (\d+)', (work / f'{name}.log').read_text())
        return re.findall(r'xdg_toplevel[@#]\d+\.configure\((\d+), (\d+),',
                          (work / f'{name}.log').read_text())

    success = False
    try:
        protocol = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip()) / 'stable/xdg-shell/xdg-shell.xml'
        run(['wayland-scanner', 'client-header', protocol, work / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', protocol, work / 'xdg-shell-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/scrolling-vertical-reference.c', work / 'xdg-shell-protocol.c',
             '-o', work / 'client', *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))])
        startup = 'true'
        if args.xwayland:
            run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-DX11',
                 ROOT / 'scripts/fixtures/window-remap.c', '-o', work / 'x11-client', '-lX11'])
            startup = 'printf %s "$DISPLAY" > ' + shlex.quote(str(work / 'display'))
        server = launch([args.compositor.resolve(), *([] if args.xwayland else ['-no-xwayland']),
                         '-log-level', 'debug', '-c', startup], 'compositor')
        env['WAYLAND_DISPLAY'] = wait_for(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'No Wayland socket')
        if args.xwayland:
            env['DISPLAY'] = wait_for(lambda: (work / 'display').read_text() if (work / 'display').exists() else None, 'No XWayland DISPLAY')
        wait_for(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'No output socket')
        available = outputs({'op': 'list'})['outputs']
        # Exercise a nonzero output origin and both left/right containment.
        available.sort(key=lambda o: o['x'])
        other, owner = available[0]['name'], available[1]['name']
        response = outputs({'op': 'set', 'changes': [{'name': owner, 'scale': args.scale, 'transform': args.transform}]})
        assert response.get('ok'), response
        green = spawn('issue53-green', 'ff00ff00')
        ctl('window', 'move', '--id', green['id'], '--output', other, '--json')
        activate(green)
        state(green, True)
        red = spawn('issue53-red', 'ffff0000')
        ctl('window', 'move', '--id', red['id'], '--output', owner, '--json')
        activate(red)
        state(red, True)
        owner_state = next(o for o in outputs({'op': 'list'})['outputs'] if o['name'] == owner)
        run(['wlrctl', 'pointer', 'move', '-10000', '-10000'])
        run(['wlrctl', 'pointer', 'move', str(owner_state['x'] + 100), str(owner_state['y'] + 100)])
        time.sleep(.3)
        reference = capture('red-reference', owner)
        assert row_counts(reference)[(255, 0, 0)] == reference.width
        logical_width = reference.width / args.scale
        duration = math.log(logical_width / .5) / (args.rate or 7)
        animated = not (args.disabled or args.no_animations)
        settle = duration + .25 if animated else .15
        key(2)
        time.sleep(max(settle, .6))
        blue = spawn('issue53-blue', 'ff0000ff')
        time.sleep(.3)
        green_reference = capture('neighbor-reference', other)
        assert row_counts(green_reference)[(0, 255, 0)] == green_reference.width

        def transition(label, number, source, target, focus=None):
            fullscreen_before = {identity(w): configure_sizes(identity(w)) for w in windows()
                                 if w['output'] == owner and 'fullscreen' in w['states']}
            start = time.monotonic()
            key(number)
            early_state = windows()
            (work / f'{label}-windows.json').write_text(json.dumps(early_state, indent=2))
            if focus:
                assert any(w['id'] == focus['id'] and 'focused' in w['states'] for w in early_state), early_state
            samples = []
            while time.monotonic() - start < settle:
                image = capture(f'{label}-{len(samples):03}', owner)
                counts = row_counts(image)
                elapsed = time.monotonic() - start
                samples.append(dict(time=elapsed, source=counts[source], target=counts[target]))
                neighbor = capture(f'{label}-neighbor-{len(samples):03}', other)
                assert neighbor.tobytes() == green_reference.tobytes(), f'{label}: slide leaked onto neighbor'
                time.sleep(.02)
            no_snapshots(label)
            final = row_counts(capture(f'{label}-settled', owner))
            assert final[target] > reference.width * .9, (label, final)
            # Require a visibly intermediate boundary early in the slide, not
            # merely a fast final switch or a change at the center pixel.
            if animated and (args.rate or 7) <= 7:
                assert any(s['time'] < duration * .65 and
                           reference.width * .03 < s['source'] < reference.width * .97 and
                           s['target'] > reference.width * .03 for s in samples), (label, samples)
            for name, before_sizes in fullscreen_before.items():
                after_sizes = configure_sizes(name)
                assert all(size == before_sizes[-1] for size in after_sizes[len(before_sizes):]), 'Workspace switch resized fullscreen client'
                assert 'fullscreen' in window(name)['states']
            results.append(dict(case=label, samples=samples))
            print(f'PASS {label}', flush=True)

        R, B, K = (255, 0, 0), (0, 0, 255), (0, 0, 0)
        activate(red)
        time.sleep(max(settle, .6))
        transition('fullscreen-to-ordinary', 2, R, B, blue)
        transition('ordinary-to-fullscreen', 1, B, R, red)
        transition('fullscreen-to-empty', 3, R, K)
        transition('empty-to-fullscreen', 1, K, R, red)
        # A transparent fullscreen client makes the opaque backing itself the
        # measured moving boundary; an unanimated live backing fails this case.
        key(4)
        time.sleep(max(settle, .6))
        black = spawn('issue53-transparent', '00000000')
        state(black, True)
        time.sleep(.2)
        transition('transparent-fullscreen-to-ordinary', 2, K, B, blue)
        transition('ordinary-to-transparent-fullscreen', 4, B, K, black)
        activate(red)
        state(red, True)
        time.sleep(max(settle, .6))
        key(2)
        time.sleep(.08)
        key(1)
        time.sleep(.08)
        key(3)
        time.sleep(max(settle, .6))
        no_snapshots('rapid-switch')
        assert row_counts(capture('rapid-empty', owner))[K] == reference.width
        # Mode changes during a slide must settle into the new style.
        key(1)
        time.sleep(.08)
        state(red, False)
        time.sleep(max(settle, .6))
        no_snapshots('toggle-during-slide')
        assert row_counts(capture('toggle-settled', owner))[R] > reference.width * .9
        state(red, True)
        time.sleep(.15)
        no_snapshots('fullscreen-toggle-snaps')
        # Move the outgoing window to a third workspace while its snapshot is
        # still visible. The old viewport must release that snapshot immediately.
        records = json.loads(ctl('shell', 'snapshot', '--json'))['upsert']
        owner_id = next(r['id'] for r in records if r['kind'] == 'output' and r['name'] == owner)
        third = next(r['id'] for r in records if r['kind'] == 'workspace' and
                     r['output'] == owner_id and r['name'] == '3')
        key(2)
        time.sleep(.08)
        ctl('window', 'move', '--id', red['id'], '--workspace-id', third, '--json')
        time.sleep(max(settle, .6))
        no_snapshots('move-during-slide')
        assert window('issue53-red')['workspace'] == 3
        assert row_counts(capture('move-settled', owner))[B] > reference.width * .9
        activate(red)
        time.sleep(max(settle, .6))
        key(2)
        time.sleep(.08)
        ctl('overview', 'show', '--output', owner, '--json')
        time.sleep(.2)
        no_snapshots('overview-during-slide')
        ctl('overview', 'hide', '--json')
        time.sleep(.2)
        activate(red)
        time.sleep(max(settle, .6))
        key(2)
        time.sleep(.08)
        response = outputs({'op': 'set', 'changes': [{'name': owner, 'x': owner_state['x'] + 20}]})
        assert response.get('ok'), response
        time.sleep(max(settle, .6))
        no_snapshots('output-moved-during-slide')
        assert row_counts(capture('output-moved-settled', owner))[B] > reference.width * .9
        activate(red)
        time.sleep(max(settle, .6))
        key(2)
        time.sleep(.08)
        ctl('window', 'close', '--id', red['id'], '--json')
        time.sleep(max(settle, .6))
        no_snapshots('close-during-slide')
        assert row_counts(capture('close-settled', owner))[B] > reference.width * .9
        activate(black)
        state(black, True)
        time.sleep(max(settle, .6))
        key(2)
        time.sleep(.08)
        response = outputs({'op': 'set', 'changes': [{'name': owner, 'enabled': False}]})
        assert response.get('ok'), response
        time.sleep(max(settle, .6))
        no_snapshots('output-disabled')
        print('PASS interruption and output lifecycle checks', flush=True)
        success = True
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
        for log in logs:
            log.close()
        (work / 'results.json').write_text(json.dumps(dict(passed=success, renderer=args.renderer,
            rate=args.rate, disabled=args.disabled, no_animations=args.no_animations, xwayland=args.xwayland,
            scale=args.scale, transform=args.transform, results=results), indent=2))
        print(f'Results: {work / "results.json"}', flush=True)


if __name__ == '__main__':
    main()
