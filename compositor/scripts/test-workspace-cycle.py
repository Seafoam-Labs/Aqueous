#!/usr/bin/env python3
"""Exercise default animated workspace cycling with real windows and keyboard events.

Requires cc, wayland-scanner, Wayland/xkbcommon development files and a compositor
built for the selected renderer. Artifacts remain in /tmp; the desktop is untouched.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-workspace-cycle-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    compositor = None
    ipc = None

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=30)

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            assert compositor.poll() is None, f'compositor exited; see {work}'
            value = predicate()
            if value:
                return value
            time.sleep(.02)
        raise AssertionError(description)

    def events(kind):
        return [e for line in (work / 'client.jsonl').read_text().splitlines()
                if (e := json.loads(line))['event'] == kind]

    def command(value):
        before = len(events('command'))
        client.stdin.write((value + '\n').encode()); client.stdin.flush()
        wait(lambda: len(events('command')) > before, f'client command {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def records(kind):
        return [r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == kind]

    def window(number):
        return next((w for w in records('window') if w['app_id'] == f'cycle-{number}'), None)

    def focused():
        return next((w['id'] for w in records('window') if w['focused']), None)

    def session():
        return records('session')[0]

    def focus(number):
        wid = window(number)['id']
        ctl('window', 'activate', '--id', wid, '--seat', 'default')
        wait(lambda: focused() == wid, f'focus {number}')

    def create(number, parent=-1, modal=0):
        command(f'create {number} {parent} {modal}')
        return wait(lambda: window(number), f'window {number} did not map')['id']

    def key(code, modifiers=0, count=1):
        keyboard.stdin.write(f'chord {code} {modifiers} {count}\n'.encode())
        keyboard.stdin.flush()

    def step(modifiers, count=1):
        serial = session()['switcher_serial']
        key(15, modifiers, count)
        wait(lambda: session()['switcher_serial'] == serial + count, 'every Tab press must advance once')
        wait(lambda: not session()['switcher_pending'], 'focus commit')
        return focused()

    def dismiss():
        key(1)
        wait(lambda: session()['switcher_window'] is None, 'Escape dismissal')

    def move(number, workspace):
        ctl('window', 'move', '--id', window(number)['id'], '--workspace-id', workspace)
        wait(lambda: window(number)['workspace'] == workspace, 'window transfer')

    def visit(expected, modifiers=64):
        observed = [step(modifiers) for _ in expected]
        assert observed == expected, (observed, expected)
        return observed

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-dialog': protocols / 'staging/xdg-dialog/xdg-dialog-v1.xml',
            'aqueous-input': ROOT / 'protocol/aqueous-input-management-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
            'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code]); generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-dialog.c', *generated,
             '-lwayland-client', '-o', work / 'client'])
        shell_generated = [generated[0]]
        for name, xml in {
            'xdg-activation': protocols / 'staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': protocols / 'unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': protocols / 'staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
            'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
            'pointer-constraints': protocols / 'unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code]); shell_generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/shell-client.c',
             *shell_generated, '-lwayland-client', '-lxkbcommon', '-o', work / 'shell-client'])
        runtime = work / 'runtime'; runtime.mkdir(mode=0o700)
        for name in ('home', 'config', 'cache', 'state'):
            (work / name).mkdir()
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        preamble = '[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = true\nmouse_follows_focus = false\n'
        (work / 'config.toml').write_text(preamble)
        (work / 'rules.toml').write_text('[[window]]\napp_id = "cycle-9"\nskip_switcher = true\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        client = launch([work / 'client', 'cycle'], 'client')
        wait(lambda: events('ready'), 'client ready')
        keyboard = launch([work / 'shell-client', 'input'], 'keyboard')
        wait(lambda: 'ready' in (work / 'keyboard.jsonl').read_text(), 'keyboard ready')
        outputs = sorted(records('output'), key=lambda o: o['name'])
        spaces = records('workspace')
        first = next(w['id'] for w in spaces if w['output'] == outputs[0]['id'] and w['active'])
        other = next(w['id'] for w in spaces if w['output'] == outputs[0]['id'] and w['id'] != first)
        remote = next(w['id'] for w in spaces if w['output'] == outputs[1]['id'] and w['active'])
        ctl('workspace', 'activate', '--id', first, '--seat', 'default')
        key(15, 64); time.sleep(.1)
        assert session()['switcher_window'] is None
        ids = [create(i) for i in range(4)]
        for i in range(4):
            move(i, first)
        create(4); move(4, other)
        create(5); move(5, remote)
        focus(0)
        geometry = {w['id']: w['geometry'] for w in records('window')}
        # The empty-workspace press seeded the ring before these sequential maps.
        order = ids.copy()
        start = order.index(ids[0])
        expected = order[start+1:] + order[:start+1]
        visit(expected)
        assert session()['switcher_scope'] == 'workspace'
        assert session()['switcher_total'] == 4
        assert session()['switcher_workspace'] == first
        assert session()['switcher_output'] == outputs[0]['id']
        visit(expected, 8)  # Alt+Tab uses the exact same workspace ring.
        reverse = [order[(start-i) % 4] for i in range(1, 5)]
        visit(reverse, 65)
        visit(reverse, 9)
        print('PASS default Super/Alt forward/reverse visit all four windows; workspace/output isolation', flush=True)

        # Capture actual compositor transforms while an existing deck retargets.
        step(64)
        frames = []
        for delay in (0, .08, .24):
            time.sleep(delay)
            scene = run([args.ctl.resolve(), 'scene'])
            frames.append(re.findall(r'overview thumbnail buffer \[buffer\] (.*)', scene))
        (work / 'animation.json').write_text(json.dumps(frames, indent=2))
        assert frames[0] and frames[0] != frames[-1], frames
        assert scene.count('overview card:') == 3, 'four ring members must remain reachable with three cards'
        selected = focused()
        dismiss()
        assert focused() == selected
        assert 'overview card:' not in run([args.ctl.resolve(), 'scene'])
        assert {w['id']: w['geometry'] for w in records('window')} == geometry
        wait(lambda: session()['switcher_window'] is None, 'scene restored')
        current = order.index(focused())
        assert step(64, 9) == order[(current+9) % 4]
        selected = focused()
        wait(lambda: session()['switcher_window'] is None, 'idle dismissal')
        assert focused() == selected
        assert step(8) == order[(order.index(selected)+1) % 4]
        # Each paused press outlives the deck; order still persists.
        for _ in range(4):
            selected = focused()
            wait(lambda: session()['switcher_window'] is None, 'idle between presses')
            assert step(64) == order[(order.index(selected)+1) % 4]
        focus(2)
        assert step(64) == order[(order.index(ids[2])+1) % 4]
        print('PASS animation, rapid presses, idle dismissal, external focus and geometry restoration', flush=True)

        # Workspace transfer removes an entry; returning appends after survivors.
        dismiss()
        move(1, other)
        focus(0)
        survivors = [wid for wid in order if wid != ids[1]]
        at = survivors.index(ids[0])
        visit(survivors[at+1:] + survivors[:at+1])
        dismiss(); move(1, first); focus(0)
        order = survivors + [ids[1]]
        at = order.index(ids[0]); visit(order[at+1:] + order[:at+1])
        dismiss()
        ctl('window', 'state', '--id', ids[2], '--minimized', 'true')
        wait(lambda: window(2)['minimized'], 'minimized')
        focus(0)
        survivors = [wid for wid in order if wid != ids[2]]
        at = survivors.index(ids[0]); visit(survivors[at+1:] + survivors[:at+1])
        dismiss()
        ctl('window', 'state', '--id', ids[2], '--minimized', 'false')
        wait(lambda: not window(2)['minimized'], 'restored')
        focus(0); order = survivors + [ids[2]]
        at = order.index(ids[0]); visit(order[at+1:] + order[:at+1])
        dismiss()
        appended = create(6); move(6, first); focus(0)
        order.append(appended)
        at = order.index(ids[0]); visit(order[at+1:] + order[:at+1])
        focus(0); assert step(65) == appended
        command('destroy-top 6')
        wait(lambda: window(6) is None, 'closed window')
        focus(0); order.remove(appended)
        at = order.index(ids[0]); visit(order[at+1:] + order[:at+1])
        print('PASS create, close, minimize, restore, move-away and append-on-return', flush=True)

        dismiss()
        skipped = create(9); move(9, first)
        dialog = create(7, 0, 2)
        wait(lambda: window(7)['workspace'] == first, 'dialog scope')
        focus(7)
        eligible = set(ids[1:] + [dialog])
        visited = [step(64) for _ in range(4)]
        assert set(visited) == eligible and skipped not in visited and ids[0] not in visited, visited
        dismiss(); command('destroy-top 7'); command('destroy-top 9')
        wait(lambda: window(7) is None and window(9) is None, 'dialog cleanup')
        focus(0)
        ctl('window', 'state', '--id', ids[0], '--fullscreen', 'true')
        wait(lambda: window(0)['fullscreen'], 'fullscreen')
        assert set(step(64) for _ in range(4)) == set(ids)
        dismiss()
        ctl('window', 'state', '--id', ids[0], '--fullscreen', 'false')
        print('PASS modal parents and skip-switcher excluded; fullscreen included', flush=True)

        # Switching away and back preserves each ring; a sole member is a no-op.
        ctl('workspace', 'activate', '--id', other, '--seat', 'default')
        wait(lambda: focused() == window(4)['id'], 'other workspace focus')
        key(15, 8); time.sleep(.15)
        assert focused() == window(4)['id'] and session()['switcher_window'] is None
        focus(0)
        assert set(step(64) for _ in range(4)) == set(ids)
        dismiss()

        # Explicit bindings (including the user's migrated configuration) replace defaults.
        migrated = '[keybinds]\ncycle_focus = ["Super+Tab", "Alt+Tab"]\ncycle_focus_reverse = ["Super+Shift+Tab", "Alt+Shift+Tab"]\n'
        (work / 'config.toml').write_text(preamble + migrated)
        ctl('session', 'reload')
        focus(0)
        assert set(step(8) for _ in range(4)) == set(ids)
        assert set(step(65) for _ in range(4)) == set(ids)
        dismiss()
        # Existing opt-in global shortcuts still cross workspace/output boundaries.
        (work / 'config.toml').write_text(preamble + migrated + 'window_switcher_next = "Super+G"\n')
        ctl('session', 'reload')
        serial = session()['switcher_serial']; key(34, 64)
        wait(lambda: session()['switcher_serial'] == serial+1, 'global action')
        assert session()['switcher_scope'] == 'all' and session()['switcher_total'] == 6
        dismiss()
        print('PASS per-workspace persistence, single-window no-op, explicit config and global action', flush=True)

        # The workspace IPC and native bindings share the same ring, including
        # reduced-motion presentation requested by a shell such as Pearl.
        focus(0)
        ipc = socket.socket(socket.AF_UNIX)
        ipc.settimeout(5)
        ipc.connect(str(next(runtime.glob('aqueous/*/ipc.sock'))))
        reply = ipc.makefile('r')
        request_id, ipc_session = 0, None

        def request(op, **params):
            nonlocal request_id, ipc_session
            request_id += 1
            value = dict(ipc=1, id=str(request_id), op=op, params=params)
            if ipc_session:
                value['session'] = ipc_session
            ipc.sendall(json.dumps(value).encode() + b'\n')
            result = json.loads(reply.readline())
            assert result['ok'], result
            return result['result']

        ipc_session = request('hello')['session']
        reduced = []
        for _ in range(4):
            serial = session()['switcher_serial']
            request('command', action='switcher.next', fields=dict(
                output=outputs[0]['id'], workspace=first, seat='default', reduced_motion=True))
            wait(lambda: session()['switcher_serial'] == serial+1 and not session()['switcher_pending'],
                 'reduced motion selection')
            reduced.append(focused())
        assert set(reduced) == set(ids) and reduced[-1] == ids[0], reduced
        before = re.findall(r'overview thumbnail buffer \[buffer\] (.*)', run([args.ctl.resolve(), 'scene']))
        time.sleep(.3)
        after = re.findall(r'overview thumbnail buffer \[buffer\] (.*)', run([args.ctl.resolve(), 'scene']))
        assert before and before == after, 'reduced motion must settle immediately'
        dismiss(); reply.close(); ipc.close(); ipc = None
        print('PASS reduced-motion workspace commands share the keyboard ring without animation', flush=True)
        (work / 'result.json').write_text(json.dumps({'status': 'passed', 'renderer': args.renderer}))
    finally:
        if ipc is not None:
            ipc.close()
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
