#!/usr/bin/env python3
"""Check focus-before-click and primary-selection transfers in private sessions."""
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
    work = Path(tempfile.mkdtemp(prefix='aqueous-primary-selection-'))
    print(f'Artifacts: {work}', flush=True)
    generated = []
    protocols = Path('/usr/share/wayland-protocols')
    for name, xml in {
        'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
        'xdg-dialog': protocols / 'staging/xdg-dialog/xdg-dialog-v1.xml',
        'primary-selection': protocols / 'unstable/primary-selection/primary-selection-unstable-v1.xml',
        'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
        'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
    }.items():
        subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
        code = work / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True)
        generated.append(code)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
                    ROOT / 'scripts/fixtures/primary-selection.c', *generated,
                    '-lwayland-client', '-lxkbcommon', '-o', work / 'client'], check=True)

    for mode in ('click', 'scroll'):
        case = work / mode
        case.mkdir()
        for name in ('runtime', 'home', 'config', 'cache', 'state'):
            (case / name).mkdir(mode=0o700)
        env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        env.update(HOME=str(case / 'home'), XDG_RUNTIME_DIR=str(case / 'runtime'),
                   XDG_CONFIG_HOME=str(case / 'config'), XDG_CACHE_HOME=str(case / 'cache'),
                   XDG_STATE_HOME=str(case / 'state'), WLR_BACKENDS='headless',
                   WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER=args.renderer)
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = case / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        layout = 'scrolling' if mode == 'scroll' else 'floating'
        follows = 'true' if mode == 'scroll' else 'false'
        (case / 'config.toml').write_text(f'[layout]\ndefault = "{layout}"\n[blur]\nenabled = false\n'
                                         f'[workspace_transition]\nenabled = false\n[input]\nfocus_follows_mouse = {follows}\n')
        (case / 'layout.toml').write_text('[layout.options.scrolling]\ncolumn_fraction = 0.4\n'
                                         'center_focused = false\nfocus_follows_mouse_delay_ms = 150\n')
        if mode == 'click':
            (case / 'rules.toml').write_text('''[[window]]
app_id = "source-*"
floating = true
x = 100
y = 150
width = 320
height = 240
[[window]]
app_id = "target-0"
floating = true
x = 550
y = 150
width = 400
height = 300
[[window]]
app_id = "target-1"
floating = true
x = 800
y = 350
width = 300
height = 200
''')
        children, logs, clients = [], [], {}
        compositor = None

        def launch(command, label):
            out, err = (case / f'{label}.jsonl').open('w'), (case / f'{label}.log').open('w')
            logs.extend((out, err))
            child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                     stdout=out, stderr=err, start_new_session=True)
            children.append(child)
            return child

        def wait(predicate, description):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                assert compositor.poll() is None, (case / 'compositor.log').read_text()[-3000:]
                value = predicate()
                if value:
                    return value
                time.sleep(.01)
            raise AssertionError(description)

        def events(label, kind=None):
            result = []
            for line in (case / f'{label}.jsonl').read_text().splitlines():
                try:
                    value = json.loads(line)
                    if kind is None or value['event'] == kind:
                        result.append(value)
                except ValueError:
                    pass
            return result

        def command(value, label='source'):
            before = len(events(label, 'command'))
            clients[label].stdin.write((value + '\n').encode())
            clients[label].stdin.flush()
            wait(lambda: len(events(label, 'command')) > before, f'{label}: {value}')

        def ctl(*values):
            return json.loads(subprocess.check_output([str(args.ctl.resolve()), *values, '--json'],
                                                      env=env, text=True, timeout=10))

        def window(label, id=0):
            return next((w for w in ctl('windows') if w.get('app_id') == f'{label}-{id}'), None)

        def focus(label, id=0):
            ctl('window', 'activate', '--id', str(window(label, id)['id']), '--seat', 'default')
            wait(lambda: 'focused' in window(label, id)['states'], 'keyboard focus')

        def point(label, id=0):
            g = window(label, id)['geometry']
            return g['x'] + 30, g['y'] + 30

        def click(x, y, destination='target', expected='first-selection', ordering=False):
            before = len(events(destination))
            command(f'click-at {x} {y}')
            wait(lambda: len([e for e in events(destination)[before:] if e['event'] == 'button']) == 2,
                 'press/release pair missing')
            command('read-paste', destination)
            result = events(destination, 'paste')[-1]
            assert result['text'] == expected and result['bytes'] == len(expected), result
            received = events(destination)[before:]
            buttons = [e for e in received if e['event'] == 'button']
            assert [e['state'] for e in buttons] == [1, 0], buttons
            if ordering:
                kinds = [e['event'] for e in received]
                assert kinds.index('keyboard') < kinds.index('selection') < kinds.index('button'), received

        def select(text):
            focus('source')
            x, y = point('source')
            command(f'move {x} {y}')
            before = len(events('source', 'button'))
            command('button 272 1')
            command('button 272 0')
            wait(lambda: len(events('source', 'button')) == before + 2, 'selection input serial')
            command(f'primary {text}')
            wait(lambda: events('source', 'selection')[-1]['available'], 'source selection')

        def left_click_target():
            before = len(events('target', 'button'))
            x, y = point('target')
            command(f'move {x} {y}')
            command('button 272 1'); command('button 272 0')
            wait(lambda: len(events('target', 'button')) == before + 2, 'target click delivery')

        try:
            compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
            env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (case / 'runtime').glob('wayland-*')
                                                      if p.is_socket()), None), 'no display')
            wait(lambda: (case / 'runtime/aqueous/outputd.sock').exists(), 'no output service')
            for label in ('source', 'target', 'panel'):
                clients[label] = launch([work / 'client', label], label)
                wait(lambda: events(label, 'ready'), 'client not ready')
            for label in ('target', 'source'):
                command('create 0', label)
                wait(lambda: window(label), 'window not mapped')
            select('first-selection')
            click(*point('target'), ordering=True)
            click(*point('target'))  # Already-focused destination.
            select('replacement-selection')
            click(*point('target'), expected='replacement-selection', ordering=True)
            print(f'PASS {mode}: first click, focused click, replaced selection, focus/selection/button ordering', flush=True)

            if mode == 'click':
                command('layer 0 2', 'panel')  # On-demand keyboard focus.
                # The layer is anchored at the top-left and receives focus on click.
                wait(lambda: events('panel', 'layer-ready'), 'panel not mapped')
                select('panel-selection')
                click(30, 30, 'panel', 'panel-selection', ordering=True)
                command('destroy 0', 'panel')
                command('layer 0 1', 'panel')  # Exclusive keyboard focus.
                def panel_focused():
                    return any(r.get('kind') == 'seat' and r.get('focus_kind') == 'layer_surface'
                               for r in ctl('shell', 'snapshot')['upsert'])
                wait(panel_focused, 'exclusive panel focus')
                left_click_target()
                assert panel_focused(), 'click stole exclusive panel focus'
                command('destroy 0', 'panel')
                command('create 1', 'target')
                wait(lambda: window('target', 1) and 'focused' in window('target', 1)['states'], 'modal focus')
                left_click_target()
                assert 'focused' in window('target', 1)['states'], 'parent click bypassed modal focus'
                print('PASS on-demand panel paste, exclusive panel and modal focus restrictions', flush=True)
                command('destroy 1', 'target')
                wait(lambda: not window('target', 1), 'modal did not close')
                for destroy in (False, True):
                    select('lifecycle-selection')
                    x, y = point('target')
                    enters = len(events('target', 'enter'))
                    command(f'move {x} {y}')
                    wait(lambda: len(events('target', 'enter')) > enters, 'target pointer focus')
                    before = len(events('target', 'button'))
                    cancellations = (case / 'compositor.log').read_text().count('cancelling pending pointer button')
                    command(f'vanish 0 {int(destroy)}', 'target')
                    wait(lambda: not window('target'), 'target did not disappear')
                    assert (case / 'compositor.log').read_text().count('cancelling pending pointer button') > cancellations
                    assert len(events('target', 'button')) == before, 'cancelled press or unmatched release delivered'
                    if not destroy:
                        command('destroy 0', 'target')
                    command('create 0', 'target')
                    wait(lambda: window('target'), 'target did not return')
                    select('after-cancellation')
                    click(*point('target'), expected='after-cancellation', ordering=True)
                print('PASS pending press cancellation on unmap/destroy and subsequent click recovery', flush=True)
        finally:
            for child in reversed(children):
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        child.kill(); child.wait()
            for log in logs:
                log.close()


if __name__ == '__main__':
    main()
