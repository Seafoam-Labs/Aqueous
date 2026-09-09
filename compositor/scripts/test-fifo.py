#!/usr/bin/env python3
"""FIFO wire/cache tests and numbered-frame tests in a private Aqueous session.

Use a build with -Doutput-retry-testing=true. Hardware timing remains a separate
DRM validation; headless presentation here verifies scheduling and queue order.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import socket
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--wlroots-prefix', type=Path, default=ROOT / '.deps/wlroots-render-hook')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--sanitize', action='store_true', help='Link unit fixture with ASan/UBSan (use a sanitized wlroots prefix)')
    parser.add_argument('--unit-only', action='store_true')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-fifo-tests-'))
    print(f'Artifacts: {work}', flush=True)
    env = dict(os.environ)
    prefix = args.wlroots_prefix.resolve()
    env['PKG_CONFIG_PATH'] = str(prefix / 'lib/pkgconfig')
    env['LD_LIBRARY_PATH'] = str(prefix / 'lib')
    children, files, results = [], [], []

    def run(command, **kwargs):
        return subprocess.run([str(v) for v in command], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=30, **kwargs)

    def checked(command):
        result = run(command)
        assert result.returncode == 0, result.stdout
        return result.stdout

    def record(name, **details):
        results.append(dict(case=name, passed=True, **details))
        print(f'PASS {name}', flush=True)

    def request(**data):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(data).encode() + b'\n')
            with client.makefile('r') as response:
                value = json.loads(response.readline())
        assert value.get('ok'), value
        return value

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        files.extend((out, err))
        child = subprocess.Popen([str(v) for v in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def events(label='client'):
        return [json.loads(line) for line in (work / f'{label}.jsonl').read_text().splitlines() if line.endswith('}')]

    def wait(predicate, description, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert compositor.poll() is None, 'private compositor exited; see compositor.log'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(description)

    def burst(client, label, count=8):
        previous = max(e['frame'] for e in events(label) if e['event'] == 'submitted')
        client.stdin.write(b'b'); client.stdin.flush()
        expected = list(range(previous + 1, previous + count + 1))
        wait(lambda: len([e for e in events(label) if e['event'] == 'presented' and e['frame'] in expected]) == count,
             f'{label}: queued frames failed to present in order')
        selected = [e for e in events(label) if e['event'] in ('presented', 'discarded') and e['frame'] in expected]
        assert all(e['event'] == 'presented' for e in selected), selected
        assert [e['frame'] for e in selected] == expected, selected
        return selected

    try:
        generated = []
        for name, xml in {
            'fifo-v1': '/usr/share/wayland-protocols/staging/fifo/fifo-v1.xml',
            'xdg-shell': '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml',
            'presentation-time': '/usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml',
        }.items():
            checked(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            checked(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        flags = checked(['pkg-config', '--cflags', '--libs', 'wlroots-0.20', 'wayland-client', 'wayland-server']).split()
        checked(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                 *(['-fsanitize=address,undefined'] if args.sanitize else []), f'-I{work}',
                 ROOT / 'scripts/fixtures/wlroots-fifo.c', generated[0], '-o', work / 'unit', *flags])
        for case in ('normal', 'duplicate', 'dead-set', 'dead-wait', 'bypass', 'no-expiry'):
            result = run([work / 'unit', *([] if case == 'normal' else [case])])
            (work / f'unit-{case}.log').write_text(result.stdout)
            negative = case in ('bypass', 'no-expiry')
            expected_assertion = 'commits ==' if case == 'bypass' else 'wlr_fifo_manager_v1_output_pending'
            assert (result.returncode == -signal.SIGABRT and expected_assertion in result.stdout) if negative else (result.returncode == 0), result.stdout
            record(f'wire-cache-{case}', returncode=result.returncode)
        if args.unit_only:
            return
        checked(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
                 ROOT / 'scripts/fixtures/fifo-v1-client.c', *generated, '-lwayland-client', '-o', work / 'client'])
        for key in list(env):
            if key.startswith(('AQUEOUS_', 'WLR_')) or key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
                env.pop(key)
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        for directory in ('home', 'config', 'cache', 'state'):
            (work / directory).mkdir()
        env.update(XDG_RUNTIME_DIR=str(runtime), HOME=str(work / 'home'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
                   XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                   WLR_RENDERER=args.renderer, WLR_SCENE_DISABLE_DIRECT_SCANOUT='1')
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('''[layout]
gaps_outer = 0
gaps_inner = 0
border_width = 0
[blur]
enabled = false
[opacity]
enabled = false
[input]
focus_follows_mouse = false
''')
        (work / 'binaries.json').write_text(json.dumps({str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (args.compositor.resolve(), prefix / 'lib/libwlroots-0.20.so')}))
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'info', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no Wayland socket')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        names = [o['name'] for o in request(op='list')['outputs']]
        assert len(names) == 2
        request(op='set', changes=[dict(name=names[0], mode='640x480@60', position=[0, 0]),
                                   dict(name=names[1], mode='640x480@144', position=[640, 0], scale=1.25, transform='90')])
        # Verify failure injection exists before claiming recovery coverage.
        request(op='test_output_retry', name=names[0])
        client = launch([work / 'client', 'aqueous.fifo', names[0], '8'], 'client')
        wait(lambda: any(e['event'] == 'presented' for e in events()), 'initial frame not presented')
        time.sleep(.3)
        samples = burst(client, 'client')
        # Headless is a simulated refresh clock, not proof of DRM latch timing.
        assert samples[-1]['ms'] - samples[0]['ms'] >= 50, samples
        record('60hz-queued-numbered-frames', samples=samples)
        fast = launch([work / 'client', 'aqueous.fifo-fast', names[1], '8'], 'fast')
        wait(lambda: any(e['event'] == 'presented' for e in events('fast')), 'fast output did not present')
        time.sleep(.3)
        record('144hz-queued-numbered-frames', samples=burst(fast, 'fast'))
        for stage in ('scene_build', 'output_commit', 'fallback_build', 'fallback_commit'):
            request(op='test_output_retry', name=names[0], action='arm', stage=stage, count=2,
                    overlay=stage.startswith('fallback'))
            record(f'recovery-{stage}', samples=burst(client, 'client'))
        client.stdin.write(b'h'); client.stdin.flush(); time.sleep(.15)
        previous = max(e['frame'] for e in events() if e['event'] == 'submitted')
        client.stdin.write(b'm'); client.stdin.flush()
        wait(lambda: any(e['event'] == 'presented' and e['frame'] > previous for e in events()), 'FIFO remap stalled')
        time.sleep(.2)
        record('detach-remap', samples=burst(client, 'client'))
        cover = launch([work / 'client', 'aqueous.fifo-cover', names[0], '8'], 'cover')
        wait(lambda: any(e['event'] == 'presented' for e in events('cover')), 'cover did not present')
        time.sleep(.2)
        previous = max(e['frame'] for e in events() if e['event'] == 'submitted')
        client.stdin.write(b'b'); client.stdin.flush()
        wait(lambda: len([e for e in events() if e['event'] == 'discarded' and previous < e['frame'] <= previous + 8]) >= 7,
             'occluded FIFO queue did not drain while covered')
        cover.stdin.write(b'q'); cover.stdin.flush(); cover.wait(timeout=3)
        wait(lambda: any(e['event'] == 'presented' and e['frame'] >= previous + 8 for e in events()),
             'uncovered FIFO surface did not resume')
        time.sleep(.2)
        record('occluded-queue-forward-progress')
        for i in range(10):
            burst(client, 'client')
        record('sustained-queue', frames=80)
        time.sleep(.2)
        before = len([e for e in events() if e['event'] == 'presented'])
        before_seq = request(op='test_output_retry', name=names[0])['commit_seq']
        time.sleep(.3)
        assert len([e for e in events() if e['event'] == 'presented']) == before
        idle = request(op='test_output_retry', name=names[0])
        assert idle['commit_seq'] == before_seq and not idle['timer_armed'], idle
        record('client-and-output-idle')
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
        for file in files:
            file.close()
        (work / 'results.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
