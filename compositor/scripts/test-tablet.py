#!/usr/bin/env python3
"""Private tablet-v2, mapping, reload and aqueousctl generation integration test.

Requires an Aqueous build with -Dtablet-testing=true. Uses in-process wlroots
tablet events, not a virtual pointer and not the user's physical input devices.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import tomllib

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--external', action='store_true', help='Check production external-policy ownership and absence of test injection')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-tablet-'))
    print(f'Artifacts: {work}', flush=True)
    runtime = work / 'runtime'; runtime.mkdir(mode=0o700)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_')) and k not in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS')}
    env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
    for key in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        path = work / f'{key.lower()}.toml'; path.write_text('')
        env[f'AQUEOUS_{key}'] = str(path)
    (work / 'config.toml').write_text('[layout]\ngaps_outer=0\ngaps_inner=0\nborder_width=0\n[workspace_transition]\nenabled=false\n[input]\nfocus_follows_mouse=false\nmouse_follows_focus=false\n')
    input_file = work / 'input.toml'
    input_file.write_text('# retain this comment\n[input.mouse]\naccel_speed = 0.25\n')
    children, logs = [], []

    def run(command, check=True):
        return subprocess.run([str(v) for v in command], env=env, capture_output=True,
                              text=True, timeout=30, check=check)

    def launch(command, label):
        out = (work / f'{label}.jsonl').open('w'); err = (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(v) for v in command], env=env, stdout=out, stderr=err, start_new_session=True)
        children.append(child); return child

    def request(**value):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(4); client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(value).encode() + b'\n')
            with client.makefile('r') as stream: result = json.loads(stream.readline())
        assert result.get('ok'), result
        return result

    def tablet(action, device=0, **values):
        return request(op='test_tablet', action=action, device=device, **values)

    def wait(fn, description, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert compositor.poll() is None, f'compositor exited: {work / "compositor.log"}'
            value = fn()
            if value: return value
            time.sleep(.03)
        raise AssertionError(description)

    def devices():
        return json.loads(run([args.ctl, 'input', 'devices', '--json']).stdout)['devices']

    def generate(device_id, output, rule, write=False, path=None):
        cmd = [args.ctl, 'input', 'generate-config', '--device', device_id, '--output', output, '--id', rule]
        if write: cmd += ['--write', path or input_file]
        return run(cmd)

    def events(label):
        return [json.loads(line) for line in (work / f'{label}.jsonl').read_text().splitlines() if line.endswith('}')]

    try:
        generated = []
        for name, xml in [('tablet-v2', '/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml'), ('xdg-shell', '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml')]:
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            run(['wayland-scanner', 'private-code', xml, work / f'{name}.c'])
            generated.append(work / f'{name}.c')
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/tablet-client.c', *generated, '-lwayland-client', '-o', work / 'client'])
        lock_xml = '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml'
        run(['wayland-scanner', 'client-header', lock_xml, work / 'ext-session-lock-v1-client-protocol.h'])
        run(['wayland-scanner', 'private-code', lock_xml, work / 'lock.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/tablet-lock-client.c', work / 'lock.c', '-lwayland-client', '-o', work / 'locker'])
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-policy', 'external' if args.external else 'internal', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'Wayland socket')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'output service')
        if args.external:
            assert not request(op='input_devices')['internal_policy']
            bad = run([args.ctl, 'input', 'generate-config', '--device', '1', '--id', 'pen', '--mapping', 'desktop'], check=False)
            assert bad.returncode != 0 and 'ExternalPolicyOwnsInput' in bad.stderr
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(runtime / 'aqueous/outputd.sock'))
                client.sendall(b'{"op":"test_tablet","action":"add","name":"Test Pen"}\n')
                assert not json.loads(client.recv(4096))['ok']
            print('PASS external-policy ownership and production test-injection gate', flush=True)
            return
        names = [o['name'] for o in request(op='list')['outputs']]
        assert len(names) == 2
        request(op='set', changes=[dict(name=names[0], mode='640x480@60', position=[0, 0]), dict(name=names[1], mode='640x480@60', position=[800, 0])])
        pen_name = 'HUION Pen "4K" #[]\\'
        tablet('add', name=pen_name); tablet('add', device=1, name='Wacom Intuos CTL-490 Pen')
        first_client = launch([work / 'client', names[0]], 'first'); second_client = launch([work / 'client', names[1]], 'second')
        wait(lambda: any(e['event'] == 'configured' for e in events('first')) and any(e['event'] == 'configured' for e in events('second')), 'tablet clients configured')
        ids = [d['id'] for d in devices() if d['type'] == 'tablet']
        assert len(ids) == 2
        before = input_file.read_bytes()
        text = generate(ids[0], names[0], 'kamvas').stdout
        assert input_file.read_bytes() == before
        assert tomllib.loads(text)['input']['tablet'][0]['match_name'] == pen_name
        generate(ids[0], names[0], 'kamvas', True); generate(ids[1], names[1], 'intuos', True)
        assert 'retain this comment' in input_file.read_text()
        assert tomllib.loads(input_file.read_text())['input']['mouse']['accel_speed'] == .25
        before = input_file.read_bytes(); generate(ids[1], names[1], 'intuos', True)
        assert input_file.read_bytes() == before
        wait(lambda: all(d['status'] == 'resolved' for d in devices() if d['type'] == 'tablet'), 'generated policy applied')
        print('PASS discovery, escaped-name TOML generation, scoped/idempotent writes and reload', flush=True)

        t = tablet('in', x=.25, y=.25); assert abs(t['x']-160) < .01 and abs(t['y']-120) < .01, t
        mouse = (t['mouse_x'], t['mouse_y'])
        t = tablet('in', device=1, x=.25, y=.25); assert abs(t['x']-960) < .01, t
        baseline_pointer_events = sum(e['event'] in ('pointer_motion', 'pointer_button') for label in ('first', 'second') for e in events(label))
        for device, x0 in ((0, 0), (1, 800)):
            for x, y in ((0, 0), (1, 1), (-1, 2), (.5, .5)):
                t = tablet('axis', device=device, x=x, y=y)
                assert x0 <= t['x'] < x0+640 and 0 <= t['y'] < 480, t
                assert (t['mouse_x'], t['mouse_y']) == mouse, t
            t = tablet('axis', device=device, x=.25)
            assert abs(t['y']-240) < .01, t
        tablet('down'); tablet('axis', x=.4, y=.4); tablet('button'); tablet('release'); tablet('up')
        wait(lambda: any(e['event'] == 'pressure' for e in events('first')) and any(e['event'] == 'tilt' for e in events('second')), 'tablet pressure and tilt')
        assert sum(e['event'] in ('pointer_motion', 'pointer_button') for label in ('first', 'second') for e in events(label)) == baseline_pointer_events
        print('PASS separate tablet-v2 events, edge confinement, partial axes and mouse independence', flush=True)

        tablet('down')
        pen = tablet('state'); moved = tablet('mouse', x=.8, y=.6)
        assert (moved['x'], moved['y']) == (pen['x'], pen['y']) and moved['down']
        assert (moved['mouse_x'], moved['mouse_y']) != mouse
        wait(lambda: any(e['event'] == 'pointer_enter' for e in events('second')), 'independent mouse focus')
        tablet('mouse', x=.85, y=.65)
        wait(lambda: any(e['event'] == 'pointer_motion' for e in events('second')), 'independent mouse motion')
        tablet('up')
        transforms = ('normal', '90', '180', '270', 'flipped', 'flipped-90', 'flipped-180', 'flipped-270')
        # Expected coordinates are specified independently of the compositor helper.
        points = ((.2,.3), (.7,.2), (.8,.7), (.3,.8), (.8,.3), (.3,.2), (.2,.7), (.7,.8))
        for scale in (1, 1.5, 2):
            for i, transform in enumerate(transforms):
                tablet('out')
                request(op='set', changes=[dict(name=names[0], mode='600x480@60', position=[-800, -200], transform=transform, scale=scale)])
                width, height = ((480, 600) if i % 2 else (600, 480))
                u, v = points[i]
                def mapped():
                    t = tablet('in', x=.2, y=.3)
                    return abs(t['x']-(-800+u*width/scale)) < .01 and abs(t['y']-(-200+v*height/scale)) < .01
                wait(mapped, f'{transform} at {scale}x with negative origin')
        tablet('out')
        request(op='set', changes=[dict(name=names[0], mode='640x480@60', position=[0, 0], transform='normal', scale=1)])
        wait(lambda: abs(tablet('in', x=.5, y=.5)['x']-320) < .01, 'original layout restored')
        print('PASS independent mouse during pen-down, all rotations/reflections at 1x/1.5x/2x and negative origins', flush=True)

        generate(ids[0], names[1], 'kamvas', True)
        wait(lambda: tablet('state')['pending'], 'mapping deferred during proximity')
        assert tablet('axis', x=.5, y=.5)['x'] < 640
        tablet('out'); assert tablet('in', x=.5, y=.5)['x'] > 800
        # A malformed reload must not silently release the existing restriction.
        good = input_file.read_text(); input_file.write_text(good + '\n[[input.tablet]]\nid="bad"\nmatch_name="Pen"\noutput=42\n')
        time.sleep(1.2)
        assert tablet('axis', x=.25, y=.25)['x'] > 800
        input_file.write_text(good)
        tablet('down'); tablet('button')
        request(op='set', changes=[dict(name=names[1], enabled=False)])
        wait(lambda: tablet('state')['status'] == 'waiting_output', 'missing target suspends pen')
        t = tablet('state'); assert not t['down'] and t['buttons'] == 0 and t['wait_release'], t
        request(op='set', changes=[dict(name=names[1], enabled=True)])
        wait(lambda: tablet('state')['status'] == 'resolved', 'target restored')
        tablet('axis', x=.5, y=.5); assert not tablet('state')['down']
        tablet('up'); tablet('out'); tablet('in'); tablet('down'); tablet('up')
        print('PASS deferred remap, invalid reload retention, output loss and balanced stroke recovery', flush=True)

        tablet('out'); tablet('out', device=1)
        for option in (['--disabled'], ['--mapping', 'desktop']):
            run([args.ctl, 'input', 'generate-config', '--device', ids[0], '--id', 'kamvas', *option, '--write', input_file])
            expected_status = 'disabled' if option == ['--disabled'] else 'desktop'
            wait(lambda: next(d['status'] for d in devices() if d['id'] == ids[0]) == expected_status, expected_status)
            t = tablet('in', x=.9, y=.5)
            if expected_status == 'disabled':
                tablet('down'); assert not tablet('state')['down']; tablet('up')
            else:
                assert t['x'] > 800
            tablet('out')
        missing = tomllib.loads(generate(ids[0], names[0], 'kamvas').stdout)['input']['tablet'][0]
        # Connector absent at initial resolution must not map to the desktop.
        text = generate(ids[0], names[0], 'kamvas').stdout
        key = 'output_edid' if 'output_edid' in missing else 'output'
        value = missing[key]
        input_file.write_text(text.replace(f'{key} = "{value}"', 'output = "MISSING-1"'))
        wait(lambda: next(d['status'] for d in devices() if d['id'] == ids[0]) == 'waiting_output', 'missing configured output')
        tablet('in'); tablet('down'); assert not tablet('state')['down']; tablet('up'); tablet('out')
        print('PASS generated disabled/desktop modes and missing-target suppression', flush=True)

        # Input-file updates must preserve symlinks and reject malformed content.
        link = work / 'linked.toml'; link.symlink_to(input_file)
        generate(ids[0], names[0], 'kamvas', True, link); assert link.is_symlink()
        broken = work / 'broken.toml'; broken.write_text('[input.mouse]\naccel_speed = garbage\n')
        bad = run([args.ctl, 'input', 'generate-config', '--device', ids[0], '--output', names[0], '--id', 'kamvas', '--write', broken], check=False)
        assert bad.returncode != 0 and broken.read_text().endswith('garbage\n')
        os.chmod(input_file, 0o640)
        generate(ids[0], names[0], 'kamvas', True)
        assert input_file.stat().st_mode & 0o777 == 0o640
        dangling = work / 'dangling.toml'; dangling.symlink_to(work / 'missing.toml')
        bad = run([args.ctl, 'input', 'generate-config', '--device', ids[0], '--output', names[0], '--id', 'kamvas', '--write', dangling], check=False)
        assert bad.returncode != 0 and dangling.is_symlink() and not (work / 'missing.toml').exists()
        fifo = work / 'fifo.toml'; os.mkfifo(fifo)
        bad = run([args.ctl, 'input', 'generate-config', '--device', ids[0], '--output', names[0], '--id', 'kamvas', '--write', fifo], check=False)
        assert bad.returncode != 0
        tablet('remove'); tablet('add', name=pen_name)
        wait(lambda: any(d['name'] == pen_name and d['status'] == 'resolved' for d in devices()), 'tablet reconnect uses persisted identity')
        tablet('in'); tablet('down'); tablet('button')
        assert tablet('state')['down']
        unlock_marker = work / 'unlock'
        locker = launch([work / 'locker', unlock_marker], 'lock')
        wait(lambda: any(e['event'] == 'locked' for e in events('lock')), 'session locked')
        t = tablet('state'); assert not t['down'] and t['buttons'] == 0 and t['wait_release'], t
        tablet('up'); tablet('out'); tablet('in'); tablet('axis', x=.4, y=.4); tablet('down')
        assert not tablet('state')['down']
        tablet('up'); tablet('out')
        unlock_marker.touch(); assert locker.wait(timeout=5) == 0
        tablet('in'); tablet('down'); tablet('button')
        print('PASS session lock cancels strokes and suppresses desktop pen focus', flush=True)
        first_client.terminate(); second_client.terminate()
        first_client.wait(timeout=5); second_client.wait(timeout=5)
        wait(lambda: not tablet('state')['down'] and tablet('state')['buttons'] == 0, 'client destruction cancels grab')
        tablet('up'); tablet('release'); tablet('out'); tablet('remove'); tablet('remove', device=1)
        print('PASS symlink-preserving writes, malformed file rejection and tablet reconnect/destruction', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None: os.killpg(child.pid, signal.SIGTERM)
        for child in children:
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs: log.close()


if __name__ == '__main__':
    main()
