#!/usr/bin/env python3
"""Dwindle overflow transactions with real clients in an isolated compositor."""
import argparse
import json
import os
from pathlib import Path
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-dwindle-overflow-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    compositor = None

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=15)

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
            assert compositor.poll() is None, f'compositor exited: {work}'
            result = predicate()
            if result:
                return result
            time.sleep(.03)
        raise AssertionError(f'{description}; artifacts: {work}')

    def events():
        return [json.loads(line) for line in (work / 'client.jsonl').read_text().splitlines()]

    def command(value):
        before = sum(e['event'] == 'command' for e in events())
        client.stdin.write((value + '\n').encode())
        client.stdin.flush()
        wait(lambda: sum(e['event'] == 'command' for e in events()) > before, value)

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def records(kind):
        return [r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == kind]

    def windows():
        return {int(w['app_id'].rsplit('-', 1)[1]): w for w in records('window')
                if w['app_id'].startswith('overflow-')}

    def activate(number):
        ctl('workspace', 'activate', '--id', spaces[number], '--seat', 'default')
        wait(lambda: any(w['id'] == spaces[number] and w['active'] for w in records('workspace')), 'activate workspace')

    def layout(name):
        ctl('layout', '--output', output['name'], '--set', name)

    def create(number, parent=-1):
        command(f'create {number} {parent} {1 if parent >= 0 else 0}')
        wait(lambda: number in windows(), f'map {number}')

    def clear():
        for number in list(windows()):
            command(f'destroy-top {number}')
        wait(lambda: not windows(), 'close windows')
        for number in range(1, 10):
            activate(number)
            layout('dwindle')
        activate(1)

    def check_readable(expected):
        observed = windows()
        assert len(observed) == expected, (len(observed), expected)
        owners = {number: w['workspace'] for number, w in observed.items()}
        for number in range(1, 10):
            activate(number)
            wait(lambda: all(w['geometry']['width'] >= 320 and w['geometry']['height'] >= 200
                             for i, w in windows().items() if w['workspace'] == spaces[number] and i != 100),
                 'readable content dimensions')
        assert owners == {number: w['workspace'] for number, w in windows().items()}, 'transfers repeated on visit'
        return owners

    try:
        generated = []
        protocols = Path('/usr/share/wayland-protocols')
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
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-dialog.c', *generated, '-lwayland-client', '-o', work / 'client'])
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        for name in ('config', 'cache', 'state'):
            (work / name).mkdir()
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text(
            '[layout]\ndefault = "dwindle"\n[blur]\nenabled = false\n'
            '[workspace_transition]\nenabled = false\n[input]\n'
            'focus_follows_mouse = false\nmouse_follows_focus = false\n')
        (work / 'rules.toml').write_text('[[window]]\napp_id = "overflow-18"\nworkspace = 1\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'Wayland socket')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'IPC socket')
        client = launch([work / 'client', 'overflow'], 'client')
        wait(lambda: any(e['event'] == 'ready' for e in events()), 'client ready')
        output = records('output')[0]
        spaces = {w['number']: w['id'] for w in records('workspace') if w['output'] == output['id']}
        for origin, count, target in [('floating', 19, 'dwindle'), ('scrolling', 26, 'reverse-dwindle')]:
            clear()
            layout(origin)
            for number in range(count):
                create(number)
            create(100, 18)
            ctl('window', 'activate', '--id', windows()[count - 1]['id'], '--seat', 'default')
            layout(target)
            wait(lambda: len({w['workspace'] for w in windows().values()}) > 1, 'overflow transfer')
            assert next(w for w in records('workspace') if w['active'])['id'] == spaces[1]
            wait(lambda: windows()[100]['workspace'] == windows()[18]['workspace'], 'dialog follows parent')
            wait(lambda: any(w['focused'] and w['workspace'] == spaces[1] for w in windows().values()),
                 'focus remains on source workspace after focused window overflows')
            owners = check_readable(count + 1)
            time.sleep(.25)
            assert owners == {number: w['workspace'] for number, w in windows().items()}, 'rule returned overflow'
            print(f'PASS {origin} -> {target}: {count} windows, dialog transfer, stable ownership and navigation', flush=True)

        for source in (1, 9):
            clear()
            # At the headless output's 1280x720 logical size three dwindle
            # windows fit. Fill every workspace, then overload the source.
            for number in range(1, 10):
                activate(number)
                for index in range(3):
                    create(number * 4 + index)
            activate(source)
            layout('floating')
            for number in range(50, 76):
                create(number)
            layout('dwindle')
            wait(lambda: sum(w['workspace'] == spaces[9] for w in windows().values()) > 3, 'overflow reaches workspace nine')
            assert next(w for w in records('workspace') if w['active'])['id'] == spaces[source]
            owners = {number: w['workspace'] for number, w in windows().items()}
            assert len(owners) == 53
            activate(9)
            assert ctl('layout', '--output', output['name'])['layout'] == 'scrolling'
            for number in range(36, 39):
                assert windows()[number]['workspace'] == spaces[9], 'resident displaced'
            # The shell omits layout_index for off-viewport windows. Reveal
            # each resident before checking its index and reachability.
            for index, number in enumerate(range(36, 39)):
                ctl('window', 'activate', '--id', windows()[number]['id'], '--seat', 'default')
                wait(lambda: windows()[number]['focused'] and windows()[number]['visible'] and
                     windows()[number]['layout_index'] == index, 'scrolling resident order and reachability')
            time.sleep(.25)
            assert owners == {number: w['workspace'] for number, w in windows().items()}
            create(110)
            wait(lambda: windows()[110]['workspace'] == spaces[9], 'new arrival in scrolling sink')
            # A rule on an incoming window must not undo either the fallback
            # or a later explicit selection on that workspace.
            (work / 'rules.toml').write_text(
                '[[window]]\napp_id = "overflow-18"\nworkspace = 1\n'
                '[[window]]\napp_id = "overflow-110"\nlayout = "dwindle"\n')
            ctl('session', 'reload')
            time.sleep(.15)
            assert ctl('layout', '--output', output['name'])['layout'] == 'scrolling'
            layout('floating')
            wait(lambda: ctl('layout', '--output', output['name'])['layout'] == 'float',
                 'explicit layout selection replaces scrolling fallback')
            wait(lambda: all(w['can_minimize'] for w in windows().values() if w['workspace'] == spaces[9]),
                 'explicit floating layout takes effect despite the window rule')
            time.sleep(.15)
            assert ctl('layout', '--output', output['name'])['layout'] == 'float'
            print(f'PASS all workspaces full, source {source}: workspace 9 scrolling, residents retained, new window maps', flush=True)
        # Each IPC call has a timeout: completing all scenarios also asserts
        # that navigation and control remain responsive throughout.
    finally:
        if compositor is not None and compositor.poll() is None:
            try:
                (work / 'final-snapshot.json').write_text(json.dumps(ctl('shell', 'snapshot'), indent=2))
            except (subprocess.SubprocessError, AssertionError):
                pass
        for child in reversed(children):
            if child.poll() is None:
                child.terminate()
        for child in reversed(children):
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
