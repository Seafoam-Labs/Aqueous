#!/usr/bin/env python3
"""Regression for #65: fullscreen output hints must preserve rule-owned placement.

Uses two isolated headless outputs and the real xdg-shell fullscreen fixture.
Use --renderer pixman with a -Dvulkan-effects=false build, or vulkan with GPU
access. Logs and window snapshots remain in the printed /tmp directory.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=['pixman', 'vulkan'], default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-rule-fullscreen-'))
    print(f'Artifacts: {work}', flush=True)
    runtime = work / 'runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), HOME=str(work / 'home'),
               XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless',
               WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
    for key, filename in [('AQUEOUS_CONFIG', 'wm.toml'), ('AQUEOUS_RULES', 'rules.toml'),
                          ('AQUEOUS_LAYOUT', 'layout.toml'), ('AQUEOUS_INPUT', 'input.toml'),
                          ('AQUEOUS_OUTPUTS', 'outputs.toml')]:
        env[key] = str(work / filename)
        (work / filename).write_text('')
    (work / 'wm.toml').write_text('''[layout]
default = "scrolling"
[input]
focus_follows_mouse = false
mouse_follows_focus = false
focus_new_windows = false
[workspace_transition]
enabled = false
''')
    # Different origins and logical sizes catch stale fullscreen output pointers.
    (work / 'outputs.toml').write_text('''[[output]]
name = "HEADLESS-1"
position = [0, 0]
scale = 1.0
[[output]]
name = "HEADLESS-2"
position = [1280, 0]
scale = 2.0
''')
    processes, logs = [], []
    server = None
    current = None
    serial = 0

    def run(command):
        result = subprocess.run(list(map(str, command)), env=env, capture_output=True,
                                text=True, timeout=15)
        assert result.returncode == 0, f'{command}: {result.stderr}'
        return result.stdout

    def launch(command, name):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        process = subprocess.Popen(list(map(str, command)), env=env, stdin=subprocess.PIPE,
                                   stdout=log, stderr=log, text=True)
        processes.append(process)
        return process

    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            assert server.poll() is None, 'Compositor exited; see compositor.log'
            if current:
                assert current['process'].poll() is None, f"Client exited; see {current['name']}.log"
            value = predicate()
            if value:
                return value
            time.sleep(.025)
        raise AssertionError(message)

    def ctl(*arguments):
        return json.loads(run([args.ctl, *arguments, '--json']))

    def records():
        return ctl('shell', 'snapshot')['upsert']

    def window():
        return next((w for w in ctl('windows') if w['id'] == current['id']), None)

    def events():
        return [json.loads(line) for line in (work / f"{current['name']}.log").read_text().splitlines()
                if line.startswith('{') and line.endswith('}')]

    def configures():
        return [e for e in events() if e['event'] == 'configure']

    def reload_rules(placement, matcher='steam_app_*', fullscreen=True):
        text = '' if placement is None else f'''[[window]]
app_id = "{matcher}"
layout = "scrolling"
{placement}
fullscreen = {str(fullscreen).lower()}
blur = false
opacity = 1.0
'''
        count = (work / 'compositor.log').read_text().count('configuration reloaded')
        (work / 'rules.toml').write_text(text)
        ctl('session', 'reload')
        # The reload acknowledgement precedes the next manage transaction.
        wait_for(lambda: (work / 'compositor.log').read_text().count('configuration reloaded') > count, 'No reload')

    def spawn(initial_hint=None):
        nonlocal current, serial
        serial += 1
        name = f'client-{serial}'
        process = launch([work / 'client', '--commands', f'steam_app_{serial}',
                          *([] if initial_hint is None else [initial_hint])], name)
        current = {'process': process, 'name': name, 'id': None}
        w = wait_for(lambda: next((w for w in ctl('windows') if w['app_id'] == f'steam_app_{serial}'), None), 'Window not mapped')
        current['id'] = w['id']
        wait_for(configures, 'Initial configure missing')
        return w

    def close():
        nonlocal current
        process = current['process']
        old_id = current['id']
        process.stdin.write('quit\n')
        process.stdin.flush()
        assert process.wait(timeout=5) == 0
        current = None
        wait_for(lambda: all(w['id'] != old_id for w in ctl('windows')), 'Window did not close')

    def command(value):
        count = len(configures())
        acknowledgements = sum(e['event'] == 'command' for e in events())
        current['process'].stdin.write(value + '\n')
        current['process'].stdin.flush()
        wait_for(lambda: sum(e['event'] == 'command' for e in events()) > acknowledgements, f'No acknowledgement: {value}')
        if value.startswith(('fullscreen', 'windowed')) or len(value.split()) == 3:
            wait_for(lambda: len(configures()) > count, f'No configure: {value}')

    def expect(output, workspace, fullscreen=True, visible=None, matched=True):
        def matches():
            w = window()
            if not w or (w['output'], w['workspace']) != (output, workspace):
                return False
            if ('fullscreen' in w['states']) != fullscreen or bool(w['matched_rule']) != matched:
                return False
            if visible is not None and ('visible' in w['states']) != visible:
                return False
            if fullscreen:
                bounds = next(r['bounds'] for r in records() if r['kind'] == 'output' and r['name'] == output)
                if w['geometry'] != bounds:
                    return False
                latest = configures()[-1]
                if not latest['fullscreen'] or (latest['width'], latest['height']) != (bounds['width'], bounds['height']):
                    return False
            elif configures()[-1]['fullscreen']:
                return False
            return w
        w = wait_for(matches, f'Expected {output}/{workspace}, fullscreen={fullscreen}; got {window()}')
        index = len(list(work.glob(current['name'] + '-*.json')))
        (work / f'{current["name"]}-{index}.json').write_text(json.dumps(w, indent=2))

    try:
        protocol = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip()) / 'stable/xdg-shell/xdg-shell.xml'
        run(['wayland-scanner', 'client-header', protocol, work / 'xdg-shell-client-protocol.h'])
        run(['wayland-scanner', 'private-code', protocol, work / 'xdg-shell-protocol.c'])
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-fullscreen-request.c', work / 'xdg-shell-protocol.c',
             '-o', work / 'client', *shlex.split(run(['pkg-config', '--cflags', '--libs', 'wayland-client']))])
        server = launch([args.compositor.resolve(), '-no-xwayland', '-policy', 'internal', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait_for(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'No Wayland socket')
        wait_for(lambda: len(ctl('outputs')) == 2, 'Expected two outputs')
        one, two = 'HEADLESS-1', 'HEADLESS-2'
        combined = f'output = "{two}"\nworkspace = 3'

        # Reported rule, with initial, delayed, repeated, and absent output hints.
        for initial in (None, one):
            reload_rules(combined)
            spawn(initial)
            expect(two, 3, visible=False)
            for hint in (one, one, 'none'):
                command(f'fullscreen {hint}')
                expect(two, 3, visible=False)
            command('windowed')
            expect(two, 3, fullscreen=False, visible=False)
            close()
        print('PASS: initial/repeated hints and fullscreen exit preserve rule placement', flush=True)

        # Output-only and workspace-only claims protect the resulting composite target.
        reload_rules(f'output = "{two}"')
        spawn()
        expect(two, 1)
        command(f'fullscreen {one}')
        expect(two, 1)
        close()
        reload_rules('workspace = 3')
        initial = spawn()
        owner = initial['output']
        expect(owner, 3, visible=False)
        command(f'fullscreen {one if owner == two else two}')
        expect(owner, 3, visible=False)
        close()
        print('PASS: output-only and workspace-only rules', flush=True)

        # Rule edits retarget existing fullscreen geometry without a client request.
        reload_rules(combined)
        spawn()
        expect(two, 3)
        reload_rules(f'output = "{one}"\nworkspace = 2')
        expect(one, 2, visible=False)
        command(f'fullscreen {two}')
        expect(one, 2, visible=False)
        reload_rules(None)
        wait_for(lambda: not window()['matched_rule'], 'Removed rule still matched')
        command(f'fullscreen {two}')
        expect(two, 1, matched=False)
        close()
        print('PASS: rule reload retargets geometry and removal releases placement', flush=True)

        # Identity and fullscreen requests in the same client batch must see the
        # new matcher, including when the old claim is on an inactive workspace.
        reload_rules(combined)
        spawn()
        expect(two, 3)
        command(f'identity unmatched {one}')
        expect(one, 1, matched=False)
        command(f'identity steam_app_{serial} {one}')
        expect(two, 3, visible=False)
        close()
        print('PASS: matcher transitions and fullscreen hints in the same batch', flush=True)

        # Both shell manual move paths release ownership; reload must not reclaim it.
        for move_workspace in (False, True):
            reload_rules(combined)
            spawn()
            expect(two, 3)
            command('windowed')
            if move_workspace:
                rs = records()
                owner_id = next(r['id'] for r in rs if r['kind'] == 'output' and r['name'] == two)
                workspace_id = next(r['id'] for r in rs if r['kind'] == 'workspace' and r['output'] == owner_id and r['number'] == 1)
                ctl('window', 'move', '--id', current['id'], '--workspace-id', workspace_id)
                destination, hint = two, one
            else:
                ctl('window', 'move', '--id', current['id'], '--output', one)
                destination, hint = one, two
            expect(destination, 1, fullscreen=False)
            reload_rules(combined)
            command(f'fullscreen {hint}')
            expect(hint, 1)
            # A different matcher can claim placement again after the manual override.
            reload_rules(combined, matcher=f'steam_app_{serial}')
            expect(two, 3)
            command(f'fullscreen {one}')
            expect(two, 3)
            close()
        print('PASS: manual output/workspace moves and matcher changes', flush=True)

        # An unavailable target is never owned; ordinary fullscreen routing remains.
        for placement in (None, 'output = "MISSING-OUTPUT"\nworkspace = 3'):
            reload_rules(placement)
            initial = spawn()
            hint = one if initial['output'] == two else two
            command(f'fullscreen {hint}')
            expect(hint, 1, matched=placement is not None)
            close()
        print('PASS: unruled and unavailable targets honor fullscreen hints', flush=True)
        # A powered-off destination is not claimed or retried on re-enable.
        reload_rules(combined)

        def power(enabled):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5)
                connection.connect(str(runtime / 'aqueous/outputd.sock'))
                connection.sendall(json.dumps({'op': 'set', 'changes': [
                    {'name': two, 'enabled': enabled}]}).encode() + b'\n')
                response = json.loads(connection.makefile().readline())
                assert response.get('ok'), response
            wait_for(lambda: next(r for r in records() if r['kind'] == 'output' and r['name'] == two)['powered'] == enabled,
                     'Output power did not settle')

        power(False)
        spawn(one)
        expect(one, 1)
        power(True)
        command('fullscreen none')
        expect(one, 1)
        command(f'fullscreen {two}')
        expect(two, 1)
        close()
        print('PASS: disabled targets fall back without reclaiming placement on re-enable', flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
