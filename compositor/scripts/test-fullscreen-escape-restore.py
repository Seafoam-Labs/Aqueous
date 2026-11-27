#!/usr/bin/env python3
"""Regression: escape-and-return for a fullscreen client that does NOT seize input.

This is the native Wayland case (e.g. Wine's winewayland.drv / Proton "wineland"):
the game fullscreens but neither inhibits compositor shortcuts nor holds an X11
keyboard grab. Cycling away (Alt+Tab) must surface the peer by suspending the
fullscreen owner, and cycling back must RESTORE the owner's fullscreen
(remember-and-restore). Guards issue #148's residual native-Wayland case.

Requires a C compiler, wayland-scanner, and Wayland/xkbcommon development files.
Runs against a -Dvulkan-effects=false diagnostic build with --renderer pixman.
Artifacts remain in the printed /tmp directory.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=['pixman', 'vulkan'], default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-fullscreen-escape-restore-'))
    print(f'Artifacts: {work}', flush=True)
    runtime = work / 'runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
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
    (work / 'layout.toml').write_text('[layout]\ndefault = "floating"\n')
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
        p = subprocess.Popen(list(map(str, command)), env=env, stdin=subprocess.PIPE,
                             stdout=log, stderr=log, text=True)
        processes.append(p)
        return p

    def wait_for(predicate, message, timeout=10):
        deadline = time.monotonic() + timeout
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

    def send(name, command):
        proc = next(p for p in processes if p.args and name in ' '.join(map(str, p.args)))
        proc.stdin.write(command + '\n')
        proc.stdin.flush()

    def key(code, modifiers=0):
        send('game', f'chord {code} {modifiers}')

    def focus(name):
        wid = window(name)['id']
        ctl('window', 'activate', '--id', wid, '--seat', 'default')
        wait_for(lambda: 'focused' in window(name)['states'], f'{name} not focused')

    def expect_fullscreen(name, value):
        wait_for(lambda: ('fullscreen' in window(name)['states']) == value,
                 f'{name} fullscreen={value} not reached')

    success = False
    try:
        protocol = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        inhibit_xml = protocol / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml'
        run(['wayland-scanner', 'client-header', protocol / 'stable/xdg-shell/xdg-shell.xml',
             work / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', protocol / 'stable/xdg-shell/xdg-shell.xml',
             work / 'xdg-shell-protocol.c'])
        run(['wayland-scanner', 'client-header', inhibit_xml,
             work / 'keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h'])
        run(['wayland-scanner', 'private-code', inhibit_xml,
             work / 'keyboard-shortcuts-inhibit-protocol.c'])
        vk_xml = ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml'
        run(['wayland-scanner', 'client-header', vk_xml,
             work / 'virtual-keyboard-unstable-v1-client-protocol.h'])
        run(['wayland-scanner', 'private-code', vk_xml, work / 'virtual-keyboard-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/fullscreen-escape.c', work / 'xdg-shell-protocol.c',
             work / 'keyboard-shortcuts-inhibit-protocol.c', work / 'virtual-keyboard-protocol.c',
             '-o', work / 'escape',
             *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon']))])
        server = launch([args.compositor.resolve(), '-no-xwayland', '-policy', 'internal',
                         '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait_for(
            lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None),
            'No Wayland socket')
        wait_for(lambda: len(ctl('outputs')) == 1, 'Expected one output')

        game = launch([work / 'escape', 'escape-game', 'ffff0000'], 'game')
        peer = launch([work / 'escape', 'escape-peer', 'ff0000ff'], 'peer')
        wait_for(lambda: window('escape-game'), 'game did not map')
        wait_for(lambda: window('escape-peer'), 'peer did not map')

        # Fullscreen the game and give it keyboard focus. NO inhibition / grab:
        # this is the native Wayland path that PR #166's seizure gate missed.
        send('game', 'fullscreen')
        expect_fullscreen('escape-game', True)
        focus('escape-game')
        assert 'inhibit active' not in (work / 'game.log').read_text(), 'fixture unexpectedly inhibited'
        print('PASS: fullscreen game focused without seizing the keyboard', flush=True)

        # Escape: Alt+Tab cycles to the peer and suspends the fullscreen game so
        # the peer is surfaced (game leaves the fullscreen band).
        key(15, 8)  # Alt+Tab
        expect_fullscreen('escape-game', False)
        wait_for(lambda: 'focused' in window('escape-peer')['states'], 'peer not focused after escape')
        print('PASS: Alt+Tab escaped, suspended fullscreen, focused peer', flush=True)

        # Return: cycling back to the game restores its fullscreen.
        key(15, 8)  # Alt+Tab again
        expect_fullscreen('escape-game', True)
        wait_for(lambda: 'focused' in window('escape-game')['states'], 'game not focused after return')
        print('PASS: cycling back restored fullscreen (escape-and-return)', flush=True)

        # Restore also fires on a non-cycle focus gain (dock/IPC activation).
        key(15, 8)  # escape again -> peer
        expect_fullscreen('escape-game', False)
        wait_for(lambda: 'focused' in window('escape-peer')['states'], 'peer not focused after second escape')
        focus('escape-game')  # activate via IPC, not a cycle
        expect_fullscreen('escape-game', True)
        print('PASS: IPC activation also restored fullscreen', flush=True)

        success = True
        print('PASS: fullscreen escape-and-return without keyboard seizure', flush=True)
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