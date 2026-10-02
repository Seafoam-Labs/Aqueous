#!/usr/bin/env python3
"""Verify single-tile centering and transitions in a private ultrawide compositor.

Requires a diagnostic compositor built with -Dvulkan-effects=false.
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-single-window-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []

    def run(command):
        result = subprocess.run([str(p) for p in command], env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
        assert result.returncode == 0, (command, result.stdout)
        return result.stdout

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
            time.sleep(.04)
        raise AssertionError(description)

    def command(value):
        client.stdin.write(value + '\n')
        client.stdin.flush()

    def windows():
        return json.loads(run([args.ctl.resolve(), 'windows', '--json']))

    def window(id):
        return next((w for w in windows() if w.get('app_id') == f'center-{id}'), None)

    def native_id(id):
        entities = json.loads(run([args.ctl.resolve(), 'shell', 'snapshot', '--json']))['upsert']
        return next(w['id'] for w in entities if w['kind'] == 'window' and w.get('app_id') == f'center-{id}')

    def geometry(id, expected):
        return wait(lambda: (w := window(id)) and w['geometry'] == expected,
                    f'window {id}: expected {expected}')

    def create(id, parent=-1, mode=0):
        command(f'create {id} {parent} {mode}')
        wait(lambda: window(id), f'window {id} missing')

    def destroy(id):
        command(f'destroy-top {id}')
        wait(lambda: window(id) is None, f'window {id} not destroyed')

    def configure(layout, enabled=True, ratio=16 / 9):
        (work / 'layout.toml').write_text(f'''[layout]
default = "{layout}"
gaps_outer = 8
gaps_inner = 4
border_width = 2
center_single_window = {str(enabled).lower()}
single_window_aspect_ratio = {ratio}
''')
        # Use the normal config reload path, then wait for committed geometry.
        run([args.ctl.resolve(), 'session', 'reload', '--json'])

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
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-dialog.c', *generated, '-lwayland-client', '-o', work / 'client'])
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
        (work / 'config.toml').write_text('''[layout]
default = "tile"
[blur]
enabled = false
[workspace_transition]
enabled = false
[input]
focus_follows_mouse = false
[struts]
top = 24
bottom = 0
left = 16
right = 24
''')
        (work / 'outputs.toml').write_text('[[output]]\nname = "HEADLESS-1"\nmode = "3440x1440@60"\n')
        (work / 'rules.toml').write_text('[[window]]\napp_id = "center-3"\nfloating = true\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'info', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        env['AQUEOUS_SOCKET'] = str(wait(lambda: next((work / 'runtime/aqueous').glob('*/ipc.sock'), None), 'no IPC socket'))
        client = launch([work / 'client', 'center'], 'client')
        wait(lambda: '"event":"ready"' in (work / 'client.log').read_text().replace(' ', ''), 'client not ready')
        # 3440x1440 minus struts, then 8px outer gaps: 3384x1400.
        full = dict(x=24, y=32, width=3384, height=1400)
        centered = dict(x=471, y=32, width=2489, height=1400)
        results = []
        for layout in ('tile', 'grid', 'rows', 'dwindle', 'reverse-dwindle'):
            configure(layout)
            create(0)
            geometry(0, centered)
            create(1)
            pair = wait(lambda: (a := window(0)) and (b := window(1)) and
                        a['geometry'] != centered and b['geometry']['width'] > 0 and
                        [a['geometry'], b['geometry']], 'normal tiling did not resume')
            configure(layout, False)
            geometry(0, pair[0]); geometry(1, pair[1])
            configure(layout)
            run([args.ctl.resolve(), 'window', 'activate', '--id', native_id(1), '--seat', 'default', '--json'])
            run(['wlrctl', 'keyboard', 'type', 'n', 'modifiers', 'SUPER'])
            geometry(0, centered)
            run([args.ctl.resolve(), 'window', 'activate', '--id', native_id(1), '--seat', 'default', '--json'])
            geometry(0, pair[0]); geometry(1, pair[1])
            # Moving a tile away and back follows the same singleton policy.
            run(['wlrctl', 'keyboard', 'type', '2', 'modifiers', 'SUPER,SHIFT'])
            geometry(0, centered)
            run([args.ctl.resolve(), 'window', 'activate', '--id', native_id(1), '--seat', 'default', '--json'])
            geometry(1, centered)
            run(['wlrctl', 'keyboard', 'type', '1', 'modifiers', 'SUPER,SHIFT'])
            run([args.ctl.resolve(), 'window', 'activate', '--id', native_id(0), '--seat', 'default', '--json'])
            geometry(0, pair[0]); geometry(1, pair[1])
            destroy(1)
            geometry(0, centered)
            # Transient and floating overlays do not change the tiled count.
            create(2, 0, 2)
            create(3)
            geometry(0, centered)
            destroy(3); destroy(2)
            command('fullscreen 0 1')
            geometry(0, dict(x=0, y=0, width=3440, height=1440))
            command('fullscreen 0 0')
            geometry(0, centered)
            run([args.ctl.resolve(), 'window', 'activate', '--id', native_id(0), '--seat', 'default', '--json'])
            run(['wlrctl', 'keyboard', 'type', 'm', 'modifiers', 'SUPER,SHIFT'])
            geometry(0, dict(x=16, y=24, width=3400, height=1416))
            run(['wlrctl', 'keyboard', 'type', 'm', 'modifiers', 'SUPER,SHIFT'])
            geometry(0, centered)
            configure(layout, False)
            geometry(0, full)
            configure(layout, True, 1.0)
            geometry(0, dict(x=1016, y=32, width=1400, height=1400))
            destroy(0)
            results.append(layout)
            print(f'PASS {layout}: create, close, minimize, restore, workspace moves, overlays, fullscreen, maximize, reload', flush=True)
        (work / 'results.json').write_text(json.dumps(dict(passed=results), indent=2) + '\n')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(timeout=4)
            if child.stdin:
                child.stdin.close()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
