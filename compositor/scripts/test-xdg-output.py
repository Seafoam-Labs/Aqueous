#!/usr/bin/env python3
"""Check xdg-output refreshes against the installed patched wlroots library."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def runtime_case(work, fixture, args, base_env, scaling):
    case = work / scaling
    case.mkdir()
    env = {k: v for k, v in base_env.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    for key, name in (('HOME', 'home'), ('XDG_RUNTIME_DIR', 'run'),
                      ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state')):
        path = case / name
        path.mkdir(mode=0o700)
        env[key] = str(path)
    config = case / 'config/aqueous'
    config.mkdir()
    (config / 'wm.toml').write_text('[workspace_transition]\nenabled = false\n')
    for name in ('rules', 'input', 'layout', 'outputs'):
        (config / f'{name}.toml').write_text('')
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
    observers = []
    x11 = None
    compositor = None

    def wait(check):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (case / 'compositor.log').read_text()
            result = check()
            if result:
                return result
            time.sleep(.02)
        raise AssertionError('timed out waiting for compositor state')

    def ctl(*values):
        return json.loads(subprocess.check_output(
            [args.ctl.resolve(), *values, '--json'], env=env, text=True, timeout=10))

    def output_request(**values):
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(5)
            channel.connect(str(case / 'run/aqueous/outputd.sock'))
            channel.sendall(json.dumps(values).encode() + b'\n')
            return json.loads(channel.makefile().readline())

    def command(observer, text):
        assert observer.poll() is None
        observer.stdin.write(text + '\n')
        observer.stdin.flush()
        assert select.select([observer.stdout], [], [], 5)[0], 'observer response timed out'
        return observer.stdout.readline().strip()

    def samples():
        return [json.loads(command(observer, 's')) for observer in observers]

    def reset():
        # Allow a transaction and its follow-up window configures to finish.
        time.sleep(.1)
        for observer in observers:
            assert command(observer, 'r') == 'reset'

    def quiet():
        time.sleep(.1)
        for sample in samples():
            assert all(h[key] == 0 for h in sample for key in
                       ('positions', 'sizes', 'xdg_done', 'output_done')), sample

    def change(*options):
        subprocess.run(['wlr-randr', '--output', 'HEADLESS-2', *options],
                       env=env, check=True, timeout=10)
        time.sleep(.15)
        return samples()

    with (case / 'compositor.log').open('w') as log, (case / 'x11.log').open('w') as x11_log:
        try:
            compositor = subprocess.Popen(
                [args.compositor.resolve(), '-policy', 'internal', '-xwayland-scaling', scaling,
                 '-c', 'printenv DISPLAY > "$XDG_RUNTIME_DIR/display"'],
                env=env, stdout=log, stderr=log)
            env['WAYLAND_DISPLAY'] = wait(lambda: next(
                (p.name for p in (case / 'run').glob('wayland-*') if p.is_socket()), None))
            env['DISPLAY'] = wait(lambda: (case / 'run/display').read_text().strip()
                                  if (case / 'run/display').exists() else None)
            x11 = subprocess.Popen([work / 'x11'], env=env, stdout=x11_log, stderr=x11_log)
            window = wait(lambda: next(iter(ctl('windows')), None))
            for version in (1, 2, 3):
                observer = subprocess.Popen([fixture, 'observe', str(version)], env=env,
                                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                observers.append(observer)
                assert select.select([observer.stdout], [], [], 5)[0]
                assert observer.stdout.readline().strip() == 'ready'
            initial = samples()
            assert all(len(sample) == 2 and all(h['positions'] == h['sizes'] == 1 for h in sample)
                       for sample in initial), initial
            reset()
            for index in range(12):
                ctl('layout', '--output', 'HEADLESS-1', '--set', 'grid' if index % 2 else 'rows')
                ctl('window', 'move', '--id', window['id'], '--output',
                    'HEADLESS-1' if index % 2 else 'HEADLESS-2')
            quiet()

            changed = change('--pos=-1280,-200')
            assert all(any(h['name'] == 'HEADLESS-2' and h['positions'] == 1 and h['sizes'] == 0
                           and (h['x'], h['y']) == (-1280, -200) for h in sample)
                       for sample in changed), changed
            reset()
            changed = change('--scale', '1.25')
            assert all(any(h['name'] == 'HEADLESS-2' and h['positions'] == 0 and h['sizes'] == 1
                           and (h['width'], h['height']) == (1024, 576) for h in sample)
                       for sample in changed), changed
            reset()
            changed = change('--transform', '90')
            assert all(any(h['name'] == 'HEADLESS-2' and h['positions'] == 0 and h['sizes'] == 1
                           and (h['width'], h['height']) == (576, 1024) for h in sample)
                       for sample in changed), changed
            reset()
            changed = change('--custom-mode', '1600x900')
            assert all(any(h['name'] == 'HEADLESS-2' and h['sizes'] == 1
                           and (h['width'], h['height']) == (720, 1280) for h in sample)
                       for sample in changed), changed
            reset()
            rejected = output_request(op='set', changes=[dict(name='HEADLESS-2', position=[-40000, -200])])
            assert not rejected['ok'], rejected
            quiet()
            changed = change('--off')
            assert all(len(sample) == 1 for sample in changed), changed
            reset()
            changed = change('--on')
            # Global reannouncement creates fresh resources with initial geometry.
            def reenabled():
                values = samples()
                return values if all(len(v) == 2 and all(h['width'] > 0 for h in v)
                                     for v in values) else None

            changed = wait(reenabled)
            assert all(any(h['name'] == 'HEADLESS-2' and h['positions'] == h['sizes'] == 1
                           for h in sample) for sample in changed), changed
            reset()
            ctl('layout', '--output', 'HEADLESS-1', '--set', 'tile')
            quiet()
            print(f'PASS: {scaling} XWayland runtime, unchanged transactions, position/scale/rotation/mode, '
                  'rejected changes and output reenable (xdg-output v1–3)', flush=True)
        finally:
            for process in [*observers, x11, compositor]:
                if process is not None and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prefix', type=Path, nargs='?', default=ROOT / '.deps/wlroots-render-hook')
    parser.add_argument('--compositor', type=Path, help='Also run isolated compositor transactions with XWayland')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    env = dict(os.environ)
    env['PKG_CONFIG_PATH'] = str(prefix / 'lib/pkgconfig') + ':' + env.get('PKG_CONFIG_PATH', '')
    env['LD_LIBRARY_PATH'] = str(prefix / 'lib') + ':' + env.get('LD_LIBRARY_PATH', '')
    protocols = Path(subprocess.check_output(
        ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], env=env, text=True).strip())
    xml = protocols / 'unstable/xdg-output/xdg-output-unstable-v1.xml'
    with tempfile.TemporaryDirectory(prefix='aqueous-xdg-output-') as temporary:
        work = Path(temporary)
        subprocess.run(['wayland-scanner', 'client-header', xml, work / 'xdg-output.h'], check=True)
        subprocess.run(['wayland-scanner', 'private-code', xml, work / 'xdg-output.c'], check=True)
        flags = subprocess.check_output(
            ['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-server', 'wayland-client'],
            env=env, text=True).split()
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                        '-I' + str(work), ROOT / 'scripts/fixtures/wlroots-xdg-output.c',
                        work / 'xdg-output.c', *flags, '-o', work / 'client'], env=env, check=True)
        for version in (1, 2, 3):
            subprocess.run([work / 'client', str(version)], env=env, check=True, timeout=20)
        if args.compositor:
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror',
                            ROOT / 'scripts/fixtures/xwayland-negative-position.c',
                            '-lX11', '-o', work / 'x11'], check=True)
            for scaling in ('legacy', 'native'):
                runtime_case(work, work / 'client', args, env, scaling)


if __name__ == '__main__':
    main()
