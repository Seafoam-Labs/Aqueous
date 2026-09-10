#!/usr/bin/env python3
"""Exercise xdg-dialog lifecycle, modal focus, and fullscreen scenes privately."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-xdg-dialog-'))
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
            time.sleep(.02)
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

    def command(value, child=None, label='dialog'):
        child = client if child is None else child
        before = len(events(label, 'command'))
        child.stdin.write((value + '\n').encode()); child.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: command {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(id, label='dialog'):
        return next((w for w in ctl('windows') if w.get('app_id') == f'{label}-{id}'), None)

    def focused(id):
        return (w := window(id)) and 'focused' in w['states']

    def focus(id, expected=None):
        w = wait(lambda: window(id), f'window {id} missing')
        ctl('window', 'activate', '--id', str(w['id']), '--seat', 'default')
        wait(lambda: focused(id if expected is None else expected), f'focus {id} -> {expected}')

    def create(id, parent=-1, mode=0, child=None, label='dialog'):
        command(f'create {id} {parent} {mode}', child, label)
        wait(lambda: window(id, label), f'{label}-{id} did not map')

    def pixel(id, color):
        g = window(id)['geometry']
        path = work / f'pixel-{id}.png'
        def matches():
            run(['grim', '-o', 'HEADLESS-1', path])
            with Image.open(path) as image:
                x, y = g['x'] + g['width'] // 2, g['y'] + g['height'] // 2
                actual = image.convert('RGB').getpixel((x, y))
            return all(abs(a - b) < 8 for a, b in zip(actual, color))
        wait(matches, f'window {id} is occluded; expected pixel {color}')

    try:
        protocols = Path('/usr/share/wayland-protocols')
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-dialog': protocols / 'staging/xdg-dialog/xdg-dialog-v1.xml',
            'river-input': ROOT / 'protocol/river-input-management-v1.xml',
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
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('[layout]\ndefault = "floating"\n[blur]\nenabled = false\n[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = false\n[keybinds]\ncycle_focus = "Super+C"\n')
        (work / 'rules.toml').write_text('[[window]]\napp_id = "dialog-15"\nfocus = false\n')
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        client = launch([work / 'client', 'dialog'], 'dialog')
        wait(lambda: events('dialog', 'ready'), 'client not ready')
        assert events('dialog', 'global')[0]['version'] == 1
        command('sandbox')
        normal_display = env['WAYLAND_DISPLAY']
        env['WAYLAND_DISPLAY'] = 'dialog-sandbox'
        sandboxed = launch([work / 'client', 'sandboxed'], 'sandboxed')
        env['WAYLAND_DISPLAY'] = normal_display
        wait(lambda: events('sandboxed', 'ready'), 'sandboxed dialog global missing')
        create(0, child=sandboxed, label='sandboxed')
        create(1, 0, 2, sandboxed, 'sandboxed')
        sandboxed.stdin.write(b'quit\n'); sandboxed.stdin.flush()
        assert sandboxed.wait(timeout=5) == 0
        print('PASS security-context client registry and dialog lifecycle', flush=True)
        create(0)
        create(1, 0, 2)  # Before first commit, modal already set.
        focus(0, 1)
        geometry = window(1)['geometry']
        command('modal 1 0'); focus(0)
        command('modal 1 1'); wait(lambda: focused(1), 'immediate modal hint did not redirect focus')
        assert window(1)['geometry'] == geometry
        create(2, 1, 2); focus(0, 2)
        create(3, 0, 2); focus(0, 3)  # Highest sibling wins.
        command('destroy-dialog 3'); focus(0, 2)
        command('destroy-top 2'); wait(lambda: window(2) is None, 'nested child not destroyed')
        command('modal 2 1'); command('destroy-dialog 2')  # Inert resource.
        focus(0, 1)
        command('modal 1 0'); focus(0)
        create(4)  # Unrelated foreground application.
        focus(4)
        command('modal 1 1'); time.sleep(.15); assert focused(4), 'background hint stole focus'
        command('activate-bogus 0'); time.sleep(.1); assert focused(4), 'invalid activation took focus'
        command('parent 1 -1'); focus(0)
        command('parent 1 0'); wait(lambda: focused(1), 'parent restoration did not restore modality')
        command('destroy-dialog 1'); focus(0)
        command('dialog 1'); command('modal 1 1'); focus(0, 1)  # Late object creation.
        command('remap 1 0'); wait(lambda: window(1), 'remap lost window'); focus(0, 1)
        command('modal 1 0')
        create(15, 0, 2); focus(0)  # A rule-denied child must not block its parent.
        command('destroy-top 15'); command('destroy-dialog 15')
        command('modal 1 1')
        # Moving a modal child away does not make its old parent inaccessible.
        records = ctl('shell', 'snapshot')['upsert']
        workspace = next(r['id'] for r in records if r['kind'] == 'workspace' and
                         r['name'] != str(window(0)['workspace']))
        ctl('window', 'move', '--id', str(window(1)['id']), '--workspace-id', str(workspace))
        focus(0)
        records = ctl('shell', 'snapshot')['upsert']
        parent_workspace = next(r['id'] for r in records if r['kind'] == 'workspace' and
                                r['name'] == str(window(0)['workspace']))
        ctl('window', 'move', '--id', str(window(1)['id']), '--workspace-id', str(parent_workspace))
        focus(0, 1)
        command('minimize 1'); wait(lambda: 'minimized' in window(1)['states'], 'not minimized'); focus(0)
        focus(1); focus(0, 1)
        print('PASS lifecycle, immediate hints, parent changes, nested/sibling focus, background isolation, remap/minimize', flush=True)

        keyboard = launch([work / 'shell-client', 'input'], 'keyboard')
        wait(lambda: 'ready' in (work / 'keyboard.jsonl').read_text(), 'virtual keyboard not ready')
        focus(0, 1)
        keyboard.stdin.write(b'chord 46 64\n'); keyboard.stdin.flush()
        wait(lambda: not focused(1), 'keyboard cycle got stuck on blocked parent')
        focus(0, 1)
        def seat(name='default'):
            return next(r for r in ctl('shell', 'snapshot')['upsert'] if r['kind'] == 'seat' and r['id'] == name)
        command('create-seat')
        focus(4)
        ctl('window', 'activate', '--id', str(window(0)['id']), '--seat', 'dialog-seat')
        wait(lambda: seat('dialog-seat')['window'] == window(1)['id'], 'second seat did not resolve modal target')
        assert seat()['window'] == window(4)['id'], 'second seat changed default focus'
        command('modal 1 0')
        ctl('window', 'activate', '--id', str(window(0)['id']), '--seat', 'dialog-seat')
        command('modal 1 1')
        wait(lambda: seat('dialog-seat')['window'] == window(1)['id'], 'second seat did not follow immediate hint')
        assert seat()['window'] == window(4)['id'], 'hint changed unrelated seat focus'
        command('destroy-seat')
        command('layer')
        wait(lambda: seat()['focus_kind'] == 'layer_surface', 'exclusive layer did not take focus')
        command('modal 1 0'); command('modal 1 1')
        assert seat()['focus_kind'] == 'layer_surface', 'dialog took exclusive layer focus'
        command('destroy-layer')
        focus(0, 1)
        locker = launch([work / 'shell-client', 'lock'], 'locker')
        wait(lambda: 'locked' in (work / 'locker.jsonl').read_text(), 'lock not ready')
        command('modal 1 0'); command('modal 1 1')
        time.sleep(.1)
        assert not focused(0) and not focused(1), 'dialog took focus from lock'
        locker.stdin.write(b'unlock\n'); locker.stdin.flush(); assert locker.wait(timeout=5) == 0
        focus(0, 1)
        ctl('overview', 'show', '--output', window(0)['output'])
        command('modal 1 0'); command('modal 1 1')
        ctl('overview', 'hide'); focus(0, 1)
        command('delay 1 1')
        command('fullscreen 1 1')
        wait(lambda: 'fullscreen' in window(1)['states'], 'delayed fullscreen request not applied')
        command('modal 1 0'); focus(0)
        command('modal 1 1'); focus(0, 1)
        command('delay 1 0'); command('fullscreen 1 0')
        print('PASS keyboard cycling, two-seat/exclusive-layer/lock/overview isolation, delayed configure', flush=True)

        command('fullscreen 0 1')
        wait(lambda: 'fullscreen' in window(0)['states'], 'parent not fullscreen')
        focus(0, 1); pixel(1, (0, 255, 0))
        command('modal 1 0'); focus(0)
        g = window(1)['geometry']
        command(f'click {g["x"] + g["width"] // 2} {g["y"] + g["height"] // 2}')
        wait(lambda: focused(1), 'fullscreen dialog hit testing failed')
        command('fullscreen 4 1'); focus(4); pixel(4, (255, 0, 0))
        command('fullscreen 4 0'); command('fullscreen 0 0')
        command('modal 1 1'); focus(0, 1)
        count = len(events('dialog', 'configure'))
        for _ in range(3): command('modal 1 1')
        time.sleep(.2)
        assert len(events('dialog', 'configure')) == count, 'redundant modal request generated configures'
        command('destroy-manager'); command('modal 1 0'); focus(0)
        command('modal 1 1'); focus(0, 1)
        command('destroy-top 0'); wait(lambda: window(0) is None, 'parent not destroyed')
        command('destroy-dialog 1'); command('destroy-top 1')
        print('PASS fullscreen pixels/hit testing, group ordering, quiet repeated hints, manager lifetime', flush=True)

        bad = launch([work / 'client', 'duplicate'], 'duplicate')
        wait(lambda: events('duplicate', 'ready'), 'duplicate client not ready')
        create(0, child=bad, label='duplicate')
        command('dialog 0', bad, 'duplicate')
        bad.stdin.write(b'duplicate 0\n'); bad.stdin.flush()
        assert bad.wait(timeout=5) == 2
        error = events('duplicate', 'error')[-1]
        assert error['interface'] == 'xdg_wm_dialog_v1' and error['code'] == 0, error
        assert compositor.poll() is None
        # Disconnect with live resources, then shut down with another live client.
        client.stdin.write(b'quit\n'); client.stdin.flush(); assert client.wait(timeout=5) == 0
        live = launch([work / 'client', 'shutdown'], 'shutdown')
        wait(lambda: events('shutdown', 'ready'), 'shutdown client not ready')
        create(0, child=live, label='shutdown'); create(1, 0, 2, live, 'shutdown')
        compositor.terminate(); assert compositor.wait(timeout=5) == 0
        print('PASS duplicate-object error, disconnect, shutdown with live dialogs', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs: log.close()


if __name__ == '__main__':
    main()
