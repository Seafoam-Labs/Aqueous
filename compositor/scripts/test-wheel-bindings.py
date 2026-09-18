#!/usr/bin/env python3
"""Wheel binding dispatch and client passthrough in an isolated headless session.

Requires a -Dvulkan-effects=false compositor, cc, wayland-scanner, and the
Wayland/xkbcommon development packages. All artifacts remain in /tmp.
"""
import os
import json
from pathlib import Path
import subprocess
import select
import socket
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
CTL = Path(os.environ.get('AQUEOUSCTL_BIN', BIN.parent / 'aqueousctl'))
base = Path(tempfile.mkdtemp(prefix='aqueous-wheel-bindings-'))
print(f'Artifacts: {base}', flush=True)


def wait_for(check, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition timed out')


protocols = {
    'xdg-shell': '/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml',
    'xdg-activation': '/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml',
    'shortcuts': '/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
    'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
    'virtual-pointer': ROOT / 'protocol/upstream/wlr-virtual-pointer-unstable-v1.xml',
    'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
    'session-lock': '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',
    'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
    'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
    'pointer-constraints': '/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
}
for name, xml in protocols.items():
    subprocess.run(['wayland-scanner', 'client-header', str(xml), str(base / f'{name}-client-protocol.h')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', str(xml), str(base / f'{name}.c')], check=True)
for name, deps in [('shell-client', [p for p in protocols if p != 'virtual-pointer']),
                   ('wheel-input', ['virtual-keyboard', 'virtual-pointer'])]:
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I' + str(base),
                    str(ROOT / f'scripts/fixtures/{name}.c'),
                    *[str(base / f'{p}.c') for p in deps],
                    '-lwayland-client', '-lxkbcommon', '-lm', '-o', str(base / name)], check=True)

runtime = base / 'runtime'
runtime.mkdir(mode=0o700)
(base / 'config').mkdir()
(base / 'home').mkdir()
wm = base / 'wm.toml'
preamble = '[layout]\ndefault = "tile"\n[input]\nfocus_follows_mouse = false\nfocus_new_windows = true\nmouse_follows_focus = false\n'
marker = base / 'actions'


def configure(extra=''):
    wm.write_text(preamble + '''
[keybinds]
wheel_scroll_left = []
wheel_scroll_right = []
wheel_scroll_up = []
wheel_scroll_down = []
[keybinds.custom]
''' + '\n'.join(f'"Ctrl+Wheel{direction}" = "spawn:echo {direction} >> {marker}"'
                 for direction in ('Up', 'Down', 'Left', 'Right')) + '\n' + extra)


configure(f'"Ctrl+Alt+WheelUp" = "spawn:echo Single >> {marker}"\n')
env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
env.update(XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(base / 'config'),
           HOME=str(base / 'home'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
           WLR_RENDERER='pixman', AQUEOUS_CONFIG=str(wm))
for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
    env.pop(key, None)
children = []
log = (base / 'compositor.log').open('w+')
compositor = subprocess.Popen([str(BIN), '-no-xwayland', '-log-level', 'debug', '-c', 'true'],
                              env=env, stdout=log, stderr=log)
children.append(compositor)
try:
    def ready():
        assert compositor.poll() is None, 'compositor exited; see compositor.log'
        return next((p for p in runtime.glob('wayland-*') if p.is_socket()), None)
    env['WAYLAND_DISPLAY'] = wait_for(ready).name
    client_log = base / 'client.log'
    client = subprocess.Popen([str(base / 'shell-client'), 'window'], env=env,
                              stdin=subprocess.PIPE, stdout=client_log.open('w'), stderr=log, text=True)
    children.append(client)
    wait_for(lambda: 'ready' in client_log.read_text())
    injector = subprocess.Popen([str(base / 'wheel-input')], env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=log, text=True)
    children.append(injector)
    def response():
        assert select.select([injector.stdout], [], [], 5)[0], 'input fixture timed out'
        return injector.stdout.readline().strip()

    assert response() == 'ready'

    def send(command):
        injector.stdin.write(command + '\n')
        injector.stdin.flush()
        assert response() == 'done'

    def client_command(command):
        client.stdin.write(command + '\n')
        client.stdin.flush()

    def actions():
        return marker.read_text().splitlines() if marker.exists() else []

    def axis_count():
        return sum(line.startswith('pointer axis ') and not line.startswith('pointer axis stop ')
                   for line in client_log.read_text().splitlines())

    def reload():
        previous = (base / 'compositor.log').read_text().count('configuration reloaded layout=')
        # Use the fixture's keyboard chord to force a synchronous reload request.
        client_command('chord 19 64')  # Super+R
        wait_for(lambda: (base / 'compositor.log').read_text().count('configuration reloaded layout=') > previous)

    send('move')
    wait_for(lambda: 'pointer enter' in client_log.read_text())
    send('mods 4')
    before_axes = axis_count()
    for axis, delta, name in [(0, -15, 'Up'), (0, 15, 'Down'), (1, -15, 'Left'), (1, 15, 'Right')]:
        before = len(actions())
        send(f'scroll {axis} 0 {delta} {1 if delta > 0 else -1}')
        wait_for(lambda: len(actions()) == before + 1)
        assert actions()[-1] == name
    assert axis_count() == before_axes, 'bound wheel leaked to client'

    # One event containing two physical notches dispatches twice.
    before = len(actions())
    send('scroll 0 0 30 2')
    wait_for(lambda: len(actions()) == before + 2)
    assert actions()[-2:] == ['Down', 'Down']

    # Finger scroll accumulates; a stop discards partial movement.
    before = len(actions())
    send('scroll 0 1 30 0')
    send('scroll 0 1 20 0')
    wait_for(lambda: len(actions()) == before + 1)
    send('scroll 0 1 30 0')
    send('scroll 0 1 0 0')
    send('scroll 0 1 20 0')
    time.sleep(.08)
    assert len(actions()) == before + 1
    assert axis_count() == before_axes

    # Relevant extra modifiers prevent matching; lock modifiers are ignored.
    send('mods 5')
    send('scroll 0 0 15 1')
    wait_for(lambda: axis_count() > before_axes)
    assert len(actions()) == before + 1
    send('mods 6')  # Ctrl plus Caps Lock modifier bit
    send('scroll 0 0 15 1')
    wait_for(lambda: len(actions()) == before + 2)

    # Shortcut inhibition passes matched chords to the focused application.
    client_command('inhibit')
    wait_for(lambda: 'inhibit active' in client_log.read_text())
    before_axes = axis_count()
    send('mods 4')
    send('scroll 1 0 15 1')
    wait_for(lambda: axis_count() > before_axes)
    assert len(actions()) == before + 2
    client_command('uninhibit')
    time.sleep(.08)

    # A one-direction binding must not swallow the application's stop for an
    # unbound scroll in the opposite direction.
    send('mods 12')
    before_stops = client_log.read_text().count('pointer axis stop ')
    send('scroll 0 1 50 0')
    send('scroll 0 1 0 0')
    wait_for(lambda: client_log.read_text().count('pointer axis stop ') > before_stops)
    before_stops = client_log.read_text().count('pointer axis stop ')
    send('scroll 0 1 -50 0')
    wait_for(lambda: actions()[-1:] == ['Single'])
    send('scroll 0 1 0 0')
    time.sleep(.08)
    assert client_log.read_text().count('pointer axis stop ') == before_stops

    # Reload changes the action on the existing default chord, even in tile.
    configure(f'"Super+WheelUp" = "spawn:echo Rebound >> {marker}"\n')
    reload()
    send('mods 64')
    send('scroll 0 0 -15 -1')
    wait_for(lambda: actions()[-1:] == ['Rebound'])
    configure()
    reload()
    send('mods 64')
    before_axes = axis_count()
    before = len(actions())
    send('scroll 0 0 -15 -1')
    wait_for(lambda: axis_count() > before_axes)
    assert len(actions()) == before, 'removed wheel binding still active'
    # Exercise the formerly hard-coded navigation itself on real scrolling
    # windows, then move its chord and finally disable it.
    scrolling = preamble.replace('default = "tile"', 'default = "scrolling"') + '\n[layout.options.scrolling]\ncolumn_fraction = 0.5\ncenter_focused = true\n'
    wm.write_text(scrolling)
    reload()
    for index in range(2):
        companion_log = base / f'companion-{index}.log'
        companion = subprocess.Popen([str(base / 'shell-client'), 'window'], env=env,
                                     stdin=subprocess.PIPE, stdout=companion_log.open('w'), stderr=log, text=True)
        children.append(companion)
        wait_for(lambda: 'configured' in companion_log.read_text())

    def windows():
        return json.loads(subprocess.check_output([str(CTL), 'windows', '--json'], env=env, timeout=5))

    def positions():
        return sorted((w['id'], w['geometry']['x'], w['geometry']['y']) for w in windows())

    wait_for(lambda: len(windows()) == 3)
    before_positions = positions()
    send('mods 0')
    send('mods 64')
    send('scroll 0 0 -15 -1')
    first_positions = wait_for(lambda: (current if (current := positions()) != before_positions else None))
    send('scroll 0 0 15 1')
    wait_for(lambda: positions() == before_positions)

    wm.write_text(scrolling + '\n[keybinds]\nwheel_scroll_left = "Ctrl+WheelLeft"\n')
    reload()
    send('mods 64')
    send('scroll 0 0 -15 -1')
    time.sleep(.08)
    assert positions() == before_positions, 'old hard-coded navigation chord still active'
    send('mods 4')
    send('scroll 1 0 -15 -1')
    wait_for(lambda: positions() == first_positions)
    wm.write_text(scrolling + '\n[keybinds]\nwheel_scroll_left = []\n')
    reload()
    send('mods 4')
    send('scroll 1 0 -15 -1')
    time.sleep(.08)
    assert positions() == first_positions, 'disabled navigation chord still active'
    def focused():
        snapshot = json.loads(subprocess.check_output(
            [str(CTL), 'shell', 'snapshot', '--json'], env=env, timeout=5))
        return next(r['window'] for r in snapshot['upsert'] if r['kind'] == 'seat')

    def pointer_xy():
        with socket.socket(socket.AF_UNIX) as sock:
            sock.settimeout(5)
            sock.connect(str(runtime / 'aqueous/outputd.sock'))
            sock.sendall(b'{"op":"cursor_state"}\n')
            with sock.makefile('r') as stream:
                result = json.loads(stream.readline())
        assert result['ok'], result
        return result['x'], result['y']

    def inside(wid):
        g = next(w['geometry'] for w in windows() if w['id'] == wid)
        x, y = pointer_xy()
        return g['x'] <= x < g['x'] + g['width'] and g['y'] <= y < g['y'] + g['height']

    def all_axes():
        return sum(line.startswith('pointer axis ') and not line.startswith('pointer axis stop ')
                   for path in [client_log, *base.glob('companion-*.log')]
                   for line in path.read_text().splitlines())

    # Issue #64: the same focus action follows mouse_follows_focus for keyboard,
    # all wheel directions, and touchpad steps, with either hover-focus policy.
    for follows_mouse in (False, True):
        for follows_focus in (False, True):
            policy = preamble.replace('focus_follows_mouse = false',
                                     f'focus_follows_mouse = {str(follows_mouse).lower()}')
            policy = policy.replace('mouse_follows_focus = false',
                                    f'mouse_follows_focus = {str(follows_focus).lower()}')
            wm.write_text(policy + '\n[keybinds.custom]\n' + '\n'.join(
                f'"Super+Wheel{direction}" = "builtin:cycle_focus"'
                for direction in ('Up', 'Down', 'Left', 'Right')) + '\n')
            reload()
            send('mods 0')
            send('move')
            under_pointer = next(w['id'] for w in windows() if inside(w['id']))
            subprocess.run([str(CTL), 'window', 'activate', '--id', under_pointer, '--json'],
                           env=env, check=True, stdout=subprocess.DEVNULL, timeout=5)
            wait_for(lambda: focused() == under_pointer)
            for source, axis, delta in [(0, 0, -15), (0, 0, 15), (0, 1, -15),
                                        (0, 1, 15), (1, 0, 50), (None, 0, 0)]:
                before_focus, point, before_axes = focused(), pointer_xy(), all_axes()
                if source is None:
                    send('mods 0')
                    client_command('chord 15 64')  # Super+Tab: same cycle_focus action
                else:
                    send('mods 64')
                    send(f'scroll {axis} {source} {delta} {1 if delta > 0 else -1}')
                    if source == 1:
                        send('scroll 0 1 0 0')
                wait_for(lambda: focused() != before_focus)
                if follows_focus:
                    wait_for(lambda: inside(focused()))
                    assert pointer_xy() != point, 'focus changed without moving into the target'
                else:
                    time.sleep(.08)
                    assert pointer_xy() == point, 'disabled mouse_follows_focus still warped'
                assert all_axes() == before_axes, 'bound focus scroll leaked to a client'

            # Unbound scrolling stays with the application, preserving focus
            # and pointer position even when automatic focus warps are enabled.
            send('mods 0')
            before_focus, point, before_axes = focused(), pointer_xy(), all_axes()
            send('scroll 0 0 15 1')
            wait_for(lambda: all_axes() > before_axes)
            assert focused() == before_focus and pointer_xy() == point

    # Default scrolling navigation goes through navigateWithWheel as well as
    # handleWheel; it must retain the binding's focus cause after viewport motion.
    wm.write_text(scrolling.replace('mouse_follows_focus = false', 'mouse_follows_focus = true'))
    reload()
    leftmost = min(windows(), key=lambda w: w['geometry']['x'])['id']
    subprocess.run([str(CTL), 'window', 'activate', '--id', leftmost, '--json'],
                   env=env, check=True, stdout=subprocess.DEVNULL, timeout=5)
    wait_for(lambda: focused() == leftmost and inside(leftmost))
    send('move')
    point = pointer_xy()
    send('mods 64')
    send('scroll 0 0 15 1')
    wait_for(lambda: focused() != leftmost and inside(focused()))
    assert pointer_xy() != point, 'viewport focus failed to move the pointer'
    print('Wheel directions, steps, navigation rebinding, reload, inhibition, passthrough, and focus warps passed')
finally:
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
    for child in reversed(children):
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
    log.close()
