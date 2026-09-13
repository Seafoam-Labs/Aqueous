#!/usr/bin/env python3
"""Exercise toplevel tags, rules, inspection and metadata lifetime with real clients."""
import argparse
import json
import os
from pathlib import Path
import signal
import select
import subprocess
import tempfile
import time
from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-tag-'))
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

    def window(number):
        return next((w for w in ipc.snapshot()['upsert'] if w['kind'] == 'window' and w['title'] == f'tag-window-{number}'), None)

    def cli(*args):
        return subprocess.check_output([str(compositor_path.with_name('aqueousctl')), *args], env=env, text=True)

    compositor_path = args.compositor.resolve()
    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-toplevel-tag': protocols / 'staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml',
            'aqueous-window-info': ROOT / 'protocol/aqueous-window-info-v1.xml',
            'ext-foreign-toplevel-list': protocols / 'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
        }.items():
            subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
            code = work / f'{name}.c'
            subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True); generated.append(code)
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}', ROOT / 'scripts/fixtures/xdg-toplevel-tag.c',
                        *generated, '-lwayland-client', '-o', work / 'client'], check=True)
        runtime = work / 'run'; runtime.mkdir(mode=0o700)
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "tile"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n')
        (work / 'rules.toml').write_text('[[window]]\napp_id = "aqueous-tag-test"\ntag = "settings"\nfloating = true\n[[window]]\ntag = "other"\nskip_taskbar = true\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None))
        socket = wait(lambda: next(runtime.glob('aqueous/*/ipc.sock'), None))
        ipc = Client(socket); clients.append(ipc)
        client = fixture('client')
        command('sandbox')
        normal_display = env['WAYLAND_DISPLAY']
        env['WAYLAND_DISPLAY'] = 'tag-sandbox'
        sandboxed = fixture('sandboxed')
        env['WAYLAND_DISPLAY'] = normal_display
        command('window 4 1', sandboxed, 'sandboxed'); command('commit 4', sandboxed, 'sandboxed')
        wait(lambda: window(4))
        assert window(4)['tag'] == 'settings'
        sandboxed.stdin.write(b'quit\n'); sandboxed.stdin.flush(); assert sandboxed.wait(timeout=5) == 0
        wait(lambda: window(4) is None)

        command('window 0 1'); command('commit 0')
        w = wait(lambda: window(0))
        assert w['tag'] == 'settings' and w['description'] == 'Paramètres' and w['floating'], w
        identifier = w['id']
        command('window 1 1'); command('commit 1')
        assert wait(lambda: window(1))['tag'] == 'settings'
        assert window(1)['id'] != identifier
        rows = json.loads(cli('windows', '--json'))
        row = next(r for r in rows if r['title'] == 'tag-window-0')
        assert row['tag'] == 'settings' and row['description'] == 'Paramètres'
        assert 'tag = "settings"' in cli('inspect', '--rule')
        for version in (1, 4, 6, 7, 8): command(f'inspect {version}')
        print('PASS versioned inspection; early metadata, duplicate tags, sandbox visibility, rules and CLI', flush=True)

        subscriber = Client(socket); clients.append(subscriber)
        subscriber.call('subscribe'); initial = subscriber.receive(); subscriber.ack(initial)
        command('tag 0 settings')
        command('description 0 Paramètres')
        assert not select.select([subscriber.socket], [], [], .15)[0], 'identical metadata republished'
        command('description 0 Réglages mis à jour')
        delta = subscriber.receive(); subscriber.ack(delta)
        assert any(e.get('id') == identifier and e.get('description') == 'Réglages mis à jour' for e in delta['batch']['upsert'])
        assert window(0)['tag'] == 'settings'
        command('tag 0 other')
        delta = subscriber.receive(); subscriber.ack(delta)
        assert any(e.get('id') == identifier and e.get('tag') == 'other' for e in delta['batch']['upsert'])
        subscriber.close(); clients.remove(subscriber)
        wait(lambda: window(0)['skip_taskbar'])
        assert window(0)['tag'] == 'other' and window(0)['id'] == identifier
        assert window(1)['tag'] == 'settings'
        command('tag 0 '); command('description 0 ')
        wait(lambda: window(0)['tag'] == '' and window(0)['description'] == '')
        assert not window(0)['skip_taskbar']
        command('tag 0 literal*?\\purpose"#')
        rule_text = cli('inspect', '--rule')
        # Generated TOML must match the literal tag, including glob metacharacters.
        import tomllib
        literal_rule = next(r for r in tomllib.loads(rule_text)['window'] if 'tag' in r and r['tag'] != 'settings')
        assert literal_rule['tag'] == 'literal\\*\\?\\\\purpose"#', literal_rule
        (work / 'rules.toml').write_text(rule_text.replace('\n# title', '\nskip_taskbar = true\n# title'))
        wait(lambda: window(0)['skip_taskbar'])
        command('tag 0 literalXXpurpose"#')
        wait(lambda: not window(0)['skip_taskbar'])
        print('PASS immediate updates, independent descriptions, empty values and literal rule round trip', flush=True)

        original_workspace = window(0)['workspace']
        placement_rules = '[[window]]\ntag = "placed"\nworkspace = 2\n[[window]]\ntag = "placed-again"\nworkspace = 2\n'
        (work / 'rules.toml').write_text(placement_rules)
        command('tag 0 placed')
        wait(lambda: window(0)['workspace'] != original_workspace)
        claimed_workspace = window(0)['workspace']
        ipc.command('window.move', dict(id=identifier, workspace=original_workspace))
        wait(lambda: window(0)['workspace'] == original_workspace)
        command('description 0 manually moved')
        command('tag 0 placed')
        (work / 'rules.toml').write_text(placement_rules.replace('workspace = 2', 'workspace = 2\nskip_taskbar = true'))
        wait(lambda: window(0)['skip_taskbar'])
        assert window(0)['workspace'] == original_workspace, 'reload discarded manual placement'
        command('tag 0 placed-again')
        wait(lambda: window(0)['workspace'] == claimed_workspace)
        print('PASS tag placement claims, manual overrides, reload and matcher transitions', flush=True)

        command('tag 0 retained'); command('destroy-manager')
        assert window(0)['tag'] == 'retained'
        command('bind-manager'); command('tag 0 rebound')
        wait(lambda: window(0)['tag'] == 'rebound')
        command('tag 0 rebound')
        assert window(0)['tag'] == 'rebound'
        command('unmap 0'); wait(lambda: window(0) is None)
        command('remap 0'); wait(lambda: window(0))
        assert window(0)['tag'] is None and window(0)['description'] is None
        command('unmap 0'); wait(lambda: window(0) is None)
        command('tag 0 next-map'); command('remap 0')
        assert wait(lambda: window(0))['tag'] == 'next-map'
        command('window 2 1'); command('destroy-window 2')
        client.kill(); client.wait(timeout=5)
        wait(lambda: not any(w['kind'] == 'window' for w in ipc.snapshot()['upsert']))
        ipc.command('session.exit')
        assert compositor.wait(timeout=5) == 0, (work / 'compositor.log').read_text()[-8000:]
        print(f'PASS manager lifetime, remap, destruction, abrupt disconnect ({args.renderer})', flush=True)
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
