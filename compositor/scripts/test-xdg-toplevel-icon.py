#!/usr/bin/env python3
"""Exercise real icon protocol requests, committed shell state, and PNG readback."""
import argparse
import base64
import io
import json
import os
from pathlib import Path
import signal
import select
import subprocess
import tempfile
import time
from PIL import Image
from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-icon-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs, clients = [], [], []
    compositor = None

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, message='condition timed out'):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if compositor is not None:
                assert compositor.poll() is None, (work / 'compositor.log').read_text()[-8000:]
            value = predicate()
            if value:
                return value
            time.sleep(.02)
        raise AssertionError(message)

    def events(label):
        return [json.loads(line) for line in (work / f'{label}.jsonl').read_text().splitlines()]

    def fixture(label):
        child = launch([work / 'client'], label)
        wait(lambda: any(e.get('ready') for e in events(label)), f'{label}: missing global')
        assert [e['size'] for e in events(label) if 'size' in e] == [32, 64, 128]
        assert any(e.get('done') for e in events(label))
        return child

    def command(line, child=None, label='client', error=None):
        child = client if child is None else child
        before = len(events(label))
        child.stdin.write((line + '\n').encode()); child.stdin.flush()
        if error is not None:
            wait(lambda: any('error' in e for e in events(label)[before:]), f'missing error for {line}')
            result = next(e for e in events(label)[before:] if 'error' in e)
            assert result['error'] == error, result
            assert child.wait(timeout=5) == 0
            return
        wait(lambda: any('command' in e for e in events(label)[before:]), f'unfinished {line}')
        assert all(e.get('releases', 0) == 0 for e in events(label)), 'icon emitted wl_buffer.release'

    def window(number):
        return next((w for w in ipc.snapshot()['upsert'] if w['kind'] == 'window' and w['title'] == f'icon-window-{number}'), None)

    def fetch(w, size=32, scale=1, **extra):
        return ipc.call('window.icon', dict(id=w['id'], revision=w['icon']['revision'], size=size, scale=scale), **extra)

    def pixel(w, color, size=32, scale=1):
        result = fetch(w, size, scale)['result']
        assert result['revision'] == w['icon']['revision'] and result['format'] == 'png'
        with Image.open(io.BytesIO(base64.b64decode(result['data']))) as image:
            assert image.size == (size * scale, size * scale)
            actual = image.convert('RGBA').getpixel((image.width // 2, image.height // 2))
            assert all(abs(a - b) <= 2 for a, b in zip(actual, color)), (actual, color)

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-toplevel-icon': protocols / 'staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
            'single-pixel-buffer': protocols / 'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
        }.items():
            subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
            code = work / f'{name}.c'
            subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True); generated.append(code)
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}', ROOT / 'scripts/fixtures/xdg-toplevel-icon.c',
                        *generated, '-lwayland-client', '-o', work / 'client'], check=True)
        runtime = work / 'run'; runtime.mkdir(mode=0o700)
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None))
        socket = wait(lambda: next(runtime.glob('aqueous/*/ipc.sock'), None))
        ipc = Client(socket); clients.append(ipc)
        assert ipc.capabilities['capabilities']['icon_metadata'] and ipc.capabilities['capabilities']['icon_fetch']
        client = fixture('client')
        command('sandbox')
        normal_display = env['WAYLAND_DISPLAY']
        env['WAYLAND_DISPLAY'] = 'icon-sandbox'
        sandboxed = fixture('sandboxed')
        env['WAYLAND_DISPLAY'] = normal_display
        command('icon 0', sandboxed, 'sandboxed'); command('window 4 0 1', sandboxed, 'sandboxed')
        wait(lambda: window(4))
        sandboxed.stdin.write(b'quit\n'); sandboxed.stdin.flush(); assert sandboxed.wait(timeout=5) == 0
        wait(lambda: window(4) is None)
        command('icon 0'); command('name 0 test-theme-icon')
        command('buffer 0 32 32 ffff0000 0'); command('add 0 0 1')
        command('buffer 1 64 64 ff00ff00 0'); command('add 0 1 2')
        command('window 0 0 1')
        w = wait(lambda: window(0)); assert w['icon']['name'] == 'test-theme-icon'
        pixel(w, (255, 0, 0, 255)); pixel(w, (0, 255, 0, 255), scale=2)
        command('window 1 0 1'); wait(lambda: window(1)); pixel(window(1), (255, 0, 0, 255))
        command('destroy-icon 0'); command('destroy-buffer 0'); command('destroy-buffer 1'); command('overwrite 0')
        pixel(window(0), (255, 0, 0, 255), size=31)  # Fresh encode, independent of client storage.
        print('PASS initial assignment, shared snapshots, scale variants, icon/buffer destruction', flush=True)

        command('icon 1'); command('buffer 2 64 64 80000080 0'); command('add 1 2 1')
        previous = window(0)['icon']
        subscriber = Client(socket); clients.append(subscriber)
        subscriber.call('subscribe')
        initial = subscriber.receive(); assert initial['batch']['type'] == 'snapshot'; subscriber.ack(initial)
        command('set 0 1'); assert window(0)['icon'] == previous
        assert not select.select([subscriber.socket], [], [], .1)[0], 'uncommitted icon published'

        command('commit 0'); w = wait(lambda: window(0) if window(0)['icon'] != previous else None)
        delta = subscriber.receive()
        assert any(e.get('id') == w['id'] and e.get('icon') == w['icon'] for e in delta['batch']['upsert'])
        subscriber.ack(delta); subscriber.close(); clients.remove(subscriber)
        pixel(w, (0, 0, 255, 128))
        assert fetch(dict(w, icon=previous), ok=False)['error']['code'] == 'stale_revision'
        command('set 0 1'); command('commit 0'); assert window(0)['icon'] == w['icon']
        command('set 0 -1'); command('set 0 1'); command('commit 0'); assert window(0)['icon'] == w['icon']
        command('set 0 -1'); assert window(0)['icon'] == w['icon']; command('commit 0'); assert window(0)['icon'] is None
        command('icon 2'); command('set 1 2'); command('commit 1'); assert window(1)['icon'] is None
        command('set 0 1'); command('commit 0'); command('unmap 0'); wait(lambda: window(0) is None)
        command('remap 0'); w = wait(lambda: window(0)); pixel(w, (0, 0, 255, 128))
        command('window 2 1 0'); command('destroy-window 2')
        command('icon 6'); command('buffer 6 32 32 ffffff00 0'); command('add 6 6 1')
        command('window 3 6 0'); command('destroy-icon 6'); command('destroy-buffer 6'); command('commit 3')
        pixel(wait(lambda: window(3)), (255, 255, 0, 255)); command('destroy-window 3')
        print('PASS commit timing, last assignment, reset, empty icon, remap and destroy-before-map', flush=True)

        command('icon 3'); command('name 3 missing-theme-icon'); command('set 1 3'); command('commit 1')
        assert window(1)['icon']['has_pixels'] is False
        assert fetch(window(1), ok=False)['error']['code'] == 'unavailable'
        assert fetch(w, size=256, scale=2, ok=False)['error']['code'] == 'invalid'
        # Same size and scale uses the most recently supplied buffer.
        command('icon 4'); command('buffer 3 32 32 ffff0000 1'); command('add 4 3 1')
        command('buffer 4 32 32 ff00ff00 1'); command('add 4 4 1'); command('destroy-buffer 3')
        command('set 1 4'); command('commit 1'); pixel(window(1), (0, 255, 0, 255))
        command('icon 5'); command('add 5 4 0'); command('set 1 5'); command('commit 1')
        assert not window(1)['icon']['has_pixels']
        # An active overview must reflect commits without reopening it.
        output = next(o['id'] for o in ipc.snapshot()['upsert'] if o['kind'] == 'output')
        ipc.command('overview.show', dict(output=output))
        command('set 1 4'); command('commit 1')
        screenshot = work / 'overview.png'
        subprocess.run(['grim', '-o', 'HEADLESS-1', screenshot], env=env, check=True)
        with Image.open(screenshot) as image:
            assert any(g > 240 and r < 8 and b < 8 for r, g, b in image.convert('RGB').getdata()), 'missing green overview icon'
        ipc.command('overview.hide')
        command('destroy-manager'); command('destroy-icon 4'); command('destroy-icon 5'); command('destroy-buffer 4')
        pixel(window(1), (0, 255, 0, 255), size=30)
        print('PASS names, replacements, invalid scales, query bounds, live overview and manager destruction', flush=True)

        for label, setup, bad, error in [
            ('immutable', ['icon 0', 'window 3 0 1'], 'name 0 changed', 2),
            ('immutable-buffer', ['icon 0', 'buffer 0 32 32 ffffffff 0', 'window 3 0 1'], 'add 0 0 1', 2),
            ('no-buffer', ['icon 0', 'buffer 0 32 32 ffffffff 0', 'add 0 0 1'], 'destroy-buffer 0', 3),
            ('not-square', ['icon 0', 'buffer 0 32 16 ffffffff 0'], 'add 0 0 1', 1),
            ('not-shm', ['icon 0', 'nonshm 0'], 'add 0 0 1', 1),
        ]:
            child = fixture(label)
            for step in setup: command(step, child, label)
            command(bad, child, label, error=error)
        limited = fixture('variant-limit')
        command('icon 0', limited, 'variant-limit'); command('buffer 0 32 32 ffffffff 0', limited, 'variant-limit')
        for scale in range(1, 17): command(f'add 0 0 {scale}', limited, 'variant-limit')
        command('add 0 0 17', limited, 'variant-limit', error=2)
        limited = fixture('byte-limit')
        command('icon 0', limited, 'byte-limit'); command('buffer 0 2049 2049 ffffffff 0', limited, 'byte-limit')
        command('add 0 0 1', limited, 'byte-limit', error=2)
        limited = fixture('object-limit')
        for _ in range(256): command('icon 0', limited, 'object-limit')
        command('icon 0', limited, 'object-limit', error=2)
        # Disconnect while encoding a maximum-size response; the worker must not retain its IPC client.
        aborted = Client(socket)
        aborted.send(aborted.frame('window.icon', dict(id=window(1)['id'], revision=window(1)['icon']['revision'], size=256, scale=1)))
        aborted.close()
        pixel(window(1), (0, 255, 0, 255))
        print('PASS protocol errors, resource budgets and disconnect during PNG encoding; compositor survived', flush=True)
        client.stdin.write(b'quit\n'); client.stdin.flush(); assert client.wait(timeout=5) == 0
        wait(lambda: not any(w['kind'] == 'window' for w in ipc.snapshot()['upsert']))
        print(f'PASS xdg-toplevel-icon-v1 ({args.renderer})', flush=True)
    finally:
        for client in clients: client.close()
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs: log.close()


if __name__ == '__main__':
    main()
