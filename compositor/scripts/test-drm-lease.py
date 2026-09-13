#!/usr/bin/env python3
"""DRM lease registry/fallback checks, or explicit hardware lease/release checks.

Default mode creates a private headless compositor. --hardware connects to the
current compositor and requires explicit --connector selection; it never changes
which outputs are offered by the compositor. Kernel scanout/VR remains manual.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--policy', choices=('internal', 'external'), default='internal')
    parser.add_argument('--hardware', action='store_true')
    parser.add_argument('--connector', action='append', default=[])
    parser.add_argument('--device')
    args = parser.parse_args()
    if args.hardware and not args.connector:
        parser.error('--hardware requires at least one explicit --connector')
    if not args.hardware and (args.connector or args.device):
        parser.error('--connector/--device require --hardware')
    work = Path(tempfile.mkdtemp(prefix='aqueous-drm-lease-'))
    print(f'Artifacts: {work}', flush=True)
    env = dict(os.environ)
    children, files = [], []
    compositor = None

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True, stderr=subprocess.STDOUT, timeout=30)

    def launch(command, label, overrides=None):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        files.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=dict(env, **(overrides or {})),
                                 stdin=subprocess.PIPE, stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def events(label, kind):
        result = []
        for line in (work / f'{label}.jsonl').read_text().splitlines():
            try:
                event = json.loads(line)
                if event['event'] == kind:
                    result.append(event)
            except (ValueError, KeyError):
                pass
        return result

    def wait(predicate, message, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if compositor:
                assert compositor.poll() is None, f'compositor exited; see {work}'
            value = predicate()
            if value:
                return value
            time.sleep(.02)
        raise AssertionError(f'{message}; see {work}')

    def command(child, label, value):
        before = len(events(label, 'command'))
        child.stdin.write((value + '\n').encode()); child.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: {value}')

    def quit_client(child):
        child.stdin.write(b'quit\n'); child.stdin.flush()
        assert child.wait(timeout=8) == 0

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = []
        for name, xml in {
            'drm-lease': protocols / 'staging/drm-lease/drm-lease-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code]); generated.append(code)
        flags = shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client', 'libdrm']))
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/drm-lease.c', *generated, *flags, '-o', work / 'client'])
        if not args.hardware:
            env = {k: v for k, v in env.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
            for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
                env.pop(key, None)
            for name in ('runtime', 'home', 'config', 'cache', 'state'):
                (work / name).mkdir(mode=0o700)
            env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
                       XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
                       XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                       WLR_RENDERER=args.renderer, WLR_LIBINPUT_NO_DEVICES='1')
            compositor = launch([args.compositor.resolve(), '-policy', args.policy, '-no-xwayland',
                                 '-log-level', 'debug', '-c', 'true'], 'compositor')
            env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        selection = [p for name in args.connector for p in ('--connector', name)]
        if args.device:
            selection += ['--device', args.device]
        client = launch([work / 'client', *selection, *([] if args.hardware else ['--absent'])], 'client')
        ready = wait(lambda: events('client', 'ready'), 'client not ready')[0]
        if args.hardware:
            assert ready['devices'] > 0, 'no DRM lease devices advertised'
        else:
            assert ready['devices'] == 0
        command(client, 'client', 'sandbox')
        sandbox_path = events('client', 'sandbox')[0]['socket']
        sandbox = launch([work / 'client', '--absent'], 'sandbox', {'WAYLAND_DISPLAY': sandbox_path})
        wait(lambda: events('sandbox', 'ready'), 'security-context registry failed')
        quit_client(sandbox)
        print('PASS registry and security-context visibility', flush=True)
        if args.hardware:
            before = json.loads(run([args.ctl.resolve(), 'outputs', '--json']))
            for cycle in range(3):
                old_connectors = len(events('client', 'connector'))
                command(client, 'client', 'lease')
                wait(lambda: len(events('client', 'lease_fd')) == cycle + 1, 'no usable lease FD')
                assert json.loads(run([args.ctl.resolve(), 'outputs', '--json'])) == before, 'desktop output inventory changed'
                command(client, 'client', 'release')
                wait(lambda: len(events('client', 'connector')) >= old_connectors + len(args.connector), 'connector did not reappear')
            command(client, 'client', 'lease')
            wait(lambda: len(events('client', 'lease_fd')) == 4, 'no lease before crash')
            client.stdin.write(b'crash\n'); client.stdin.flush(); assert client.wait(timeout=5) == 0
            client = launch([work / 'client', *selection], 'after-crash')
            wait(lambda: events('after-crash', 'ready'), 'no reconnect after client crash')
            command(client, 'after-crash', 'lease')
            wait(lambda: events('after-crash', 'lease_fd'), 'lease not recovered after client crash')
            quit_client(client)
            print('PASS kernel lease resources, repeated release/reacquire, client crash and stable desktop inventory', flush=True)
            print('MANUAL: headset scanout, lock/VT/suspend, unplug and multi-GPU/overlay qualification', flush=True)
        else:
            if args.policy == 'internal':
                wait(lambda: (work / 'runtime/aqueous/outputd.sock').exists(), 'no output control socket')
                outputs = json.loads(run([args.ctl.resolve(), 'outputs', '--json']))
                assert 'HEADLESS-1' in json.dumps(outputs) and 'HEADLESS-2' in json.dumps(outputs)
            quit_client(client)
            compositor.send_signal(signal.SIGTERM); assert compositor.wait(timeout=10) == 0
            print(f'PASS {args.renderer}/{args.policy} headless outputs and clean shutdown', flush=True)
            print('SKIP physical DRM lease/scanout: headless mode', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
        for stream in files:
            stream.close()
        for path in work.glob('*.log'):
            text = path.read_text(errors='replace')
            assert not any(marker in text for marker in ('panic:', 'assertion failure', 'AddressSanitizer')), path


if __name__ == '__main__':
    main()
