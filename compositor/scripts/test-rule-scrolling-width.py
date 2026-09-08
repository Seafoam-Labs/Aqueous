#!/usr/bin/env python3
"""Headless regression for the rule-owned Super+Shift+Z scrolling preset.

Use a diagnostic build with -Dvulkan-effects=false (pixman rendering).
"""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    here = Path(__file__).resolve().parents[1]
    compositor = os.environ.get('AQUEOUS_COMPOSITOR_BIN', str(here / 'zig-out/bin/aqueous'))
    ctl = os.environ.get('AQUEOUSCTL_BIN', str(here / 'zig-out/bin/aqueousctl'))
    work = Path(tempfile.mkdtemp(prefix='aqueous-rule-scrolling-width-'))
    env = dict(os.environ)
    env.pop('LD_PRELOAD', None)
    processes, logs = [], []
    succeeded = False

    def run(*command):
        return subprocess.check_output(command, env=env, text=True, stderr=subprocess.PIPE, timeout=10)

    def launch(command, name, **extra):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        process = subprocess.Popen(command, env=dict(env, **extra), stdout=log, stderr=log)
        processes.append(process)
        return process

    def wait_for(predicate, message):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.05)
        raise AssertionError(message)

    def windows():
        return json.loads(run(ctl, 'windows', '--json'))

    def width(identity, expected):
        return wait_for(lambda: next((w for w in windows()
            if w['app_id'] == identity and w['geometry']['width'] == expected), None),
            f'{identity} did not reach width {expected}: {windows()}')

    def key(symbol, modifiers='SUPER'):
        run('wlrctl', 'keyboard', 'type', symbol, 'modifiers', modifiers)

    def output_request(request):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(5)
            client.connect(str(work / 'runtime/aqueous/outputd.sock'))
            client.sendall(json.dumps(request).encode() + b'\n')
            return json.loads(client.makefile().readline())

    try:
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        (work / 'config').mkdir()
        (work / 'home').mkdir()
        config = work / 'wm.toml'
        rules = work / 'rules.toml'
        config.write_text('''[layout]
default = "scrolling"
gaps_outer = 8
gaps_inner = 8
border_width = 2
[layout.slots]
primary = "scrolling"
secondary = "monocle"
tertiary = "game-mode"
[layout.options.scrolling]
column_fraction = 0.5
prefer_vertical_on_portrait = true
[struts]
top = 0
bottom = 0
left = 16
right = 24
[input]
focus_follows_mouse = false
focus_new_windows = true
[workspace_transition]
enabled = false
[keybinds]
set_layout_primary = "Super+T"
set_layout_secondary = "Super+M"
set_layout_tertiary = "Super+G"
toggle_scrolling_full_width = "Super+Shift+Z"
reload_rules = "Super+R"
''')

        def write_rule(value=True, matcher='aq-width-*'):
            rules.write_text(f'[[window]]\napp_id = "{matcher}"\nscrolling_full_width = {str(value).lower()}\n')

        write_rule()
        protocol_dir = run('pkg-config', '--variable=pkgdatadir', 'wayland-protocols').strip()
        protocol = str(Path(protocol_dir) / 'stable/xdg-shell/xdg-shell.xml')
        run('wayland-scanner', 'client-header', protocol, str(work / 'xdg-shell-client-protocol.h'))
        run('wayland-scanner', 'private-code', protocol, str(work / 'xdg-shell-protocol.c'))
        fixture = str(work / 'reference')
        run('cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-I' + str(work),
            str(here / 'scripts/fixtures/scrolling-vertical-reference.c'),
            str(work / 'xdg-shell-protocol.c'), '-o', fixture,
            *shlex.split(run('pkg-config', '--cflags', '--libs', 'wayland-client')))
        env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(work / 'config'),
                   HOME=str(work / 'home'), AQUEOUS_CONFIG=str(config), AQUEOUS_RULES=str(rules),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
        server = launch([compositor, '-no-xwayland', '-log-level', 'info', '-c', 'true'], 'compositor')

        def display_socket():
            assert server.poll() is None, (work / 'compositor.log').read_text()
            return next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None)

        env['WAYLAND_DISPLAY'] = wait_for(display_socket, 'No Wayland socket')
        wait_for(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'No output control socket')
        output = output_request({'op': 'list'})['outputs'][0]
        viewport = int(output['current_mode']['width'] / output['scale']) - 40 - 16
        full, normal = viewport - 4, int(viewport * 0.5 + 0.5) - 4
        run('wlrctl', 'pointer', 'move', '100', '100')
        launch([fixture, 'aq-width-one', 'ffff0000', '1'], 'one', WAYLAND_DEBUG='1')
        width('aq-width-one', full)
        wait_for(lambda: any(w['app_id'] == 'aq-width-one' and 'focused' in w['states']
                            for w in windows()), 'First window did not receive focus')
        # Ignore the initial unspecified-size handshake; the first concrete
        # configure must already carry the full-width layout geometry.
        configures = re.findall(r'xdg_toplevel[@#]\d+\.configure\((\d+), (\d+),',
                                (work / 'one.log').read_text())
        assert next(int(w) for w, h in configures if int(w) > 0) == full, configures

        key('z', 'SUPER,SHIFT')
        width('aq-width-one', normal)
        write_rule(False)
        key('r')
        write_rule(True)
        key('r')
        width('aq-width-one', normal)
        # A different matcher starts a fresh ownership lifecycle.
        write_rule(matcher='aq-width-one')
        key('r')
        width('aq-width-one', full)
        rules.write_text('')
        key('r')
        width('aq-width-one', normal)
        write_rule()
        key('r')
        width('aq-width-one', full)

        launch([fixture, 'aq-normal', 'ff0000ff', '1'], 'normal')
        width('aq-normal', normal)
        # Switching away and back must preserve the preset without imposing it
        # on other layout engines or changing the workspace's chosen layout.
        key('m')
        width('aq-normal', viewport)
        key('t')
        width('aq-width-one', full)
        width('aq-normal', normal)

        response = output_request({'op': 'set', 'changes': [
            {'name': output['name'], 'transform': '90'}]})
        assert response.get('ok'), response
        portrait_viewport = int(output['current_mode']['height'] / output['scale']) - 40 - 16
        portrait_full = portrait_viewport - 4
        width('aq-width-one', portrait_full)
        # New matching windows stack in portrait mode and expand the column
        # of the currently focused ordinary member too.
        launch([fixture, 'aq-width-two', 'ff00ff00', '1'], 'two')
        width('aq-width-two', portrait_full)
        width('aq-normal', portrait_full)
        two = next(w for w in windows() if w['app_id'] == 'aq-width-two')
        ordinary = next(w for w in windows() if w['app_id'] == 'aq-normal')
        assert two['geometry']['x'] == ordinary['geometry']['x']
        assert two['geometry']['y'] != ordinary['geometry']['y']
        # The same per-window preset reaches scrolling instances nested in
        # game mode, without turning a width-only match into a game anchor.
        rules.write_text('[game_mode]\nfallback_layout = "scrolling"\n' + rules.read_text())
        key('r')
        key('g')
        width('aq-width-one', portrait_full)
        width('aq-width-two', portrait_full)
        width('aq-normal', portrait_full)
        succeeded = True
        print('Scrolling width rule: initial configure, toggle, reload, removal, layouts, output rotation, stacking, and nested scrolling passed.')
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
        for process in processes:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for log in logs:
            log.close()
        if succeeded and os.environ.get('AQUEOUS_KEEP_TEST_OUTPUT') != '1':
            shutil.rmtree(work)
        else:
            print(f'Test artifacts: {work}')


if __name__ == '__main__':
    main()
