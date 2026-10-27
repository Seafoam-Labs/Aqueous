#!/usr/bin/env python3
"""Check configurable corners and live reloads in a private headless compositor.

Use an effects build for --renderer vulkan, or -Dvulkan-effects=false for pixman.
Requires cc, wayland-scanner, Wayland development files, grim and Python/Pillow.
Vulkan also requires a render device; --uncached checks the uncached blur path.
"""
import argparse
import json
import math
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('vulkan', 'pixman'), default='vulkan')
    parser.add_argument('--scale', type=float, default=1)
    parser.add_argument('--uncached', action='store_true')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-corners-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=20)

    def launch(command, label):
        log = (work / f'{label}.log').open('w')
        logs.append(log)
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=log, stderr=log, text=True)
        children.append(child)
        return child

    def wait(predicate, description):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()[-4000:]
            result = predicate()
            if result:
                return result
            time.sleep(.05)
        raise AssertionError(description)

    def command(value):
        client.stdin.write(value + '\n')
        client.stdin.flush()

    def window():
        return next((w for w in json.loads(run([args.ctl.resolve(), 'windows', '--json']))
                     if w.get('app_id') == 'corners-0'), None)

    def configure(radius, blur=False, border=4, floating=False, reload=True):
        source = f'''[blur]
enabled = {str(blur).lower()}
radius = 8
passes = 2
[workspace_transition]
enabled = false
[input]
focus_follows_mouse = false
'''
        if radius is not None:
            source += f'[decoration]\ncorner_radius = {radius}\n'
        (work / 'config.toml').write_text(source)
        (work / 'rules.toml').write_text('[[window]]\napp_id = "corners-0"\nfloating = true\nwidth = 120\nheight = 90\n' if floating else '')
        (work / 'layout.toml').write_text(f'''[layout]
default = "{'floating' if floating else 'tile'}"
gaps_outer = 40
gaps_inner = 8
border_width = {border}
border_focused = 0xFF00FF00
border_normal = 0xFF00FF00
''')
        if reload:
            run([args.ctl.resolve(), 'session', 'reload', '--json'])

    def distance(x, y, width, height, radius):
        qx = abs(x - width / 2) - width / 2 + radius
        qy = abs(y - height / 2) - height / 2 + radius
        return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius

    def check(name, radius, border=4, fullscreen=False):
        path = work / f'{name}.png'
        # Poll pixels rather than assume a reload acknowledgement is a frame.
        def matches():
            w = window()
            if not w:
                return False
            run(['grim', '-o', 'HEADLESS-1', path])
            with Image.open(path) as capture:
                image = capture.convert('RGB')
            g = w['geometry']
            x, y, width, height = (g[k] for k in ('x', 'y', 'width', 'height'))
            scale = args.scale
            effective = min(radius, width / 2, height / 2) if args.renderer == 'vulkan' and not fullscreen else 0
            bw = 0 if fullscreen else border
            # Check the whole silhouette, ignoring its antialiasing fringe.
            counts = [0, 0, 0]
            for py in range(max(0, math.floor((y - bw - 4) * scale)), min(image.height, math.ceil((y + height + bw + 4) * scale)), 3):
                for px in range(max(0, math.floor((x - bw - 4) * scale)), min(image.width, math.ceil((x + width + bw + 4) * scale)), 3):
                    lx, ly = (px + .5) / scale - x, (py + .5) / scale - y
                    inner = distance(lx, ly, width, height, effective)
                    outer = distance(lx + bw, ly + bw, width + 2 * bw, height + 2 * bw,
                                     effective + bw if effective else 0)
                    margin = 1.5 / scale
                    r, green, b = image.getpixel((px, py))
                    if inner < -margin:
                        counts[0] += 1
                        if not (r > green + 30 and r > b + 30):
                            return False
                    elif outer > margin:
                        counts[2] += 1
                        if max(r, green, b) > 20:
                            return False
                    elif inner > margin and outer < -margin:
                        counts[1] += 1
                        if not (green > r + 30 and green > b + 30):
                            return False
            return counts[0] > 100 and (fullscreen or counts[2] > 0) and (not bw or counts[1] > 0)
        wait(matches, f'{name}: radius {radius} silhouette mismatch ({path})')
        print(f'PASS {name}', flush=True)

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-dialog': protocols / 'staging/xdg-dialog/xdg-dialog-v1.xml',
            'aqueous-input': ROOT / 'protocol/aqueous-input-management-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        flags = shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-dialog.c', *generated, *flags, '-o', work / 'client'])
        for name in ('home', 'config', 'cache', 'state', 'runtime'):
            (work / name).mkdir(mode=0o700)
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
                   XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer,
                   AQUEOUS_VULKAN_BLUR_UNCACHED='1' if args.uncached else '0')
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'outputs.toml').write_text(f'[[output]]\nname = "HEADLESS-1"\nmode = "1280x720@60"\nscale = {args.scale}\n')
        configure(None, reload=False)
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'info', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        env['AQUEOUS_SOCKET'] = str(wait(lambda: next((work / 'runtime/aqueous').glob('*/ipc.sock'), None), 'no IPC socket'))
        client = launch([work / 'client', 'corners'], 'client')
        command('create 0 -1 0')
        wait(window, 'window missing')
        check('default', 15)
        for blur in (False, True):
            for index, radius in enumerate((15, 0, 8, 15, 128)):
                configure(radius, blur)
                check(f'blur-{blur}-{index}-radius-{radius}', radius)
        configure(8, border=0)
        check('borderless', 8, border=0)
        configure(128, floating=True)
        wait(lambda: (w := window()) and min(w['geometry']['width'], w['geometry']['height']) < 256,
             'small floating geometry not applied')
        check('floating-clamped', 128)
        command('fullscreen 0 1')
        wait(lambda: (w := window()) and 'fullscreen' in w['states'], 'fullscreen not entered')
        check('fullscreen', 128, fullscreen=True)
        configure(0, floating=True)
        check('fullscreen-reload', 0, fullscreen=True)
        command('fullscreen 0 0')
        wait(lambda: (w := window()) and 'fullscreen' not in w['states'], 'fullscreen not exited')
        check('exit-fullscreen', 0)
        configure(None)
        check('removed-setting', 15)
        configure(-1)
        check('invalid-setting-default', 15)
        command('destroy-top 0')
        wait(lambda: window() is None, 'window not destroyed')
        configure(8)
        command('create 0 -1 0')
        wait(window, 'new window missing')
        check('new-window', 8)
        # Exercise the file monitor as well as explicit session reloads.
        marker = 'configuration hot-reloaded'
        old_reloads = (work / 'compositor.log').read_text().count(marker)
        config = work / 'config.toml'
        config.write_text(config.read_text().replace('corner_radius = 8', 'corner_radius = 3'))
        wait(lambda: (work / 'compositor.log').read_text().count(marker) > old_reloads,
             'automatic configuration reload not observed')
        check('automatic-reload', 3)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
