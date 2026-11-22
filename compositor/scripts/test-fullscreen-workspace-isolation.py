#!/usr/bin/env python3
"""Regression: fullscreen ownership is workspace-local, not output-wide.

Entering fullscreen on one workspace must not demote a fullscreen window on
another workspace of the same output, while same-workspace exclusivity and
cross-output independence are preserved. Covers the IPC state command, the
toggle_fullscreen keybinding, and client-originated xdg-shell requests.

Requires Pillow, grim, wlrctl, a C compiler and Wayland development tools.
Use --renderer pixman with a -Dvulkan-effects=false diagnostic build, or vulkan
with a production build and GPU access. Graphical tests must run serially.
Artifacts, including failures, remain in the printed /tmp directory.
"""
import argparse
import json
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
    parser.add_argument('--renderer', choices=['pixman', 'vulkan'], default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-fullscreen-isolation-'))
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
    (work / 'wm.toml').write_text('''[opacity]
enabled = false
[blur]
enabled = false
[input]
focus_follows_mouse = false
mouse_follows_focus = false
focus_new_windows = false
[workspace_transition]
enabled = false
''')
    (work / 'outputs.toml').write_text('''[[output]]
name = "HEADLESS-1"
position = [0, 0]
[[output]]
name = "HEADLESS-2"
position = [1280, 0]
''')
    processes, logs = [], []
    server = None

    def run(command):
        p = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                           text=True, timeout=20)
        assert p.returncode == 0, f'{command}: {p.stderr}'
        return p.stdout

    def launch(command, name):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        child_env = env if name == 'compositor' else dict(env, WAYLAND_DEBUG='1')
        p = subprocess.Popen(list(map(str, command)), env=child_env, stdin=subprocess.PIPE,
                             stdout=log, stderr=log, text=True)
        processes.append(p)
        return p

    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert server.poll() is None, (work / 'compositor.log').read_text()[-4000:]
            value = predicate()
            if value:
                return value
            time.sleep(.025)
        raise AssertionError(message)

    def ctl(*arguments):
        return json.loads(run([args.ctl, *arguments, '--json']))

    def windows():
        return ctl('windows')

    def window(name):
        return next((w for w in windows() if (w['app_id'] or w['class']) == name), None)

    def records():
        return ctl('shell', 'snapshot')['upsert']

    def workspace_id(output, number):
        rs = records()
        out = next(r['id'] for r in rs if r['kind'] == 'output' and r['name'] == output)
        return next(r['id'] for r in rs if r['kind'] == 'workspace' and r['output'] == out
                    and r['number'] == number)

    def fullscreen(name, value):
        w = window(name)
        ctl('window', 'state', '--id', w['id'], '--fullscreen', str(value).lower())
        wait_for(lambda: ('fullscreen' in window(name)['states']) == value,
                 f'{name} fullscreen={value} not reached')

    def move(name, output, number):
        w = window(name)
        ctl('window', 'move', '--id', w['id'], '--workspace-id', workspace_id(output, number))
        wait_for(lambda: (window(name)['output'], window(name)['workspace']) == (output, number),
                 f'{name} did not move to {output}/{number}')

    def spawn(name, color):
        launch([work / 'client', name, color, '1'], name)
        return wait_for(lambda: window(name), f'{name} did not map')

    def key(symbol, modifiers='SUPER'):
        run(['wlrctl', 'keyboard', 'type', symbol, 'modifiers', modifiers])

    def activate_workspace(output, number):
        ctl('workspace', 'activate', '--id', workspace_id(output, number))
        time.sleep(.3)

    def capture(label, output):
        path = work / f'{label}.png'
        run(['grim', '-o', output, path])
        with Image.open(path) as image:
            return image.convert('RGB')

    def center(image):
        return image.getpixel((image.width // 2, image.height // 2))

    def expect_fullscreen(name, value):
        wait_for(lambda: ('fullscreen' in window(name)['states']) == value,
                 f'{name}: expected fullscreen={value}, got {window(name)}')

    success = False
    try:
        protocol = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip()) / 'stable/xdg-shell/xdg-shell.xml'
        run(['wayland-scanner', 'client-header', protocol, work / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', protocol, work / 'xdg-shell-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/scrolling-vertical-reference.c', work / 'xdg-shell-protocol.c',
             '-o', work / 'client', *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-fullscreen-request.c', work / 'xdg-shell-protocol.c',
             '-o', work / 'fsclient', *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))])
        server = launch([args.compositor.resolve(), '-no-xwayland', '-policy', 'internal',
                         '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait_for(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'No Wayland socket')
        wait_for(lambda: len(ctl('outputs')) == 2, 'Expected two outputs')
        one, two = 'HEADLESS-1', 'HEADLESS-2'

        # Two fullscreen windows on different workspaces of the same output must
        # coexist; the second enter must not demote the first.
        spawn('iso-red', 'ffff0000')
        spawn('iso-blue', 'ff0000ff')
        move('iso-red', one, 1)
        move('iso-blue', one, 2)
        fullscreen('iso-red', True)
        fullscreen('iso-blue', True)
        expect_fullscreen('iso-red', True)
        expect_fullscreen('iso-blue', True)
        assert center(capture('red-ws1', one)) == (255, 0, 0)
        activate_workspace(one, 2)
        assert center(capture('blue-ws2', one)) == (0, 0, 255)
        activate_workspace(one, 1)
        assert center(capture('red-ws1-again', one)) == (255, 0, 0)
        expect_fullscreen('iso-red', True)
        expect_fullscreen('iso-blue', True)
        print('PASS: IPC fullscreen on separate workspaces coexist', flush=True)

        # Same-workspace exclusivity is preserved: a new fullscreen owner demotes
        # the previous one on that workspace only.
        spawn('iso-yellow', 'ffffff00')
        move('iso-yellow', one, 1)
        fullscreen('iso-yellow', True)
        expect_fullscreen('iso-yellow', True)
        expect_fullscreen('iso-red', False)
        expect_fullscreen('iso-blue', True)
        assert center(capture('yellow-ws1', one)) == (255, 255, 0)
        print('PASS: same-workspace exclusivity preserved', flush=True)

        # Keybinding toggle on the active workspace leaves other workspaces alone.
        activate_workspace(one, 2)
        wait_for(lambda: 'focused' in window('iso-blue')['states'], 'blue not focused on ws2')
        key('f', 'SUPER,SHIFT')
        expect_fullscreen('iso-blue', False)
        expect_fullscreen('iso-yellow', True)
        key('f', 'SUPER,SHIFT')
        expect_fullscreen('iso-blue', True)
        expect_fullscreen('iso-yellow', True)
        print('PASS: keybinding toggle is workspace-local', flush=True)

        # Client-originated xdg-shell fullscreen request on a third workspace.
        green = launch([work / 'fsclient', '--commands', 'iso-green'], 'green')
        wait_for(lambda: window('iso-green'), 'green did not map')
        move('iso-green', one, 3)
        green.stdin.write('fullscreen none\n')
        green.stdin.flush()
        expect_fullscreen('iso-green', True)
        expect_fullscreen('iso-blue', True)
        expect_fullscreen('iso-yellow', True)
        green.stdin.write('windowed\n')
        green.stdin.flush()
        expect_fullscreen('iso-green', False)
        expect_fullscreen('iso-blue', True)
        expect_fullscreen('iso-yellow', True)
        print('PASS: client request and exit are workspace-local', flush=True)

        # Cross-output independence in both directions.
        spawn('iso-purple', 'ff800080')
        move('iso-purple', two, 1)
        spawn('iso-cyan', 'ff00ffff')
        move('iso-cyan', two, 2)
        fullscreen('iso-purple', True)
        fullscreen('iso-cyan', True)
        expect_fullscreen('iso-purple', True)
        expect_fullscreen('iso-cyan', True)
        expect_fullscreen('iso-blue', True)
        expect_fullscreen('iso-yellow', True)
        assert center(capture('purple-h2', two)) == (128, 0, 128)
        fullscreen('iso-blue', False)
        expect_fullscreen('iso-purple', True)
        expect_fullscreen('iso-cyan', True)
        print('PASS: cross-output independence', flush=True)

        success = True
        print('PASS: fullscreen workspace isolation', flush=True)
    finally:
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
        for log in logs:
            log.close()
        (work / 'results.json').write_text(json.dumps(dict(passed=success, renderer=args.renderer), indent=2))
        print(f'Results: {work / "results.json"}', flush=True)
    raise SystemExit(0 if success else 1)


if __name__ == '__main__':
    main()