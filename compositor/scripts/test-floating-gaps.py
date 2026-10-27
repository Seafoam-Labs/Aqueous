#!/usr/bin/env python3
"""Headless regression for snapped focus/stacking, ownership, gaps and reloads.

Use a compositor built with -Dvulkan-effects=false. Artifacts stay in /tmp.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-floating-gaps-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    compositor = None

    def run(command):
        result = subprocess.run([str(p) for p in command], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        assert result.returncode == 0, (command, result.stdout)
        return result.stdout

    def ctl(*command):
        return run([args.ctl.resolve(), *command])

    def launch(command, label):
        log = (work / f'{label}.log').open('w')
        logs.append(log)
        child = subprocess.Popen([str(p) for p in command], env=env, stdout=log, stderr=log)
        children.append(child)
        return child

    def wait(predicate, description):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()[-4000:]
            result = predicate()
            if result:
                return result
            time.sleep(.04)
        raise AssertionError(f'{description}; windows={ctl("windows", "--json")}')

    def window(name):
        return next((w for w in json.loads(ctl('windows', '--json'))
                     if w.get('app_id') == name), None)

    def geometry(name, expected):
        wait(lambda: (w := window(name)) and [w['geometry'][key] for key in ('x', 'y', 'width', 'height')] == expected,
             f'{name}: expected {expected}')

    def focus(name):
        entities = json.loads(ctl('shell', 'snapshot', '--json'))['upsert']
        native_id = next(w['id'] for w in entities if w['kind'] == 'window' and w.get('app_id') == name)
        ctl('window', 'activate', '--id', native_id, '--seat', 'default', '--json')
        wait_focused(name)

    def wait_focused(name):
        wait(lambda: 'focused' in window(name)['states'], f'{name}: not focused')

    def pointer_at(x, y):
        run(['wlrctl', 'pointer', 'move', '-10000', '-10000'])
        run(['wlrctl', 'pointer', 'move', str(x), str(y)])

    def pointer_inside(name):
        return (work / name / 'pointer-inside').exists()

    def overlap(name):
        a, b = window('gap-one')['geometry'], window('gap-two')['geometry']
        x, y = max(a['x'], b['x']) + 40, max(a['y'], b['y']) + 40
        assert x < min(a['x'] + a['width'], b['x'] + b['width'])
        assert y < min(a['y'] + a['height'], b['y'] + b['height'])
        pointer_at(x, y)
        wait(lambda: pointer_inside(name), f'overlap does not hit {name}')

    def click(name):
        count = len(list((work / name).glob('button-*')))
        run(['wlrctl', 'pointer', 'click'])
        wait(lambda: (work / name / f'button-{count + 1}').exists(), f'click did not reach {name}')

    def tiled_edges(name, expected):
        path = work / name / 'tiled-edges'
        wait(lambda: path.exists() and path.read_text().strip() == str(expected),
             f'{name}: expected tiled edge mask {expected}')

    def input_policy(follows=False, raises=True, delay=0):
        (work / 'input.toml').write_text(f'''[input]
focus_follows_mouse = {str(follows).lower()}
raise_on_focus = {str(raises).lower()}
raise_on_focus_delay_ms = {delay}
''')
        ctl('session', 'reload', '--json')

    def check_focus_raise():
        for method in ('keyboard', 'hover', 'click'):
            input_policy()
            pointer_at(0, 0)
            focus('gap-two')
            if method == 'keyboard':
                run(['wlrctl', 'keyboard', 'type', '\t', 'modifiers', 'SUPER'])
            else:
                if method == 'hover':
                    input_policy(follows=True)
                g = window('gap-one')['geometry']
                pointer_at(g['x'] + 10, g['y'] + 10)
                if method == 'click':
                    click('gap-one')
            wait_focused('gap-one')
            overlap('gap-one')
            click('gap-one')
        input_policy()

    def press(key):
        run(['wlrctl', 'keyboard', 'type', key, 'modifiers', 'SUPER,CTRL'])

    def create(name, mode='idle'):
        sync = work / name
        sync.mkdir()
        launch([work / 'client', sync, name, mode], name)
        wait(lambda: (sync / 'ready').exists() and window(name), f'{name} not ready')
        return sync

    def configure(layout='float', inner=24, legacy='', padding='', regions='', threshold=24, zones=True):
        source = f'''[layout]
default = "{layout}"
gaps_outer = 12
gaps_inner = {inner}
border_width = 4
snap_layout = "work"
[layout.options.float]
resistance = 0
snap_threshold = {threshold}
{legacy}
[layout.snap-layout.work]
{padding}
[layout.snap-layout.work.zone.left]
x = 0.0
y = 0.0
width = 0.5
height = 1.0
[layout.snap-layout.work.zone.right]
x = 0.5
y = 0.0
width = 0.5
height = 1.0
{regions}
'''
        if not zones:
            source = source[:source.index('[layout.snap-layout.work]')] + regions
        (work / 'layout.toml').write_text(source)
        if compositor:
            ctl('session', 'reload', '--json')

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'wlr-virtual-pointer-unstable-v1': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-floating-request.c', *generated, '-lwayland-client', '-o', work / 'client'])
        for name in ('home', 'config', 'cache', 'state', 'runtime'):
            (work / name).mkdir(mode=0o700)
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
                   XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('''[workspace_transition]
enabled = false
[input]
focus_follows_mouse = false
mouse_follows_focus = false
[struts]
top = 0
bottom = 0
left = 0
right = 0
[keybinds]
snap_left = "Super+Ctrl+H"
snap_right = "Super+Ctrl+L"
unsnap = "Super+Ctrl+U"
toggle_floating = "Super+Ctrl+V"
[keybinds.custom]
"Super+Ctrl+J" = "builtin:snap_zone:work/right"
''')
        configure()
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-policy', 'internal', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        env['AQUEOUS_SOCKET'] = str(wait(lambda: next((work / 'runtime/aqueous').glob('*/ipc.sock'), None), 'no IPC socket'))
        create('gap-one')
        create('gap-two')
        focus('gap-one')
        original = [window('gap-one')['geometry'][key] for key in ('x', 'y', 'width', 'height')]
        tiled_edges('gap-one', 0)
        check_focus_raise()
        press('h'); geometry('gap-one', [16, 16, 608, 688])
        tiled_edges('gap-one', 15)
        check_focus_raise()
        geometry('gap-one', [16, 16, 608, 688])
        tiled_edges('gap-one', 15)

        # Disabling raising still focuses the snapped window below its peer.
        focus('gap-two')
        input_policy(raises=False)
        focus('gap-one')
        overlap('gap-two')
        wait_focused('gap-one')
        click('gap-two')
        wait_focused('gap-two')

        # Keep the pointer over the overlap to observe the timer's restack
        # without a click that would replace/cancel the pending focus raise.
        input_policy(delay=1000)
        started = time.monotonic()
        run(['wlrctl', 'keyboard', 'type', '\t', 'modifiers', 'SUPER'])
        wait_focused('gap-one')
        assert pointer_inside('gap-two'), 'delayed raise occurred immediately'
        wait(lambda: pointer_inside('gap-one'), 'delayed raise did not restack the snapped window')
        assert time.monotonic() - started >= .8, 'raise delay was not respected'
        click('gap-one')
        input_policy()

        # Unsnapping restores both freeform geometry and untiled client hints.
        press('u'); geometry('gap-one', original)
        tiled_edges('gap-one', 0)
        check_focus_raise()

        # Explicit floating overlays use the same snapped classification.
        press('v')
        wait(lambda: 'floating' in window('gap-one')['states'], 'not an overlay')
        press('h'); geometry('gap-one', [16, 16, 608, 688])
        tiled_edges('gap-one', 15)
        check_focus_raise()
        press('u'); geometry('gap-one', original)
        tiled_edges('gap-one', 0)
        press('v')
        wait(lambda: 'floating' not in window('gap-one')['states'], 'overlay did not return to layout')
        configure(layout='tile')
        tiled_edges('gap-one', 15)
        configure()
        geometry('gap-one', original)
        tiled_edges('gap-one', 0)
        press('h'); geometry('gap-one', [16, 16, 608, 688])
        focus('gap-two'); press('l'); geometry('gap-two', [656, 16, 608, 688])
        # 656 - 4 - (16 + 608 + 4) == 24 visible pixels.
        focus('gap-one'); press('u'); geometry('gap-one', original)
        press('j'); geometry('gap-one', [656, 16, 608, 688])
        configure(inner=40)
        geometry('gap-one', [664, 16, 600, 688])
        geometry('gap-two', [664, 16, 600, 688])
        focus('gap-one'); press('u'); geometry('gap-one', original)
        # Persistent overlay geometry has a different owner from workspace floats.
        press('v')
        wait(lambda: 'floating' in window('gap-one')['states'], 'not an overlay')
        press('h'); geometry('gap-one', [16, 16, 600, 688])
        press('j'); geometry('gap-one', [664, 16, 600, 688])
        press('u'); geometry('gap-one', original)
        # Explicit legacy zero overrides the shared inset; borders still fit.
        configure(legacy='snap_gap = 0', padding='padding = 0')
        press('h'); geometry('gap-one', [4, 4, 632, 712])
        press('j'); geometry('gap-one', [644, 4, 632, 712])
        press('u'); geometry('gap-one', original)
        configure()
        # Named pointer snap commits on titlebar release for a persistent overlay.
        sync = create('gap-drag', 'move-only')
        focus('gap-drag'); press('v')
        wait(lambda: 'floating' in window('gap-drag')['states'], 'drag window not an overlay')
        g = window('gap-drag')['geometry']
        (sync / 'move').write_text(f'{g["x"] + 5} {g["y"] + 5} 1279 360\n')
        wait(lambda: (sync / 'move-done').exists(), 'pointer drag unfinished')
        geometry('gap-drag', [656, 16, 608, 688])
        # Without named zones the built-in edge path also commits on release.
        configure(zones=False)
        edge_sync = create('gap-edge', 'move-only')
        focus('gap-edge')
        g = window('gap-edge')['geometry']
        (edge_sync / 'move').write_text(f'{g["x"] + 5} {g["y"] + 5} 1279 360\n')
        wait(lambda: (edge_sync / 'move-done').exists(), 'edge drag unfinished')
        geometry('gap-edge', [656, 16, 608, 688])
        # Snapped geometry follows output changes without replacing restore state.
        (work / 'outputs.toml').write_text('[[output]]\nname = "HEADLESS-1"\nmode = "1440x900@60"\n')
        ctl('session', 'reload', '--json')
        geometry('gap-edge', [736, 16, 688, 868])
        (work / 'outputs.toml').write_text('[[output]]\nname = "HEADLESS-1"\nmode = "1280x720@60"\n')
        ctl('session', 'reload', '--json')
        geometry('gap-edge', [656, 16, 608, 688])
        # Zero threshold disables both named and built-in pointer snapping.
        configure(threshold=0)
        disabled_sync = create('gap-disabled', 'move-only')
        focus('gap-disabled')
        g = window('gap-disabled')['geometry']
        (disabled_sync / 'move').write_text(f'{g["x"] + 5} {g["y"] + 5} 1279 360\n')
        wait(lambda: (disabled_sync / 'move-done').exists(), 'disabled snap drag unfinished')
        actual = window('gap-disabled')['geometry']
        assert (actual['width'], actual['height']) == (g['width'], g['height']), actual
        # Composable regions resolve their own bounds for keyboard and pointer snaps.
        regions = '''[layout.composable.a]
layout = "float"
p1 = [0.0, 0.0]
p2 = [0.5, 0.0]
p3 = [0.5, 1.0]
p4 = [0.0, 1.0]
[layout.composable.b]
layout = "tile"
p1 = [0.5, 0.0]
p2 = [1.0, 0.0]
p3 = [1.0, 1.0]
p4 = [0.5, 1.0]
'''
        configure(layout='composable', regions=regions)
        create('gap-region')
        focus('gap-region'); press('h'); geometry('gap-region', [16, 16, 288, 688])
        press('j'); geometry('gap-region', [336, 16, 288, 688])
        region_sync = create('gap-region-drag', 'move-only')
        focus('gap-region-drag')
        g = window('gap-region-drag')['geometry']
        (region_sync / 'move').write_text(f'{g["x"] + 5} {g["y"] + 5} 639 360\n')
        wait(lambda: (region_sync / 'move-done').exists(), 'region drag unfinished')
        geometry('gap-region-drag', [336, 16, 288, 688])
        print('PASS: snapped focus/stacking, tiled hints, raise policy/delay, border gaps, keyboard and titlebar snaps, overlay ownership, named zones, reload, legacy overrides, region bounds and restore')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for child in reversed(children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
