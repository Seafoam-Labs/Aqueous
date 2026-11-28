#!/usr/bin/env python3
"""Regression for issue #179: a fullscreen Xwayland game that minimizes itself.

Many Windows games running under Wine/Proton (CS2, Arkham Knight, SDL titles)
minimize on focus loss: they enter iconic state and unmap their X11 window. The
escape cycle (Super/Alt+Tab) moves focus to a peer, triggering that minimize.
Previously the unmap dropped the window from the compositor's managed tree, so
it vanished from the taskbar AND the window switcher and could never be cycled
back into. The compositor must now keep the window managed as minimized across
the iconic unmap (Fix 1) and keep minimized windows in the switcher ring (Fix 2),
restoring the window — and its fullscreen — when cycled back onto.

The fixture holds an honored X11 keyboard grab, iconifies+unmaps on FocusOut,
and re-maps when the compositor restores WM_STATE to NormalState (like SDL).

Requires a -Dxwayland build, Xwayland, a C compiler, wayland-scanner, and
Wayland/X11/xkbcommon development files. Runs headless with --renderer pixman.
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-xwayland-iconic-'))
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

    def run(command, **kw):
        p = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                           text=True, timeout=30, **kw)
        assert p.returncode == 0, f'{command}: {p.stderr}'
        return p.stdout

    def launch(command, name, shell=False):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        p = subprocess.Popen(command if shell else list(map(str, command)), env=env,
                             stdin=subprocess.PIPE, stdout=log, stderr=log, text=True, shell=shell)
        processes.append(p)
        return p

    def wait_for(predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert server.poll() is None, (work / 'compositor.log').read_text()[-4000:]
            value = predicate()
            if value:
                return value
            time.sleep(.03)
        raise AssertionError(message)

    def ctl(*arguments):
        return json.loads(run([args.ctl, *arguments, '--json']))

    def windows():
        return ctl('windows')

    def xwindow():
        return next((w for w in windows() if (w['class'] or '') == 'AqueousXwaylandIconicTest'), None)

    def pwindow():
        return next((w for w in windows() if (w['app_id'] or '') == 'escape-peer'), None)

    def log_text(name):
        return (work / f'{name}.log').read_text()

    success = False
    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        for xml, header in {
            ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml': 'virtual-keyboard-unstable-v1-client-protocol.h',
            ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml': 'wlr-virtual-pointer-unstable-v1-client-protocol.h',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / header])
        run(['wayland-scanner', 'private-code', ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
             work / 'virtual-keyboard-protocol.c'])
        run(['wayland-scanner', 'private-code', ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
             work / 'virtual-pointer-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xwayland-iconic.c',
             work / 'virtual-keyboard-protocol.c', work / 'virtual-pointer-protocol.c',
             '-o', work / 'xiconic',
             *shlex.split(run(['pkg-config', '--cflags', '--libs', 'x11', 'wayland-client', 'xkbcommon']))])
        inhibit_xml = protocols / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml'
        run(['wayland-scanner', 'client-header', protocols / 'stable/xdg-shell/xdg-shell.xml',
             work / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', protocols / 'stable/xdg-shell/xdg-shell.xml',
             work / 'xdg-shell-protocol.c'])
        run(['wayland-scanner', 'client-header', inhibit_xml,
             work / 'keyboard-shortcuts-inhibit-unstable-v1-client-protocol.h'])
        run(['wayland-scanner', 'private-code', inhibit_xml, work / 'keyboard-shortcuts-inhibit-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/fullscreen-escape.c', work / 'xdg-shell-protocol.c',
             work / 'keyboard-shortcuts-inhibit-protocol.c', work / 'virtual-keyboard-protocol.c',
             '-o', work / 'escape',
             *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon']))])

        xlog = work / 'x11.log'
        server = launch([args.compositor.resolve(), '-policy', 'internal', '-log-level', 'debug',
                         '-c', f'{work / "xiconic"} >{xlog} 2>&1'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait_for(
            lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None),
            'No Wayland socket')
        wait_for(lambda: len(ctl('outputs')) == 1, 'Expected one output')
        peer = launch([work / 'escape', 'escape-peer', 'ff0000ff'], 'peer')
        wait_for(lambda: pwindow(), 'peer did not map')
        wait_for(lambda: xwindow(), 'Xwayland window did not map')
        wait_for(lambda: 'honoring Xwayland keyboard grab' in log_text('compositor'),
                 'Xwayland keyboard grab not honored')

        xid = xwindow()['id']
        ctl('window', 'state', '--id', xid, '--fullscreen', 'true')
        wait_for(lambda: 'fullscreen' in xwindow()['states'], 'Xwayland window not fullscreen')
        ctl('window', 'activate', '--id', xid, '--seat', 'default')
        wait_for(lambda: 'focused' in xwindow()['states'], 'Xwayland window not focused')
        print('PASS: fullscreen grabbed Xwayland game focused', flush=True)

        # Escape: Alt+Tab moves focus to the peer; the game minimizes itself
        # (iconic + unmap). It must STAY managed as minimized, not vanish.
        peer.stdin.write('chord 15 8\n')
        peer.stdin.flush()
        wait_for(lambda: 'ICONIFIED_AND_UNMAPPED' in log_text('x11'), 'game never iconified')
        wait_for(lambda: pwindow() and 'focused' in pwindow()['states'], 'peer not focused after escape')
        wait_for(lambda: xwindow() is not None, 'game vanished from managed list after iconic unmap (#179)')
        game = wait_for(lambda: xwindow() if xwindow() and 'minimized' in xwindow()['states'] else None,
                        'game not tracked minimized after iconic unmap')
        print('PASS: self-minimizing game stays managed (minimized) after escape', flush=True)

        # Return: cycling back onto the minimized game restores it (re-map) and
        # re-asserts its fullscreen (escape-and-return).
        peer.stdin.write('chord 15 8\n')
        peer.stdin.flush()
        wait_for(lambda: 'RESTORE_REMAP' in log_text('x11'), 'game never re-mapped on restore')
        wait_for(lambda: xwindow() and 'focused' in xwindow()['states'], 'game not focused after return')
        wait_for(lambda: 'minimized' not in xwindow()['states'], 'game still minimized after return')
        wait_for(lambda: 'fullscreen' in xwindow()['states'], 'fullscreen not restored on return')
        print('PASS: cycling back restored the minimized game and its fullscreen', flush=True)

        success = True
        print('PASS: self-minimizing Xwayland game stays switcher-reachable (issue #179)', flush=True)
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
