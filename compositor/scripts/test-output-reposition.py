#!/usr/bin/env python3
"""Output moves preserve floating geometry, hidden workspaces and preview rollback.

Runs only a private two-output headless compositor. Requires the same Wayland
client build tools as test-floating-outputs.sh. Set AQUEOUS_COMPOSITOR_BIN and
AQUEOUSCTL_BIN to test a staged build.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import tempfile
import time

from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl'))


def main():
    with tempfile.TemporaryDirectory(prefix='aqueous-output-reposition-') as tmp:
        base = Path(tmp)
        env = {k: os.environ[k] for k in ('PATH', 'LANG', 'TZ') if k in os.environ}
        for key, name in [('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'), ('XDG_RUNTIME_DIR', 'run')]:
            path = base / name
            path.mkdir(mode=0o700)
            env[key] = str(path)
        cfg = base / 'config/aqueous'
        cfg.mkdir()
        wm = '[layout]\ndefault = "floating"\ngaps_outer = 0\n[workspace_transition]\nenabled = false\n'
        (cfg / 'wm.toml').write_text(wm)
        (cfg / 'layout.toml').write_text(wm)
        (cfg / 'rules.toml').write_text('[[window]]\napp_id = "reposition-overlay"\nfloating = true\nwidth = 320\nheight = 200\nx = 120\ny = 100\n')
        (cfg / 'outputs.toml').write_text('[[output]]\nname = "*"\nmode = "3840x2160@60"\nscale = 2\n')
        env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman',
                   AQUEOUS_CONFIG=str(cfg / 'wm.toml'), AQUEOUS_LAYOUT=str(cfg / 'layout.toml'),
                   AQUEOUS_RULES=str(cfg / 'rules.toml'))
        protocols = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
        sources = []
        for name, xml in [('xdg-shell', protocols / 'stable/xdg-shell/xdg-shell.xml'),
                          ('wlr-virtual-pointer-unstable-v1', ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml')]:
            subprocess.run(['wayland-scanner', 'client-header', str(xml), str(base / f'{name}-client-protocol.h')], check=True)
            source = base / f'{name}-protocol.c'
            subprocess.run(['wayland-scanner', 'private-code', str(xml), str(source)], check=True)
            sources.append(str(source))
        fixture = base / 'fixture'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
        subprocess.run(['cc', '-std=c11', '-O2', '-I' + str(base), str(ROOT / 'scripts/fixtures/xdg-floating-request.c'),
                        *sources, '-o', str(fixture), *flags], check=True)
        log = (base / 'compositor.log').open('w+')
        proc = subprocess.Popen(['dbus-run-session', '--', str(BIN), '-no-xwayland', '-c',
                                 'printenv AQUEOUS_SOCKET WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/socket"'],
                                env=env, stdout=log, stderr=log, start_new_session=True)
        children = []
        client = None

        def wait(fn):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                assert proc.poll() is None, 'private compositor exited'
                result = fn()
                if result:
                    return result
                time.sleep(.03)
            raise AssertionError('condition timed out')

        def ctl(*args):
            return json.loads(subprocess.check_output([str(CTL), *args, '--json'], env=env, text=True, timeout=5))

        try:
            marker = base / 'run/socket'
            lines = wait(lambda: marker.read_text().splitlines() if marker.exists() and len(marker.read_text().splitlines()) == 2 else None)
            client = Client(lines[0])
            env.update(AQUEOUS_SOCKET=lines[0], WAYLAND_DISPLAY=lines[1])

            def model():
                return client.call('display.snapshot')['result']

            def settled():
                m = model()
                return m if m['observation'] == 'current' else None

            snap = wait(settled)
            names = [o['connector'] for o in sorted(snap['outputs'], key=lambda o: o['actual']['x'])]
            assert len(names) == 2
            for app in ('reposition-layout', 'reposition-overlay'):
                sync = base / app
                sync.mkdir()
                children.append(subprocess.Popen([str(fixture), str(sync), app, 'idle'], env=env, stdout=log, stderr=log))
                wait(lambda: any(w['app_id'] == app for w in ctl('windows')))
            time.sleep(.2)
            original = {w['app_id']: w for w in ctl('windows')}
            assert 'floating' in original['reposition-overlay']['states'], original
            assert all(w['output'] == names[0] for w in original.values()), original

            def check(dx, dy=0):
                expected = {app: dict(w['geometry'], x=w['geometry']['x'] + dx, y=w['geometry']['y'] + dy)
                            for app, w in original.items()}
                wait(lambda: len(ws := ctl('windows')) == len(expected) and all(
                    w['geometry'] == expected[w['app_id']] for w in ws))
                assert all(w['output'] == names[0] for w in ctl('windows'))

            def apply(positions, extra=None):
                changes = [dict(name=name, position=position, **(extra[i] if isinstance(extra, list) else extra or {}))
                           for i, (name, position) in enumerate(zip(names, positions))]
                with socket.socket(socket.AF_UNIX) as wire:
                    wire.settimeout(5)
                    wire.connect(str(base / 'run/aqueous/outputd.sock'))
                    wire.sendall(json.dumps(dict(op='set', changes=changes)).encode() + b'\n')
                    result = json.loads(wire.makefile().readline())
                    assert result['ok'], result
                wait(lambda: (m if (m := settled()) and all(
                    [o['actual']['x'], o['actual']['y']] == positions[names.index(o['connector'])]
                    for o in m['outputs']) else None))

            apply([[7680, 0], [5760, 0]])
            check(7680)
            apply([[0, 0], [1920, 0]])
            check(0)
            # Workspaces which are not currently arranged must also follow.
            records = ctl('shell', 'snapshot')['upsert']
            output_id = next(r['id'] for r in records if r['kind'] == 'output' and r['name'] == names[0])
            workspaces = [r for r in records if r['kind'] == 'workspace' and r['output'] == output_id]
            current = next(r for r in workspaces if r['active'])
            other = next(r for r in workspaces if not r['active'])
            ctl('workspace', 'activate', '--id', other['id'])
            wait(lambda: all('visible' not in w['states'] for w in ctl('windows')))
            apply([[-1920, -120], [0, 0]])
            ctl('workspace', 'activate', '--id', current['id'])
            check(-1920, -120)
            print('PASS: output-relative floating, overlay and inactive-workspace geometry', flush=True)

            # Exercise the native preview lease and its real rollback path.
            snap = wait(settled)
            source = ''.join(f'[[output]]\nname = "{name}"\nposition = [{x}, 0]\n' for name, x in zip(names, [0, 1920]))
            preview = client.call('display.preview.begin', dict(expected_generation=snap['config_generation'],
                display_revision=snap['display_revision'], candidate_digest='a' * 64,
                wm_source=wm, outputs_source=source))['result']
            token = preview['token']
            wait(lambda: client.call('display.preview.status', dict(token=token))['result']['state'] == 'previewing')
            check(0)
            client.call('display.preview.revert', dict(token=token))
            wait(lambda: not model()['preview_active'])
            check(-1920, -120)
            print('PASS: preview moves and rollback restore floating positions exactly', flush=True)

            # A maximized overlay keeps a separate floating restore rectangle.
            overlay = original['reposition-overlay']['id']
            ctl('window', 'state', '--id', overlay, '--maximized', 'true')
            wait(lambda: 'maximized' in next(w for w in ctl('windows') if w['id'] == overlay)['states'])
            apply([[0, 0], [1920, 0]])
            ctl('window', 'state', '--id', overlay, '--maximized', 'false')
            check(0)
            # Dormant floating-layout caches must follow even while tiling.
            ctl('layout', '--output', names[0], '--set', 'tile')
            apply([[-1920, 0], [0, 0]])
            ctl('layout', '--output', names[0], '--set', 'floating')
            check(-1920)
            print('PASS: maximize restore and dormant floating layout follow output moves', flush=True)

            apply([[0, 0], [1080, 0]], dict(transform='90'))
            wait(lambda: all(w['geometry']['x'] >= 0 and w['geometry']['x'] + w['geometry']['width'] <= 1080 for w in ctl('windows')))
            for w in ctl('windows'):
                rect = w['geometry']
                assert rect['x'] >= 0 and rect['y'] >= 0 and rect['x'] + rect['width'] <= 1080, w
            stable = {w['id']: w['geometry'] for w in ctl('windows')}
            # Mixed scaling on another head must not translate these again.
            apply([[0, 0], [1080, 0]], [{}, {'scale': 1.5}])
            wait(settled)
            assert {w['id']: w['geometry'] for w in ctl('windows')} == stable
            print('PASS: rotated output keeps windows reachable; mixed scaling does not drift', flush=True)
        except BaseException:
            log.flush()
            log.seek(0)
            print(log.read()[-5000:])
            raise
        finally:
            if client:
                client.close()
            for child in children:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=5)
            log.close()


if __name__ == '__main__':
    main()
