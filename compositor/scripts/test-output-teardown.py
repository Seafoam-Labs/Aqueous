#!/usr/bin/env python3
"""Remove outputs with live windows hidden by opaque layer surfaces.

Requires -Doutput-retry-testing=true. Runs in a private headless session and
retains logs. Previously, removing the covering layer during output destruction
attached new wl_surface output listeners and aborted in wlr_output_finish.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='vulkan')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-output-teardown-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    for key, name in (('HOME', 'home'), ('XDG_RUNTIME_DIR', 'runtime'),
                      ('XDG_CONFIG_HOME', 'config'), ('XDG_CACHE_HOME', 'cache'),
                      ('XDG_STATE_HOME', 'state')):
        (work / name).mkdir(mode=0o700)
        env[key] = str(work / name)
    for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        path = work / f'{name.lower()}.toml'
        path.write_text('')
        env[f'AQUEOUS_{name}'] = str(path)
    (work / 'config.toml').write_text('[opacity]\nenabled = false\n[blur]\nenabled = false\n')
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer,
               AQUEOUS_VULKAN_PRESENTATION='copy')
    bundled = args.compositor.resolve().parent.parent / 'lib/aqueous'
    env['LD_LIBRARY_PATH'] = str(bundled) + ':' + env.get('LD_LIBRARY_PATH', '')
    protocols = Path(subprocess.check_output(
        ['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    generated = []
    for name, xml in {
        'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
        'presentation-time': protocols / 'stable/presentation-time/presentation-time.xml',
        'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
    }.items():
        subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
        subprocess.run(['wayland-scanner', 'private-code', xml, work / f'{name}.c'], check=True)
        generated.append(work / f'{name}.c')
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True).split()
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-DTEST_OUTPUT_TEARDOWN',
                    f'-I{work}', ROOT / 'scripts/fixtures/output-retry.c', *generated,
                    *flags, '-o', work / 'client'], check=True)
    children, files = [], []

    def launch(label, command):
        log = (work / f'{label}.log').open('w')
        files.append(log)
        process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=log, stderr=log)
        children.append(process)
        return process

    def wait(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()
            value = predicate()
            if value:
                return value
            time.sleep(.02)
        raise AssertionError(message)

    def events(label, event):
        values = []
        for line in (work / f'{label}.log').read_text().splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if value.get('event') == event:
                values.append(value)
        return values

    def request(**data):
        with socket.socket(socket.AF_UNIX) as control:
            control.settimeout(5)
            control.connect(str(work / 'runtime/aqueous/outputd.sock'))
            control.sendall(json.dumps(data).encode() + b'\n')
            with control.makefile('r') as response:
                line = response.readline()
            assert line, (work / 'compositor.log').read_text()
            result = json.loads(line)
            assert result.get('ok'), result
            return result

    try:
        compositor = launch('compositor', [args.compositor.resolve(), '-no-xwayland', '-c', 'true'])
        env['WAYLAND_DISPLAY'] = wait(
            lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None),
            'no Wayland socket')
        wait(lambda: (work / 'runtime/aqueous/outputd.sock').exists(), 'no output service')
        names = [o['name'] for o in request(op='list')['outputs']]
        assert len(names) == 2, names
        request(op='test_output_retry', name=names[0], action='status')
        for i, name in enumerate(names):
            launch(f'cover-{i}', [work / 'client', 'cover', name, '0'])
            wait(lambda: events(f'cover-{i}', 'presented'), 'cover did not present')
            launch(f'window-{i}', [work / 'client', f'teardown-{i}', name, '0'])
            wait(lambda: any(v['submitted'] > 0 for v in events(f'window-{i}', 'sample')),
                 'covered window did not submit a buffer')
        # Allow the window transactions to settle behind the covers. These
        # windows must never have entered an output before its destroy signal.
        time.sleep(.3)
        for i in range(2):
            assert not events(f'window-{i}', 'enter'), 'window was not fully occluded'
        for i, name in enumerate(names):
            request(op='test_output_retry', name=name, action='destroy')
            wait(lambda: events(f'cover-{i}', 'closed'), 'layer was not closed on output removal')
            assert name not in [o['name'] for o in request(op='list')['outputs']]
        assert request(op='list')['outputs'] == []
        assert all(child.poll() is None for child in children), 'a test client exited unexpectedly'
        compositor.terminate()
        assert compositor.wait(timeout=5) == 0, (work / 'compositor.log').read_text()
        print('PASS: occluded windows survive removal of both outputs; clean shutdown')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in files:
            log.close()


if __name__ == '__main__':
    main()
