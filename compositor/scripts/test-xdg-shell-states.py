#!/usr/bin/env python3
"""Exercise xdg-shell version filtering and states in a private headless session."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
SUSPENDED = 1 << 9
CONSTRAINED = sum(1 << bit for bit in range(10, 14))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-xdg-shell-states-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []

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
            assert compositor.poll() is None, 'compositor exited'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(description)

    def events(label, kind=None):
        result = []
        for line in (work / f'{label}.jsonl').read_text().splitlines():
            try:
                value = json.loads(line)
                if kind is None or value['event'] == kind:
                    result.append(value)
            except ValueError:
                pass
        return result

    def state(label):
        values = events(label, 'configure')
        return values[-1] if values else None

    def command(child, label, value):
        before = len(events(label, 'command'))
        child.stdin.write(value.encode()); child.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: command {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(label):
        return next((w for w in ctl('windows') if w.get('app_id') == label), None)

    def output_request(**data):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3); client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(data).encode() + b'\n')
            with client.makefile('r') as response:
                value = json.loads(response.readline())
        assert value.get('ok'), value
        return value

    def expect_state(label, mask, enabled):
        return wait(lambda: (v := state(label)) and (v['states'] & mask == mask) == enabled and v,
                    f'{label}: mask {mask} enabled={enabled}')

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, relative in {
            'xdg-shell': 'stable/xdg-shell/xdg-shell.xml',
            'ext-foreign-toplevel-list': 'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
            'ext-image-capture-source': 'staging/ext-image-capture-source/ext-image-capture-source-v1.xml',
            'ext-image-copy-capture': 'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', protocols / relative, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', protocols / relative, code])
            generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-shell-states.c', *generated,
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
            run(['wayland-scanner', 'private-code', xml, code])
            shell_generated.append(code)
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
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\n')
        (work / 'rules.toml').write_text(''.join(
            f'[[window]]\napp_id = "xdg-states-v{v}"\nfloating = true\nwidth = 400\nheight = 300\n'
            for v in (1, 5, 6, 7)))
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        for version in (1, 5, 6, 7):
            label = f'xdg-states-v{version}'
            child = launch([work / 'client', version, label], label)
            w = wait(lambda: window(label), f'{label}: no window')
            wait(lambda: events(label, 'draw'), 'initial draw')
            assert events(label, 'global')[0]['version'] == 7
            command(child, label, 'f')
            expect_state(label, 1 << 2, True)
            if version == 7:
                expect_state(label, CONSTRAINED, True)
            command(child, label, 'F')
            expect_state(label, 1 << 2, False)
            if version == 7:
                expect_state(label, CONSTRAINED, False)
                command(child, label, 'x')
                expect_state(label, CONSTRAINED, True)
                command(child, label, 'X')
                expect_state(label, CONSTRAINED, False)
            command(child, label, 'n')
            wait(lambda: 'minimized' in window(label)['states'], 'minimize')
            if version >= 6:
                expect_state(label, SUSPENDED, True)
            ctl('window', 'activate', '--id', str(w['id']))
            expect_state(label, SUSPENDED, False)
            if version >= 6:
                command(child, label, 'a')  # acknowledge state-only changes without new buffers
                command(child, label, 'n')
                expect_state(label, SUSPENDED, True)
                ctl('window', 'activate', '--id', str(w['id']))
                expect_state(label, SUSPENDED, False)
                command(child, label, 'a')
            if version == 7:
                locker = launch([work / 'shell-client', 'lock'], 'locker')
                wait(lambda: 'locked' in (work / 'locker.jsonl').read_text().splitlines(), 'session lock')
                expect_state(label, SUSPENDED, True)
                locker.stdin.write(b'unlock\n'); locker.stdin.flush()
                assert locker.wait(timeout=5) == 0
                expect_state(label, SUSPENDED, False)
                ctl('overview', 'show', '--output', window(label)['output'])
                command(child, label, 's')
                expect_state(label, SUSPENDED, False)
                ctl('overview', 'hide')
                records = ctl('shell', 'snapshot')['upsert']
                owner = next(r['id'] for r in records if r['kind'] == 'output' and r['name'] == window(label)['output'])
                other_workspace = next(r['id'] for r in records if r['kind'] == 'workspace' and
                                       r['output'] == owner and r['name'] != str(window(label)['workspace']))
                ctl('workspace', 'activate', '--id', str(other_workspace))
                expect_state(label, SUSPENDED, True)
                command(child, label, 'c')
                command(child, label, 's')
                expect_state(label, SUSPENDED, True)  # source alone is not a consumer
                command(child, label, 'C')
                expect_state(label, SUSPENDED, False)
                command(child, label, 'e')
                expect_state(label, SUSPENDED, True)
                ctl('window', 'activate', '--id', str(w['id']))
                expect_state(label, SUSPENDED, False)
                outputs = output_request(op='list')['outputs']
                output_request(op='set', changes=[dict(name=o['name'], enabled=False) for o in outputs])
                expect_state(label, SUSPENDED, True)
                output_request(op='set', changes=[dict(name=o['name'], enabled=True) for o in outputs])
                ctl('window', 'activate', '--id', str(w['id']))
                expect_state(label, SUSPENDED, False)
                # Delay a geometry acknowledgement, then ensure newer state is
                # delivered and the transaction eventually converges.
                command(child, label, 'l')
                command(child, label, 'f')
                expect_state(label, 1 << 2, True)
                wait(lambda: 'timeout occurred' in (work / 'compositor.log').read_text(), 'deliberately late size acknowledgement')
                records = ctl('shell', 'snapshot')['upsert']
                owner = next(r['id'] for r in records if r['kind'] == 'output' and r['name'] == window(label)['output'])
                other_workspace = next(r['id'] for r in records if r['kind'] == 'workspace' and
                                       r['output'] == owner and r['name'] != str(window(label)['workspace']))
                ctl('workspace', 'activate', '--id', str(other_workspace))
                command(child, label, 's')
                expect_state(label, SUSPENDED, False)  # timed-out resize still needs a buffer
                command(child, label, 'L')
                expect_state(label, SUSPENDED, True)
                ctl('window', 'activate', '--id', str(w['id']))
                expect_state(label, SUSPENDED, False)
                command(child, label, 'F')
                expect_state(label, 1 << 2, False)
                expect_state(label, SUSPENDED, False)
            previous_draws = len(events(label, 'draw'))
            command(child, label, 'r')
            wait(lambda: len(events(label, 'draw')) > previous_draws and window(label), 'remap')
            command(child, label, 's')
            quiet_count = len(events(label, 'configure'))
            for _ in range(8):
                ctl('shell', 'snapshot')
                command(child, label, 's')
            assert len(events(label, 'configure')) == quiet_count, 'configure storm at settled state'
            for value in events(label, 'configure'):
                if version < 6:
                    assert not value['states'] & SUSPENDED, value
                if version < 7:
                    assert not value['states'] & CONSTRAINED, value
            child.stdin.write(b'q'); child.stdin.flush()
            assert child.wait(timeout=5) == 0
            print(f'PASS v{version}: version filtering, fullscreen, minimize/resume, remap', flush=True)
        label = 'xdg-layout'
        child = launch([work / 'client', 7, label], label)
        w = wait(lambda: window(label), 'layout window map')
        for layout, constrained in [('tile', True), ('scrolling', True), ('floating', False)]:
            ctl('layout', '--output', w['output'], '--set', layout)
            expect_state(label, CONSTRAINED, constrained)
            if layout != 'floating':
                expect_state(label, sum(1 << bit for bit in range(5, 9)), True)
        command(child, label, 'c')
        command(child, label, 'C')
        command(child, label, 'l')
        command(child, label, 'f')
        expect_state(label, 1 << 2, True)
        child.stdin.write(b'q'); child.stdin.flush()
        assert child.wait(timeout=5) == 0
        wait(lambda: window(label) is None, 'destroy during resize/capture')
        print('PASS workspace/power, capture, lock, overview, late ack, quiet state, and layout edges', flush=True)
        print('PASS xdg-shell states', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
