#!/usr/bin/env python3
# SPDX-FileCopyrightText: © 2026 Seafoam Labs
# SPDX-License-Identifier: GPL-3.0-only
"""Check Aqueous protocol objects, window lifecycle and bindings in private headless sessions."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FAMILIES = ('window-management', 'input-management', 'xkb-bindings',
            'xkb-config', 'libinput-config', 'layer-shell')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--policy', choices=('internal', 'external', 'compare'), default='internal')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-protocols-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)

    def run(command):
        subprocess.run([str(part) for part in command], env=env, check=True, timeout=30)

    protocols = {f'aqueous-{family}-v1': ROOT / f'protocol/aqueous-{family}-v1.xml'
                 for family in FAMILIES}
    protocols.update({
        'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
        'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
        'security-context': Path('/usr/share/wayland-protocols/staging/security-context/security-context-v1.xml'),
        'xdg-shell': Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml'),
        'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        'screencopy': ROOT / 'protocol/upstream/wlr-screencopy-unstable-v1.xml',
    })
    generated = []
    for name, xml in protocols.items():
        run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
        code = work / f'{name}.c'
        run(['wayland-scanner', 'private-code', xml, code])
        generated.append(code)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True).split()
    run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
         ROOT / 'scripts/fixtures/aqueous-protocols.c', *generated, *flags, '-o', work / 'client'])
    run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
         ROOT / 'scripts/fixtures/exit-session.c', work / 'aqueous-window-management-v1.c',
         work / 'ext-workspace.c', *flags, '-o', work / 'exit-session'])
    for name in ('runtime', 'home', 'config', 'cache', 'state'):
        (work / name).mkdir(mode=0o700)
    env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
               XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless',
               WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
    for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        path = work / f'{name.lower()}.toml'
        path.write_text('')
        env[f'AQUEOUS_{name}'] = str(path)
    with (work / 'compositor.log').open('w') as log:
        compositor = subprocess.Popen([str(args.compositor.resolve()), '-no-xwayland',
                                       '-policy', args.policy, '-log-level', 'debug', '-c', 'true'],
                                      env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                assert compositor.poll() is None, (work / 'compositor.log').read_text()
                sockets = [p for p in (work / 'runtime').glob('wayland-*') if p.is_socket()]
                if sockets:
                    env['WAYLAND_DISPLAY'] = sockets[0].name
                    break
                time.sleep(.02)
            else:
                raise AssertionError('compositor did not create a Wayland socket')
            run([work / 'client', args.policy])
            assert compositor.poll() is None, 'compositor exited after client disconnect'
            if args.policy in ('external', 'compare'):
                run([work / 'exit-session'])
            else:
                compositor.terminate()
            assert compositor.wait(timeout=5) == 0
        finally:
            if compositor.poll() is None:
                compositor.terminate()
                try:
                    compositor.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    compositor.kill()
                    compositor.wait()


if __name__ == '__main__':
    main()
