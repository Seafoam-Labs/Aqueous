#!/usr/bin/env python3
"""Real Super + pointer drags between outputs in every non-stacking layout."""
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
LAYOUTS = ('tile', 'monocle', 'grid', 'rows', 'dwindle', 'reverse-dwindle',
           'scrolling', 'game-mode', 'composable')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous')))
    parser.add_argument('--ctl', type=Path, default=Path(os.environ.get('AQUEOUSCTL_BIN', ROOT / 'zig-out/bin/aqueousctl')))
    parser.add_argument('--modifier', choices=('Super', 'Alt'), default='Super')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-tiled-drag-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    compositor = None
    modifier = 64 if args.modifier == 'Super' else 8

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=30)

    def launch(command, label, interactive=False):
        log = (work / f'{label}.log').open('w')
        logs.append(log)
        process = subprocess.Popen([str(p) for p in command], env=env, stderr=log,
                                   stdout=subprocess.PIPE if interactive else log,
                                   stdin=subprocess.PIPE if interactive else None, text=True)
        children.append(process)
        return process

    def wait(check, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()[-3000:]
            value = check()
            if value:
                return value
            time.sleep(.03)
        raise AssertionError(f'{description}; windows={ctl("windows")}')

    def ctl(*command):
        return json.loads(run([args.ctl.resolve(), *command, '--json']))

    def records(kind):
        return [r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == kind]

    def request(op, **payload):
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(str(work / 'runtime/aqueous/outputd.sock'))
            sock.sendall((json.dumps(dict(op=op, **payload)) + '\n').encode())
            with sock.makefile('r') as stream:
                reply = json.loads(stream.readline())
        assert reply.get('ok'), reply
        return reply

    def command(value):
        inputs.stdin.write(value + '\n')
        inputs.stdin.flush()
        assert select.select([inputs.stdout], [], [], 5)[0], value
        assert inputs.stdout.readline().strip() == 'done', value

    def move(x, y, release=False):
        current = request('cursor_state')
        command(f'{"drop" if release else "motion"} {round(x-current["x"])} {round(y-current["y"])}')
        def arrived():
            cursor = request('cursor_state')
            return abs(cursor['x'] - x) <= 1 and abs(cursor['y'] - y) <= 1
        wait(arrived, f'pointer did not reach {(x, y)}')

    def window(name):
        return next((w for w in ctl('windows') if w['app_id'] == name), None)

    def center(box):
        return box['x'] + box['width'] // 2, box['y'] + box['height'] // 2

    def begin(name):
        w = window(name)
        ctl('window', 'activate', '--id', w['id'], '--seat', 'default')
        time.sleep(.08)
        move(*center(window(name)['geometry']))
        command(f'modifiers {modifier}')
        command('button 1')

    def end():
        command('button 0')
        command('modifiers 0')

    def owned(name, output, workspace=None):
        w = window(name)
        return w and w['output'] == output['name'] and (workspace is None or w['workspace'] == workspace)

    def assert_tiled(name, output):
        wait(lambda: owned(name, output), f'{name} did not transfer to {output["name"]}')
        def settled():
            w = window(name)
            g, area = w['geometry'], output['bounds']
            assert 'floating' not in w['states'], w
            return w if ('focused' in w['states'] and g['width'] > 0 and g['height'] > 0
                         and area['x'] <= g['x'] < area['x'] + area['width']
                         and area['y'] <= g['y'] < area['y'] + area['height']) else None
        w = wait(settled, f'{name} destination layout did not settle')
        assert records('seat')[0]['output'] == output['id']
        return w

    def layout(output, name):
        ctl('layout', '--output', output['name'], '--set', name)
        time.sleep(.06)

    def create(name, output):
        process = launch([work / 'window', name, 'ff336699', '1'], name)
        w = wait(lambda: window(name), f'{name} not mapped')
        ctl('window', 'move', '--id', w['id'], '--output', output['name'])
        wait(lambda: owned(name, output), f'{name} initial output')
        return process

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = {}
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            generated[name] = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, generated[name]])
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/tiled-drag-input.c', generated['virtual-keyboard'],
             generated['virtual-pointer'], '-lwayland-client', '-lxkbcommon', '-o', work / 'input'])
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/scrolling-vertical-reference.c', generated['xdg-shell'],
             '-lwayland-client', '-o', work / 'window'])
        for name in ('runtime', 'config', 'home', 'cache', 'state', 'data'):
            (work / name).mkdir(mode=0o700)
        config = work / 'wm.toml'
        config.write_text((ROOT / 'scripts/fixtures/new-window-focus-on-wm.toml').read_text() + '''
[layout.composable.a]
layout = "tile"
p1 = [0.0, 0.0]
p2 = [0.5, 0.0]
p3 = [0.5, 1.0]
p4 = [0.0, 1.0]
[layout.composable.b]
layout = "scrolling"
p1 = [0.5, 0.0]
p2 = [1.0, 0.0]
p3 = [1.0, 1.0]
p4 = [0.5, 1.0]
[keybinds.custom]
"Super+F6" = "builtin:move_to_composable:a"
"Super+F7" = "builtin:move_to_composable:b"
''')
        env.update(XDG_RUNTIME_DIR=str(work / 'runtime'), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'), XDG_DATA_HOME=str(work / 'data'),
                   HOME=str(work / 'home'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                   WLR_RENDERER='pixman', AQUEOUS_CONFIG=str(config), AQUEOUS_MOD=args.modifier)
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'Wayland socket')
        wait(lambda: (work / 'runtime/aqueous/outputd.sock').is_socket(), 'output service')
        outputs = sorted(wait(lambda: records('output') if len(records('output')) == 2 else None, 'two outputs'), key=lambda o: o['name'])
        request('set', changes=[dict(name=outputs[0]['name'], position=[-1280, 0], scale=1, transform='normal'),
                                dict(name=outputs[1]['name'], position=[0, 0], scale=1, transform='normal')])
        left, right = sorted(records('output'), key=lambda o: o['bounds']['x'])
        inputs = launch([work / 'input'], 'input', True)
        assert select.select([inputs.stdout], [], [], 5)[0]
        assert inputs.stdout.readline().strip() == 'ready'
        a = create('drag-a', left)

        # Every non-stacking layout must admit an empty-output transfer, in
        # both directions, without requiring a hit-tested destination window.
        for name in LAYOUTS:
            layout(left, name)
            layout(right, name)
            begin('drag-a')
            move(*center(right['bounds']))
            assert_tiled('drag-a', right)
            move(*center(left['bounds']))
            assert_tiled('drag-a', left)
            end()
            print(f'PASS: {name} empty-output round trip', flush=True)

        b = create('drag-b', right)
        c = create('drag-c', right)
        # Mixed layouts and occupied targets, including continued reordering
        # after admission. Monocle has no second visible target to hit.
        for index, name in enumerate(LAYOUTS):
            layout(left, LAYOUTS[(index + 1) % len(LAYOUTS)])
            layout(right, name)
            begin('drag-a')
            move(*center(window('drag-b')['geometry']))
            assert_tiled('drag-a', right)
            if name in ('tile', 'grid', 'rows', 'dwindle', 'reverse-dwindle'):
                before = window('drag-a')['geometry']
                move(*center(window('drag-c')['geometry']))
                wait(lambda: window('drag-a')['geometry'] != before, f'{name}: drag did not continue')
            move(*center(left['bounds']))
            assert_tiled('drag-a', left)
            end()
            assert owned('drag-b', right) and owned('drag-c', right)
            print(f'PASS: occupied {name} and mixed-layout transfer', flush=True)

        layout(left, 'tile')
        layout(right, 'tile')
        begin('drag-a')
        # Send crossing and release in one protocol frame.
        move(*center(right['bounds']), release=True)
        command('modifiers 0')
        assert_tiled('drag-a', right)
        begin('drag-a')
        move(*center(right['bounds']))
        command(f'crossings {-right["bounds"]["width"]} 5')
        end()
        assert_tiled('drag-a', left)
        print('PASS: release at crossing and repeated crossings', flush=True)

        # Cross into a different active workspace, leaving residents on the
        # destination's original workspace untouched.
        second = next(w for w in records('workspace') if w['output'] == right['id'] and w['number'] == 2)
        ctl('workspace', 'activate', '--id', second['id'])
        layout(right, 'scrolling')
        begin('drag-a')
        move(*center(right['bounds']))
        assert_tiled('drag-a', right)
        assert window('drag-a')['workspace'] == 2
        assert window('drag-b')['workspace'] == window('drag-c')['workspace'] == 1
        move(*center(left['bounds']))
        assert_tiled('drag-a', left)
        end()
        first = next(w for w in records('workspace') if w['output'] == right['id'] and w['number'] == 1)
        ctl('workspace', 'activate', '--id', first['id'])
        print('PASS: destination active workspace and inactive residents', flush=True)

        # Admit in one composable region, then drop into the other region.
        # Repeat with a stacking child to check completion after the region swap.
        for stacking_child in (False, True):
            if stacking_child:
                config.write_text(config.read_text().replace('layout = "scrolling"', 'layout = "stacking"'))
                command(f'key 19 {modifier}')  # reload_config
                time.sleep(.1)
            layout(right, 'composable')
            ctl('window', 'activate', '--id', window('drag-c')['id'], '--seat', 'default')
            command(f'key 65 {modifier}')  # region B
            boundary = right['bounds']['x'] + right['bounds']['width'] // 2
            wait(lambda: window('drag-c')['geometry']['x'] >= boundary, 'region B placement')
            ctl('window', 'activate', '--id', window('drag-b')['id'], '--seat', 'default')
            command(f'key 64 {modifier}')  # region A is the admission region
            begin('drag-a')
            move(*center(window('drag-c')['geometry']))
            assert_tiled('drag-a', right)
            wait(lambda: window('drag-a')['geometry']['x'] >= boundary, 'cross-region drop')
            move(*center(left['bounds']))
            if stacking_child:
                assert owned('drag-a', right)
                end()
                ctl('window', 'move', '--id', window('drag-a')['id'], '--output', left['name'])
            else:
                assert_tiled('drag-a', left)
                end()
        print('PASS: composable non-stacking and stacking child transfers', flush=True)

        # Changing the source to stacking or hiding its workspace ends the
        # current tiled operation; later pointer motion must not move it.
        begin('drag-a')
        layout(left, 'stacking')
        move(*center(right['bounds']))
        assert owned('drag-a', left)
        end()
        layout(left, 'tile')
        source_workspace = window('drag-a')['workspace']
        other = next(w for w in records('workspace') if w['output'] == left['id'] and w['number'] != source_workspace)
        begin('drag-a')
        ctl('workspace', 'activate', '--id', other['id'])
        move(*center(right['bounds']))
        assert owned('drag-a', left, source_workspace)
        end()
        original = next(w for w in records('workspace') if w['output'] == left['id'] and w['number'] == source_workspace)
        ctl('workspace', 'activate', '--id', original['id'])
        print('PASS: layout and workspace changes cancel tiled gesture', flush=True)

        # Fullscreen policy windows do not enter the tiled drag path.
        ctl('window', 'state', '--id', window('drag-a')['id'], '--fullscreen', 'true')
        wait(lambda: 'fullscreen' in window('drag-a')['states'], 'fullscreen request')
        begin('drag-a')
        move(*center(right['bounds']))
        end()
        assert owned('drag-a', left)
        ctl('window', 'state', '--id', window('drag-a')['id'], '--fullscreen', 'false')
        wait(lambda: 'fullscreen' not in window('drag-a')['states'], 'fullscreen restore')
        print('PASS: fullscreen drag rejected', flush=True)

        # A stacking destination keeps policy ownership but ends tiled motion.
        layout(right, 'stacking')
        begin('drag-a')
        move(*center(right['bounds']))
        assert_tiled('drag-a', right)
        move(*center(left['bounds']))
        assert owned('drag-a', right)
        end()
        print('PASS: stacking destination completes tiled gesture', flush=True)

        # A rotated, scaled output separated by a gap uses logical bounds.
        layout(right, 'tile')
        request('set', changes=[dict(name=left['name'], position=[-1280, -200]),
                                dict(name=right['name'], position=[100, 80], scale=1.5, transform='90')])
        left, right = sorted(records('output'), key=lambda o: o['bounds']['x'])
        begin('drag-a')
        move(*center(left['bounds']))
        assert_tiled('drag-a', left)
        move(*center(right['bounds']))
        assert_tiled('drag-a', right)
        end()
        print('PASS: negative origins, gap, scale and rotation', flush=True)

        begin('drag-a')
        move(*center(left['bounds']))
        assert_tiled('drag-a', left)
        end()
        begin('drag-a')
        target_x, target_y = center(window('drag-c')['geometry'])
        cursor = request('cursor_state')
        command(f'motion {round(target_x-cursor["x"])} {round(target_y-cursor["y"])}')
        c.terminate()
        c.wait(timeout=5)
        wait(lambda: window('drag-c') is None, 'drop target closed')
        assert_tiled('drag-a', right)
        move(*center(left['bounds']))
        assert_tiled('drag-a', left)
        end()
        print('PASS: target closure during transfer', flush=True)

        # Closing an owned window and disabling its output cannot retain a
        # stale drag. Normal disabled-output workspace ownership is preserved.
        begin('drag-a')
        a.terminate()
        a.wait(timeout=5)
        wait(lambda: window('drag-a') is None, 'closed drag window')
        end()
        begin('drag-b')
        request('set', changes=[dict(name=right['name'], enabled=False)])
        time.sleep(.1)
        end()
        request('set', changes=[dict(name=right['name'], enabled=True)])
        wait(lambda: owned('drag-b', right), 're-enabled output ownership')
        time.sleep(.1)
        begin('drag-b')
        move(*center(left['bounds']))
        assert_tiled('drag-b', left)
        end()
        assert compositor.poll() is None
        print(f'PASS: lifecycle recovery ({args.modifier})', flush=True)
    finally:
        for process in reversed(children):
            if process.poll() is None:
                process.terminate()
        for process in reversed(children):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
