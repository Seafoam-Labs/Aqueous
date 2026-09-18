#!/usr/bin/env python3
"""Headless regression for scrolling presets and explicit rule layouts.

Use a diagnostic build with -Dvulkan-effects=false (pixman rendering).
"""

import json
import os
from pathlib import Path
import re
import select
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
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for name in ('LD_PRELOAD', 'WAYLAND_SOCKET', 'DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(name, None)
    processes, logs = [], []
    succeeded = False

    def run(*command):
        return subprocess.check_output(command, env=env, text=True, stderr=subprocess.PIPE, timeout=10)

    def launch(command, name, interactive=False, **extra):
        log = (work / f'{name}.log').open('w')
        logs.append(log)
        process = subprocess.Popen(command, env=dict(env, **extra),
                                   stdout=subprocess.PIPE if interactive else log, stderr=log,
                                   stdin=subprocess.PIPE if interactive else None, text=True)
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
            rules.write_text(f'[[window]]\napp_id = "{matcher}"\nscrolling_full_width = {str(value).lower()}\n'
                             '[[window]]\napp_id = "aq-normal"\nblur = false\nopacity = 0.8\n'
                             'workspace = 1\nsize = "320x240"\n')

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
        for name, xml in {
            'virtual-keyboard': here / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'virtual-pointer': here / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
        }.items():
            run('wayland-scanner', 'client-header', str(xml), str(work / f'{name}-client-protocol.h'))
            run('wayland-scanner', 'private-code', str(xml), str(work / f'{name}.c'))
        run('cc', '-Wall', '-Wextra', '-Werror', '-O2', '-I' + str(work),
            str(here / 'scripts/fixtures/tiled-drag-input.c'), str(work / 'virtual-keyboard.c'),
            str(work / 'virtual-pointer.c'), '-lwayland-client', '-lxkbcommon', '-o', str(work / 'input'))
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

        # Visual, placement, and size fields above must leave scrolling active.
        # Only an explicit layout turns the same match into a game anchor.
        ordinary_rules = rules.read_text()
        game_options = '[game_mode]\nfallback_layout = "monocle"\n'
        rules.write_text(game_options + ordinary_rules + 'layout = "game-mode"\n')
        key('r')
        width('aq-normal', 320)
        # Removing the layout releases the anchor but preserves the existing
        # workspace claim, so the configured game fallback now arranges it.
        rules.write_text(game_options + ordinary_rules)
        key('r')
        width('aq-normal', viewport)
        key('t')
        width('aq-width-one', full)
        width('aq-normal', normal)
        # Reloading ordinary rules must not reclaim game mode after that reset.
        write_rule()
        key('r')
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
        # Exercise custom fractions through first configure, reloads and real
        # pointer input after the existing full-width compatibility checks.
        assert output_request({'op': 'set', 'changes': [{'name': output['name'], 'transform': 'normal'}]})['ok']
        key('t')

        def fraction_rule(value=0.65, matcher='aq-custom', full_width=False):
            rules.write_text(f'[[window]]\napp_id = "{matcher}"\nscrolling_full_width = {str(full_width).lower()}\n'
                             + (f'scrolling_width = {value}\n' if value is not None else ''))
            key('r')

        def fraction_width(fraction, available=viewport):
            return max(1, int(available * fraction + 0.5) - 4)

        fraction_rule()
        launch([fixture, 'aq-custom', 'ff00ffff', '1'], 'custom', WAYLAND_DEBUG='1')
        custom = width('aq-custom', fraction_width(0.65))
        original_height = custom['geometry']['height']
        configures = re.findall(r'xdg_toplevel[@#]\d+\.configure\((\d+), (\d+),', (work / 'custom.log').read_text())
        assert next(int(w) for w, h in configures if int(w) > 0) == fraction_width(0.65), configures
        key('z', 'SUPER,SHIFT')
        width('aq-custom', full)
        key('z', 'SUPER,SHIFT')
        width('aq-custom', fraction_width(0.65))
        for value in [0.25, 1.0, 0.65]:
            fraction_rule(value)
            assert width('aq-custom', fraction_width(value))['geometry']['height'] == original_height
        fraction_rule(None)
        width('aq-custom', normal)
        fraction_rule()
        width('aq-custom', fraction_width(0.65))
        assert output_request({'op': 'set', 'changes': [{'name': output['name'], 'transform': '90'}]})['ok']
        width('aq-custom', fraction_width(0.65, portrait_viewport))
        assert output_request({'op': 'set', 'changes': [{'name': output['name'], 'transform': 'normal'}]})['ok']
        width('aq-custom', fraction_width(0.65))
        assert output_request({'op': 'set', 'changes': [{'name': output['name'], 'scale': 1.25}]})['ok']
        scaled_viewport = int(output['current_mode']['width'] / 1.25) - 40 - 16
        width('aq-custom', fraction_width(0.65, scaled_viewport))
        assert output_request({'op': 'set', 'changes': [{'name': output['name'], 'scale': output['scale']}]})['ok']
        width('aq-custom', fraction_width(0.65))

        input_process = launch([str(work / 'input')], 'input', interactive=True)

        def input_reply():
            assert select.select([input_process.stdout], [], [], 5)[0], 'input fixture timed out'
            return input_process.stdout.readline().strip()

        assert input_reply() == 'ready'

        def send(command):
            input_process.stdin.write(command + '\n')
            input_process.stdin.flush()
            assert input_reply() == 'done', command

        def point_at_custom():
            g = next(w for w in windows() if w['app_id'] == 'aq-custom')['geometry']
            send('motion -10000 -10000')
            send(f'motion {g["x"] + g["width"] // 2} {g["y"] + min(50, g["height"] // 2)}')

        def resize(dx, dy):
            point_at_custom()
            send('modifiers 64')
            send('button 1 273')
            send(f'motion {dx} {dy}')
            send('button 0 273')
            send('modifiers 0')

        def reset_size():
            point_at_custom()
            send('modifiers 64')
            for _ in range(2):
                send('button 1')
                send('button 0')
            send('modifiers 0')

        resize(0, 30)
        wait_for(lambda: next((w for w in windows() if w['app_id'] == 'aq-custom'
                              and w['geometry']['height'] != original_height), None), 'vertical resize')
        width('aq-custom', fraction_width(0.65))
        fraction_rule(0.25)
        width('aq-custom', fraction_width(0.25))
        resize(40, 0)
        resized = wait_for(lambda: next((w for w in windows() if w['app_id'] == 'aq-custom'
                                        and w['geometry']['width'] != fraction_width(0.25)), None), 'horizontal resize')
        manual_width = resized['geometry']['width']
        fraction_rule(0.65)
        width('aq-custom', manual_width)
        reset_size()
        width('aq-custom', normal)
        fraction_rule(0.75)
        width('aq-custom', normal)
        # Different matcher reclaims the rule after a manual override.
        fraction_rule(0.65, matcher='aq-custo*')
        width('aq-custom', fraction_width(0.65))
        # Clearing only a fraction must schedule an arrangement too.
        reset_size()
        width('aq-custom', normal)
        fraction_rule(0.65, matcher='aq-custom')
        width('aq-custom', fraction_width(0.65))
        # A stacked member must not reassert its fraction after column resizing.
        fraction_rule(0.65, matcher='aq-custom*')
        launch([fixture, 'aq-custom-peer', 'ffffff00', '1'], 'custom-peer')
        width('aq-custom-peer', fraction_width(0.65))
        send('key 105 65') # Super+Shift+Left
        custom = width('aq-custom', fraction_width(0.65))
        peer = width('aq-custom-peer', fraction_width(0.65))
        assert custom['geometry']['x'] == peer['geometry']['x']
        # Focus the first row so pointer input targets the visible member.
        send('key 103 64') # Super+Up
        resize(30, 0)
        resized = wait_for(lambda: next((w for w in windows() if w['app_id'] == 'aq-custom'
                                        and w['geometry']['width'] != fraction_width(0.65)), None), 'stack resize')
        manual_width = resized['geometry']['width']
        fraction_rule(0.25, matcher='aq-custom*')
        width('aq-custom', manual_width)
        width('aq-custom-peer', manual_width)
        reset_size()
        width('aq-custom', normal)
        width('aq-custom-peer', normal)
        succeeded = True
        print('Window rules: scrolling presets and fractions, first configure, reload, pointer resizing/reset, stack ownership, explicit layouts, output rotation, and nested scrolling passed.')
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
