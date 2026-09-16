#!/usr/bin/env python3
"""Check upgraded globals and old/new clients in a private headless session."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='vulkan')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-protocol-versions-'))
    print(f'Artifacts: {work}', flush=True)
    protocols = Path(subprocess.check_output(
        ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    generated = []
    for name, xml in {
        'xdg-shell': 'stable/xdg-shell/xdg-shell.xml',
        'decoration': 'unstable/xdg-decoration/xdg-decoration-unstable-v1.xml',
        'text-input': 'unstable/text-input/text-input-unstable-v3.xml',
        'tablet': 'stable/tablet/tablet-v2.xml',
        'dmabuf': 'stable/linux-dmabuf/linux-dmabuf-v1.xml',
    }.items():
        subprocess.run(['wayland-scanner', 'client-header', protocols / xml, work / f'{name}.h'], check=True)
        subprocess.run(['wayland-scanner', 'private-code', protocols / xml, work / f'{name}.c'], check=True)
        generated.append(work / f'{name}.c')
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    '-I' + str(work), ROOT / 'scripts/fixtures/protocol-versions.c',
                    *generated, *flags, '-o', work / 'client'], check=True)
    env = dict(os.environ)
    # A desktop session may export LD_LIBRARY_PATH for its installed version.
    # Exercise the library bundled beside the binary under test first.
    bundled_library = args.compositor.resolve().parent.parent / 'lib/aqueous'
    env['LD_LIBRARY_PATH'] = str(bundled_library) + ':' + env.get('LD_LIBRARY_PATH', '')
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
        compositor = subprocess.Popen([args.compositor.resolve(), '-no-xwayland', '-c', 'true'],
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
                raise AssertionError('no compositor socket')
            modes = ['legacy', 'current', 'mapped-v1-error', 'invalid-action']
            if args.renderer == 'vulkan':
                modes.append('invalid-device')
            for mode in modes:
                subprocess.run([work / 'client', mode, args.renderer], env=env, check=True, timeout=15)
                assert compositor.poll() is None, (work / 'compositor.log').read_text()
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
