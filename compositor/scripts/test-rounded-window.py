#!/usr/bin/env python3
"""Pixel regression for #92: window masks with CSD padding and subsurfaces.

Requires Wayland development files, a C compiler, grim, and Pillow. All sessions
and configuration are private. --compositor can select an old binary to prove
that the padded-corner assertion fails before the fix.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import shlex
import subprocess
import tempfile
import threading
import time
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
parser.add_argument('--ctl', type=Path)
parser.add_argument('--quick', action='store_true')
parser.add_argument('--no-effects', action='store_true')
args = parser.parse_args()
ctl = (args.ctl or args.compositor.parent / 'aqueousctl').resolve()
work = Path(tempfile.mkdtemp(prefix='aqueous-rounded-window-'))
print(f'Artifacts: {work}', flush=True)

def run(command, env=None):
    return subprocess.run([str(s) for s in command], env=env, check=True,
                          capture_output=True, text=True, timeout=15).stdout

protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
sources = []
for name, xml in [('xdg-shell', 'stable/xdg-shell/xdg-shell.xml'),
                  ('viewporter', 'stable/viewporter/viewporter.xml'),
                  ('single-pixel', 'staging/single-pixel-buffer/single-pixel-buffer-v1.xml')]:
    run(['wayland-scanner', 'client-header', protocols / xml, work / f'{name}-client-protocol.h'])
    run(['wayland-scanner', 'private-code', protocols / xml, work / f'{name}.c'])
    sources.append(work / f'{name}.c')
run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
     ROOT / 'scripts/fixtures/rounded-window-client.c', *sources,
     '-o', work / 'client', *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))])


def case(scale, transform):
    path = work / f'{scale}-{transform}'
    path.mkdir()
    runtime = path / 'runtime'
    runtime.mkdir(mode=0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_', 'DMS_'))
           and k not in ('WAYLAND_DISPLAY', 'DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD', 'WAYLAND_DEBUG')}
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(path / 'config'),
               XDG_STATE_HOME=str(path / 'state'), XDG_CACHE_HOME=str(path / 'cache'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
               WLR_RENDERER='pixman' if args.no_effects else 'vulkan')
    for key, name in [('CONFIG', 'wm'), ('RULES', 'rules'), ('LAYOUT', 'layout'), ('INPUT', 'input'), ('OUTPUTS', 'outputs')]:
        env[f'AQUEOUS_{key}'] = str(path / f'{name}.toml')
    (path / 'wm.toml').write_text('''[blur]
enabled = false
[input]
focus_new_windows = true
[workspace_transition]
enabled = true
rate = 4.0
[layout.options.scrolling]
column_fraction = 0.75
center_focused = true
follow_new_windows = true
''')
    (path / 'outputs.toml').write_text(f'''[[output]]
name = "HEADLESS-1"
mode = "1600x1200@60"
scale = {scale}
transform = "{transform}"
''')
    rules = path / 'rules.toml'
    def placement(x=80, y=80, width=320, height=240, floating=True):
        rules.write_text(f'''[[window]]
app_id = "aqueous.corner-probe"
floating = {str(floating).lower()}
width = {width}
height = {height}
x = {x}
y = {y}
blur = false
''')
    placement()
    logs = []
    processes = []
    def launch(command, name, **kwargs):
        log = (path / f'{name}.log').open('w'); logs.append(log)
        p = subprocess.Popen([str(s) for s in command], env=env, stderr=log,
                             stdout=kwargs.pop('stdout', log), **kwargs)
        processes.append(p)
        return p
    def wait(check):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert all(p.poll() is None for p in processes), f'process exited: {path}'
            result = check()
            if result: return result
            time.sleep(.025)
        raise AssertionError(f'timed out: {path}')
    def window():
        return next((w for w in json.loads(run([ctl, 'windows', '--json'], env))
                     if w['app_id'] == 'aqueous.corner-probe'), None)
    def capture(name, frames=2):
        target = path / f'{name}.png'
        for _ in range(frames): run(['grim', '-s', '1', target], env)
        return Image.open(target).convert('RGB')
    def corners(image, geom, rounded=True):
        x, y, w, h = (geom[k] for k in ('x', 'y', 'width', 'height'))
        for px, py in ((x, y), (x+w-1, y), (x, y+h-1), (x+w-1, y+h-1)):
            color = image.getpixel((px, py))
            if rounded: assert max(color) < 20, (path, 'corner leaked', px, py, color)
            else: assert color[0] > 80, (path, 'square corner missing', color)
        assert image.getpixel((x+w//2, y+h//2))[0] > 80, 'content disappeared'
    try:
        launch([args.compositor.resolve(), '-no-xwayland', '-policy', 'internal', '-log-level', 'debug', '-c', 'true'], 'compositor')
        sock = wait(lambda: next((p for p in runtime.glob('wayland-*') if p.is_socket()), None))
        env['WAYLAND_DISPLAY'] = sock.name
        client = launch([work / 'client'], 'client', stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        lines = queue.Queue()
        threading.Thread(target=lambda: [lines.put(line.strip()) for line in client.stdout], daemon=True).start()
        assert lines.get(timeout=10) == 'READY'
        geom = wait(window)['geometry']
        time.sleep(.15)
        def command(text):
            client.stdin.write(text + '\n'); client.stdin.flush()
            assert lines.get(timeout=10) == 'OK'
            time.sleep(.06)
        reference = capture('padded')
        corners(reference, geom, not args.no_effects)
        command('padding 0')
        unpadded = capture('unpadded')
        corners(unpadded, geom, not args.no_effects)
        x, y, w, h = (geom[k] for k in ('x', 'y', 'width', 'height'))
        # Fractional sampling blends the padded texture's transparent edge;
        # the unpadded texture instead clamps to its last opaque texel.
        for box in ((x-5, y-5, x+30, y+30), (x+w-30, y+h-30, x+w+5, y+h+5)):
            difference = ImageChops.difference(reference.crop(box), unpadded.crop(box))
            assert max(high for low, high in difference.getextrema()) <= 8, 'padding changed silhouette'
        command('padding 32')
        corners(capture('padding-changed'), geom, not args.no_effects)
        for buffer_transform in range(8):
            command(f'transform {buffer_transform}')
            corners(capture(f'buffer-transform-{buffer_transform}'), geom, not args.no_effects)
        command('transform 0')
        command('child 60 60')
        child = capture('interior-child')
        r, g, b = child.getpixel((x+60, y+60))
        assert g > r * 2 and g > b * 2, 'interior subsurface acquired an independent rounded corner'
        command('child -8 -8')
        crossed = capture('crossing-child')
        if not args.no_effects:
            for px, py in ((x-6, y-6), (x, y)):
                assert max(crossed.getpixel((px, py))) < 20, 'subsurface escaped window mask'
        command('no-child')
        command('single-child -8 -8')
        single = capture('single-pixel-child')
        if not args.no_effects:
            assert max(single.getpixel((x, y))) < 20, 'single-pixel shortcut escaped the mask'
        assert single.getpixel((x+20, y+20))[1] > 100, 'single-pixel surface disappeared'
        command('no-child')
        command('fullscreen')
        wait(lambda: 'fullscreen' in window()['states'])
        fullscreen = capture('fullscreen')
        # grim rounds its scale-1 image down, while output logical dimensions
        # round up at fractional scales. Check the actual output image edges.
        corners(fullscreen, dict(x=0, y=0, width=fullscreen.width, height=fullscreen.height), False)
        command('windowed')
        wait(lambda: 'fullscreen' not in window()['states'])
        time.sleep(.2)
        corners(capture('windowed'), window()['geometry'], not args.no_effects)
        # A geometry/configuration change exercises saved buffers and the move snapshot.
        placement(160, 120, 360, 260)
        run([ctl, 'session', 'reload', '--json'], env)
        wait(lambda: window()['geometry']['x'] == 160)
        capture('moving')
        time.sleep(.8)
        corners(capture('moved-resized'), window()['geometry'], not args.no_effects)
        command('child 340 240')
        run([ctl, 'overview', 'show', '--output', 'HEADLESS-1', '--json'], env)
        time.sleep(.7)
        scene = run([ctl, 'scene'], env)
        (path / 'overview-scene.txt').write_text(scene)
        assert 'overview thumbnail buffer' in scene
        overview = capture('overview')
        thumbnail = re.search(r'overview thumbnail buffer \[buffer\] \((-?\d+),(-?\d+) (\d+)x(\d+)\)', scene)
        assert thumbnail, 'missing thumbnail geometry'
        tx, ty, tw, th = map(int, thumbnail.groups())
        if not args.no_effects:
            # The top-left corner may be covered by an application icon.
            # Stay inside the card to avoid resampling its cyan selection border.
            for px, py in ((tx+tw-3, ty+2), (tx+2, ty+th-3), (tx+tw-3, ty+th-3)):
                assert max(overview.getpixel((px, py))) < 30, 'thumbnail lost its window mask'
        run([ctl, 'overview', 'hide', '--json'], env)
        time.sleep(.2)
        command('no-child')
        corners(capture('after-overview'), window()['geometry'], not args.no_effects)
        # A slow incoming workspace slide exposes both the frozen mask and a
        # viewport crop. The crop must not invent a corner at the output edge.
        records = json.loads(run([ctl, 'shell', 'snapshot', '--json'], env))['upsert']
        workspaces = {r['name']: r['id'] for r in records if r['kind'] == 'workspace'}
        run([ctl, 'workspace', 'activate', '--id', workspaces['2'], '--json'], env)
        time.sleep(2.2)
        run([ctl, 'workspace', 'activate', '--id', workspaces['1'], '--json'], env)
        observed = cropped = False
        for frame in range(8):
            moving = capture(f'workspace-incoming-{frame}', frames=1)
            red, green, _ = moving.split()
            body = ImageChops.subtract(red, green).point(lambda v: 255 if v > 60 else 0).getbbox()
            if not body:
                continue
            left, top, right, bottom = body
            observed = True
            if not args.no_effects:
                for px in (left, right-1):
                    if 2 < px < moving.width-3:
                        for py in (top, bottom-1):
                            r, g, _ = moving.getpixel((px, py))
                            assert r-g < 60, 'animation snapshot lost its rounded corner'
                edge = 0 if left == 0 else moving.width-1 if right == moving.width else None
                if edge is not None and right-left > 30:
                    r, g, _ = moving.getpixel((edge, top+3))
                    assert r-g > 60, 'viewport crop invented a rounded corner'
                    cropped = True
        assert observed, 'incoming snapshot was never visible'
        if not args.no_effects:
            assert cropped, 'incoming snapshot never exercised a viewport crop'
        time.sleep(2.2)
        corners(capture('after-workspace'), window()['geometry'], not args.no_effects)
        placement(floating=False)
        run([ctl, 'session', 'reload', '--json'], env)
        wait(lambda: 'floating' not in window()['states'])
        time.sleep(.8)
        corners(capture('tiled'), window()['geometry'], not args.no_effects)
        if scale == 1 and transform == 'normal':
            rules.write_text('''[[window]]
app_id = "aqueous.corner-*"
layout = "scrolling"
floating = false
blur = false
''')
            run([ctl, 'session', 'reload', '--json'], env)
            launch([work / 'client', 'aqueous.corner-neighbor'], 'neighbor', stdin=subprocess.PIPE)
            wait(lambda: len(json.loads(run([ctl, 'windows', '--json'], env))) == 2)
            time.sleep(.8)
            scrolling = capture('scrolling')
            windows = json.loads(run([ctl, 'windows', '--json'], env))
            (path / 'scrolling-windows.json').write_text(json.dumps(windows, indent=2))
            assert any(0 < min(w['geometry']['x'] + w['geometry']['width'], scrolling.width) -
                       max(w['geometry']['x'], 0) < w['geometry']['width'] for w in windows), 'no partially clipped column'
            red, green, _ = scrolling.split()
            bounds = ImageChops.subtract(red, green).point(lambda v: 255 if v > 60 else 0).getbbox()
            assert bounds, 'scrolling content disappeared'
            assert bounds[0] > 0, 'offscreen column escaped the inset scrolling viewport'
            if not args.no_effects:
                left, top, right, bottom = bounds
                # The viewport cuts the offscreen column with a straight edge;
                # original corners still visible inside it retain their mask.
                for w in windows:
                    geom = w['geometry']
                    for px in (geom['x'], geom['x'] + geom['width']-1):
                        if left < px < right:
                            for py in (top, bottom-1):
                                r, g, _ = scrolling.getpixel((px, py))
                                assert r-g < 60, 'scrolling window corner leaked'
            print('PASS scrolling: padded columns clipped to the viewport', flush=True)
        print(f'PASS scale={scale} transform={transform}: padding, subsurfaces, buffer transforms, fullscreen, resize, overview, workspace crops, tiled', flush=True)
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=4)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
        for f in logs: f.close()

matrix = [(1, 'normal')] if args.quick else [(s, 'normal') for s in (1, 1.25, 1.5, 2)] + [(1.25, t) for t in ('90', '180', '270', 'flipped')]
for scale, transform in matrix: case(scale, transform)
