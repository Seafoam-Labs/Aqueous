#!/usr/bin/env python3
"""Verify isolated scene pixels, destination color and lock/unmap denial in a private session."""
import argparse
import json
import os
from pathlib import Path
import signal
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-scene-capture-'))
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

    def command(child, label, value):
        before = len(events(label, 'command'))
        child.stdin.write(value.encode()); child.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: command {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(label):
        return next((w for w in ctl('windows') if w.get('app_id') == label), None)

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, relative in {
            'xdg-shell': 'stable/xdg-shell/xdg-shell.xml',
            'ext-foreign-toplevel-list': 'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
            'ext-image-capture-source': 'staging/ext-image-capture-source/ext-image-capture-source-v1.xml',
            'ext-image-copy-capture': 'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml',
            'aqueous-capture-color-v1': str(ROOT / 'protocol/aqueous-capture-color-v1.xml'),
            'security-context': 'staging/security-context/security-context-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', protocols / relative, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', protocols / relative, code])
            generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/scene-capture.c', *generated,
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
            f'[[window]]\napp_id = "{label}"\nfloating = true\nwidth = 400\nheight = 300\nx = 200\ny = 150\n'
            for label in ('scene-target', 'scene-cover')))
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        target=launch([work / 'client', 'scene-target'], 'target')
        wait(lambda: window('scene-target'), 'target map')
        command(target, 'target', 's')
        command(target, 'target', 'b')
        command(target, 'target', 'o')
        command(target, 'target', 'c')
        cover=launch([work / 'client', 'scene-cover'], 'cover')
        wait(lambda: window('scene-cover'), 'cover map')
        ctl('window', 'activate', '--id', window('scene-cover')['id'])
        wait(lambda: 'focused' in window('scene-cover')['states'], 'cover raised')
        a,b=window('scene-target'),window('scene-cover')
        (work / 'overlap.json').write_text(json.dumps([a,b],indent=2))
        assert a['geometry']==b['geometry'], (a,b)
        for _ in range(2):
            command(target, 'target', 'c')
        command(target, 'target', 'p')
        locker=launch([work / 'shell-client', 'lock'], 'locker')
        wait(lambda: 'locked' in (work / 'locker.jsonl').read_text().splitlines(), 'session lock')
        command(target, 'target', 'f')
        command(target, 'target', 'o')
        wait(lambda: events('target','stopped'), 'new source denied under lock')
        locker.stdin.write(b'unlock\n'); locker.stdin.flush(); assert locker.wait(timeout=5)==0
        command(target, 'target', 'o')
        command(target, 'target', 'c')
        command(target, 'target', 'p')
        command(target, 'target', 'u')
        wait(lambda: window('scene-target') is None, 'target unmap')
        command(target, 'target', 'f')
        print('PASS isolated foreign-toplevel pixels, repeated SDR metadata, lock denial, unmap and untouched failed buffers', flush=True)
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
