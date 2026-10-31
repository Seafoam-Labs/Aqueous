#!/usr/bin/env python3
"""Preserve workspace numbers and return windows to reconnected outputs.

Requires -Doutput-retry-testing=true. Uses a private headless session and the
existing xdg-dialog client; logs and snapshots remain in /tmp.
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
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-output-workspaces-'))
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
    (work / 'config.toml').write_text(
        '[layout]\ndefault = "tile"\n[blur]\nenabled = false\n'
        '[workspace_transition]\nenabled = false\n'
        '[input]\nfocus_follows_mouse = false\nmouse_follows_focus = false\n')
    (work / 'rules.toml').write_text(
        '[[window]]\napp_id = "recovery-0"\nfloating = true\nwidth = 320\nheight = 200\n'
        '[[window]]\napp_id = "recovery-1"\nfloating = true\nwidth = 320\nheight = 200\n')
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='3', WLR_RENDERER=args.renderer,
               AQUEOUS_VULKAN_PRESENTATION='copy')
    bundled = args.compositor.resolve().parent.parent / 'lib/aqueous'
    env['LD_LIBRARY_PATH'] = str(bundled) + ':' + env.get('LD_LIBRARY_PATH', '')
    children, logs = [], []

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=30)

    def launch(label, command):
        log = (work / f'{label}.log').open('w')
        logs.append(log)
        process = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                   stdout=log, stderr=log, text=True)
        children.append(process)
        return process

    def wait(predicate, description):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()[-5000:]
            result = predicate()
            if result:
                return result
            time.sleep(.03)
        raise AssertionError(f'{description}; artifacts: {work}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def records(kind):
        return [r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == kind]

    def request(**data):
        with socket.socket(socket.AF_UNIX) as control:
            control.settimeout(5)
            control.connect(str(work / 'runtime/aqueous/outputd.sock'))
            control.sendall(json.dumps(data).encode() + b'\n')
            with control.makefile('r') as response:
                result = json.loads(response.readline())
        assert result.get('ok'), result
        return result

    def command(value):
        client.stdin.write(value + '\n')
        client.stdin.flush()

    def pointer_command(value):
        before = (work / 'input.log').read_text().count('done')
        inputs.stdin.write(value + '\n')
        inputs.stdin.flush()
        wait(lambda: (work / 'input.log').read_text().count('done') > before, 'pointer command')

    def window(number):
        return next((w for w in records('window') if w['app_id'] == f'recovery-{number}'), None)

    def space(output, number):
        return next(w for w in records('workspace') if w['output'] == output['id'] and w['number'] == number)

    def move(number, output, workspace):
        target = space(output, workspace)['id']
        ctl('window', 'move', '--id', window(number)['id'], '--workspace-id', target)
        wait(lambda: window(number)['workspace'] == target, 'window transfer')

    def check(output, assignments):
        spaces = {w['number']: w['id'] for w in records('workspace') if w['output'] == output['id']}
        return all(window(i)['workspace'] == spaces.get(n) for i, n in assignments.items())

    def remove(output):
        request(op='test_output_retry', name=output['name'], action='destroy')
        wait(lambda: all(o['id'] != output['id'] for o in records('output')), 'output removal')

    def add(name=None):
        before = {o['id'] for o in records('output')}
        request(op='test_output_retry', action='create', **({'name': name} if name else {}))
        return wait(lambda: next((o for o in records('output') if o['id'] not in before), None), 'hotplug')

    def primary(output):
        (work / 'outputs.toml').write_text(f'[[output]]\nname = "{output["name"]}"\nprimary = true\n')
        request(op='reload')

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-dialog': protocols / 'staging/xdg-dialog/xdg-dialog-v1.xml',
            'aqueous-input': ROOT / 'protocol/aqueous-input-management-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-dialog.c', *generated, '-lwayland-client', '-o', work / 'client'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}',
             ROOT / 'scripts/fixtures/tiled-drag-input.c', work / 'virtual-keyboard.c',
             work / 'virtual-pointer.c', '-lwayland-client', '-lxkbcommon', '-o', work / 'input'])
        compositor = launch('compositor', [args.compositor.resolve(), '-no-xwayland', '-c', 'true'])
        env['WAYLAND_DISPLAY'] = wait(
            lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None),
            'Wayland socket')
        wait(lambda: (work / 'runtime/aqueous/outputd.sock').exists(), 'output service')
        outputs = records('output')
        assert len(outputs) == 3, outputs
        first, source, destination = outputs
        primary(destination)  # Deliberately choose the last output in list order.
        client = launch('client', [work / 'client', 'recovery'])
        inputs = launch('input', [work / 'input'])
        wait(lambda: 'ready' in (work / 'input.log').read_text(), 'pointer ready')
        for i, number in enumerate((1, 3, 9, 3)):
            owner = source if i < 3 else destination
            cursor = request(op='cursor_state')
            area = owner['bounds']
            pointer_command(f'motion {round(area["x"] + area["width"] / 2 - cursor["x"])} {round(area["y"] + area["height"] / 2 - cursor["y"])}')
            ctl('workspace', 'activate', '--id', space(owner, number)['id'], '--seat', 'default')
            command(f'create {i} -1 0')
            wait(lambda: window(i), 'window creation')
            move(i, source if i < 3 else destination, number)
        ctl('workspace', 'activate', '--id', space(destination, 1)['id'], '--seat', 'default')
        ctl('window', 'state', '--id', window(2)['id'], '--fullscreen', 'true')
        wait(lambda: window(2)['fullscreen'], 'fullscreen')
        expected = {0: 1, 1: 3, 2: 9, 3: 3}
        # Removal during a floating drag must keep workspace 3, even though
        # the destination's active workspace is 1 and focus is on the source.
        ctl('workspace', 'activate', '--id', space(source, 3)['id'], '--seat', 'default')
        wait(lambda: window(1)['visible'], 'drag window visible')
        time.sleep(.2)
        box = window(1)['geometry']
        cursor = request(op='cursor_state')
        pointer_command(f'motion {round(box["x"] + 40 - cursor["x"])} {round(box["y"] + 40 - cursor["y"])}')
        pointer_command('modifiers 64')
        pointer_command('button 1')
        pointer_command('motion 20 10')
        assert window(1)['workspace'] == space(source, 3)['id'], 'fixture dragged across an output boundary'
        wait(lambda: window(1)['geometry']['x'] != box['x'], 'floating drag started')
        remove(source)
        pointer_command('button 0')
        pointer_command('modifiers 0')
        wait(lambda: check(destination, expected), 'same-number migration to primary')
        assert space(destination, 1)['active'], 'migration changed destination active workspace'
        assert window(2)['fullscreen'], 'fullscreen lost during migration'
        bounds = destination['usable_bounds']
        def recovered_float():
            w = window(0)
            g = w['geometry']
            return (w['floating'] and g['width'] == 320 and g['height'] == 200 and
                    bounds['x'] <= g['x'] and bounds['y'] <= g['y'] and
                    g['x'] + g['width'] <= bounds['x'] + bounds['width'] and
                    g['y'] + g['height'] <= bounds['y'] + bounds['height'])
        wait(recovered_float, 'floating size and destination bounds')
        assert len([w for w in records('workspace') if w['output'] == destination['id']]) == 9
        print('PASS: primary selection, workspace 1/3/9 merge, active workspace and fullscreen', flush=True)

        # Removing the primary leaves one output, which must receive every slot.
        remove(destination)
        wait(lambda: check(first, expected), 'removed primary fallback')
        assert window(2)['fullscreen']
        print('PASS: removal of configured primary falls back to remaining output', flush=True)

        # No output objects may remain alive just to retain membership.
        remove(first)
        assert not records('output')
        assert all(window(i) is not None for i in expected)
        returned = add()
        wait(lambda: check(returned, expected), 'zero-output workspace restoration')
        assert window(2)['fullscreen'], 'fullscreen lost through zero-output interval'
        print('PASS: last output removal and hotplug preserve workspace numbers', flush=True)

        # An unrelated display must not consume the original return placement.
        extra = add()
        time.sleep(.2)
        assert check(returned, expected)
        primary(extra)
        remove(returned)
        wait(lambda: check(extra, expected), 'repeated recovery')
        for number in (1, 3, 9):
            ctl('workspace', 'activate', '--id', space(extra, number)['id'], '--seat', 'default')
            wait(lambda: space(extra, number)['active'], 'workspace activation')
        # A configured primary which is powered off cannot receive recovery.
        unavailable = add()
        fallback = add()
        primary(unavailable)
        request(op='set', changes=[dict(name=unavailable['name'], enabled=False)])
        wait(lambda: not next(o for o in records('output') if o['id'] == unavailable['id'])['powered'],
             'primary disabled')
        remove(extra)
        wait(lambda: check(fallback, expected), 'disabled primary excluded')
        print('PASS: disabled primary is excluded from recovery targets', flush=True)
        # Returning the original source must reclaim its windows from the
        # fallback, even after several migrations and a zero-output interval.
        # A newly mapped fallback resident must remain on the fallback.
        command('create 4 -1 0')
        wait(lambda: window(4), 'fallback resident')
        move(4, fallback, 3)
        # An explicit move cancels automatic return for just that window.
        move(1, fallback, 5)
        restored = add(source['name'])
        wait(lambda: check(restored, {0: 1, 2: 9}), 'original source restored')
        assert check(fallback, {1: 5, 3: 3, 4: 3}), 'unrelated or manually moved windows returned'
        assert window(2)['fullscreen'], 'fullscreen lost when original output returned'
        print('PASS: original output/workspaces restored; manual moves and residents preserved', flush=True)

        # A second original output restores only its own resident, not windows
        # which used it as an intermediate fallback.
        with (work / 'outputs.toml').open('a') as config:
            config.write(f'\n[[output]]\nname = "{destination["name"]}"\nenabled = false\n')
        request(op='reload')
        restored_destination = add(destination['name'])
        wait(lambda: not next(o for o in records('output') if o['id'] == restored_destination['id'])['powered'],
             'returning original disabled')
        assert check(fallback, {3: 3}), 'restored to a disabled original'
        request(op='set', changes=[dict(name=restored_destination['name'], enabled=True)])
        wait(lambda: check(restored_destination, {3: 3}), 'second original restored')
        assert check(restored, {0: 1, 2: 9})
        assert check(fallback, {1: 5, 4: 3})

        # Repeat an off/on cycle with the same connector name. Closing a window
        # while away also exercises ownership of its saved connector string.
        remove(restored)
        command('destroy-top 0')
        wait(lambda: window(0) is None, 'close migrated window')
        restored_again = add(source['name'])
        wait(lambda: check(restored_again, {2: 9}), 'repeated original return')
        assert window(2)['fullscreen']
        assert check(restored_destination, {3: 3})
        assert check(fallback, {1: 5, 4: 3})
        print('PASS: independent origins, disabled original, repeated reconnect and closing migrated windows', flush=True)
        (work / 'final-snapshot.json').write_text(json.dumps(ctl('shell', 'snapshot'), indent=2))
        assert all(child.poll() is None for child in children)
        compositor.terminate()
        assert compositor.wait(timeout=5) == 0, (work / 'compositor.log').read_text()[-5000:]
        print('PASS: reconnect stability, repeated migration and clean shutdown', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
