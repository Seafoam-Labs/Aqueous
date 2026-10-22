#!/usr/bin/env python3
"""Exercise the real backend, portal router and PipeWire on a private headless desktop.

No host services, environment imports, or actual desktop capture are used.
Requires python-gobject, dbus, pipewire, xdg-desktop-portal and a built Aqueous.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def wait_for(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('Timed out waiting for private portal session')


def chooser():
    choices = sys.stdin.read().splitlines()
    root = Path(os.environ['PORTAL_TEST_ROOT'])
    with (root / 'invocations').open('a') as log:
        log.write(json.dumps({'pid': os.getpid(), 'parent': os.getenv('AQUEOUS_PORTAL_PARENT_WINDOW'),
                              'activation': os.getenv('XDG_ACTIVATION_TOKEN'), 'choices': choices}) + '\n')
    mode = (root / 'choice').read_text()
    if mode == 'hold':
        while True:
            time.sleep(1)
    if mode == 'accept' and choices:
        print(choices[0])


def client(mode):
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    backend = 'org.freedesktop.impl.portal.desktop.aqueous'
    frontend = 'org.freedesktop.portal.Desktop'
    base = '/org/freedesktop/portal/desktop'
    root = Path(os.environ['PORTAL_TEST_ROOT'])
    prefix = base + '/session/test/'
    request_prefix = base + '/request/test/'
    impl = 'org.freedesktop.impl.portal.ScreenCast'
    expected = {'default': 1, 'transient': 1, 'none': 0, 'permanent': 2}[mode]

    def call(method, signature, args, destination=backend, interface=impl, path=base):
        return bus.call_sync(destination, path, interface, method,
                             GLib.Variant(signature, args) if signature else None,
                             None, 0, 5000, None)

    def invocations():
        return [json.loads(line) for line in (root / 'invocations').read_text().splitlines()] if (root / 'invocations').exists() else []

    def create():
        handle = prefix + 's' + uuid.uuid4().hex
        code, _ = call('CreateSession', '(oosa{sv})', (request_prefix + uuid.uuid4().hex, handle, 'test', {})).unpack()
        assert code == 0
        return handle

    def select(handle, persist=2, restore=None, types=1):
        options = {'restore_data': restore} if restore is not None else {}
        options.update(types=GLib.Variant('u', types), cursor_mode=GLib.Variant('u', 1),
                       persist_mode=GLib.Variant('u', persist))
        before = len(invocations())
        result = call('SelectSources', '(oosa{sv})', (request_prefix + uuid.uuid4().hex, handle, 'test', options))
        assert result.unpack()[0] == 0
        assert len(invocations()) == before, 'SelectSources must not launch a chooser'

    def start(handle, parent='', token='', request=None):
        options = {'activation_token': GLib.Variant('s', token)} if token else {}
        return call('Start', '(oossa{sv})', (request or request_prefix + uuid.uuid4().hex, handle, 'test', parent, options))

    def close(handle):
        call('Close', None, None, interface='org.freedesktop.impl.portal.Session', path=handle)

    def fails(action):
        try:
            action()
        except GLib.Error:
            return
        raise AssertionError('Expected invalid request to fail')

    def restore_of(reply):
        return reply.get_child_value(1).lookup_value('restore_data', None)

    (root / 'choice').write_text('accept')
    fails(lambda: start(prefix + 'missing'))
    fails(lambda: select(prefix + 'missing'))
    fresh = create()
    fails(lambda: start(fresh))
    fails(lambda: select(fresh, persist=99))
    close(fresh)
    # Keep sessions alive together: list head/order must not affect the reply.
    sessions = [create() for _ in range(3)]
    restore = None
    for handle, persist in zip(sessions, (0, 2, 1)):
        select(handle, persist)
        fails(lambda: select(handle, persist))
        reply = start(handle, 'wayland:test-parent', 'test-token')
        code, value = reply.unpack()
        assert code == 0 and len(value['streams']) == 1, (code, value)
        assert value['persist_mode'] == min(persist, expected), value
        assert ('restore_data' in value) == (min(persist, expected) > 0), value
        assert invocations()[-1]['parent'] == 'wayland:test-parent'
        assert invocations()[-1]['activation'] == 'test-token'
        fails(lambda: start(handle))
        if persist == 2:
            restore = restore_of(reply)
    for handle in sessions:
        close(handle)
    if restore:
        before = len(invocations())
        handle = create(); select(handle, restore=restore)
        value = start(handle).unpack()[1]
        assert value['persist_mode'] == expected, value
        assert len(invocations()) == before, 'Valid restore must not launch the picker'
        close(handle)
        before = len(invocations())
        handle = create(); select(handle, persist=0, restore=restore)
        value = start(handle).unpack()[1]
        assert value['persist_mode'] == 0 and 'restore_data' not in value
        assert len(invocations()) == before + 1, 'No-persistence request must not reuse consent'
        close(handle)
    # Bad restore metadata must not poison options parsed after it or bypass UI.
    bad = [GLib.Variant('s', 'wrong type'),
           GLib.Variant('(suv)', ('other', 1, GLib.Variant('a{sv}', {}))),
           GLib.Variant('(suv)', ('wlroots', 99, GLib.Variant('s', 'new version'))),
           GLib.Variant('(suv)', ('wlroots', 1, GLib.Variant('s', 'wrong payload'))),
           GLib.Variant('(suv)', ('wlroots', 1, GLib.Variant('a{sv}', {'output_name': GLib.Variant('s', 'gone')})))]
    for data in bad:
        before = len(invocations()); handle = create(); select(handle, restore=data)
        assert start(handle).unpack()[1]['persist_mode'] == expected
        assert len(invocations()) == before + 1
        assert invocations()[-1]['activation'] is None, 'Previous request token leaked'
        close(handle)
    if restore:
        handle = create(); select(handle, restore=restore, types=2)
        assert start(handle).unpack()[0] == 1, 'Monitor restore must not satisfy a windows-only request'
        close(handle)
    (root / 'choice').write_text('cancel')
    handle = create(); select(handle)
    assert start(handle).unpack() == (1, {})
    count = len(invocations()); time.sleep(.2)
    assert len(invocations()) == count
    fails(lambda: start(handle))
    close(handle)

    def pump(predicate):
        def check():
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            return predicate()
        return wait_for(check)

    # Async Start remains cancellable and only responds once.
    for close_session in (False, True):
        (root / 'choice').write_text('hold')
        handle = create(); select(handle); request = request_prefix + uuid.uuid4().hex
        before = len(invocations()); answers = []
        def finished(connection, result, data):
            answers.append(connection.call_finish(result).unpack())
        bus.call(backend, base, impl, 'Start', GLib.Variant('(oossa{sv})', (request, handle, 'test', '', {})),
                 None, 0, 5000, None, finished, None)
        pump(lambda: len(invocations()) > before)
        pid = invocations()[-1]['pid']
        if close_session:
            close(handle)
        else:
            call('Close', None, None, interface='org.freedesktop.impl.portal.Request', path=request)
        pump(lambda: answers)
        assert answers == [(1, {})], answers
        def dead():
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            return False
        wait_for(dead)
        if not close_session:
            close(handle)
        assert len(invocations()) == before + 1
    print(f'PASS {mode}: session lookup, persistence bounds, restore validation, request metadata, cancellation', flush=True)

    # Public API: preview then stream using the opaque restore token.
    (root / 'choice').write_text('accept')
    replies = {}
    bus.signal_subscribe(frontend, 'org.freedesktop.portal.Request', 'Response', None, None, 0,
                         lambda c, s, p, i, m, a, d: replies.update({p: a.unpack()}), None)
    def public(method, signature, args):
        # A late cancellation response must not be mistaken for a newer request.
        args[-1]['handle_token'] = GLib.Variant('s', 'r'+uuid.uuid4().hex)
        request = call(method, signature, args, destination=frontend,
                       interface='org.freedesktop.portal.ScreenCast').unpack()[0]
        pump(lambda: request in replies)
        code, value = replies.pop(request)
        assert code == 0, (code, value)
        return value
    def capture(token):
        value = public('CreateSession', '(a{sv})', ({'session_handle_token': GLib.Variant('s', 's'+uuid.uuid4().hex)},))
        handle = value['session_handle']
        options = {'types': GLib.Variant('u', 1), 'persist_mode': GLib.Variant('u', 2)}
        if token:
            options['restore_token'] = GLib.Variant('s', token)
        public('SelectSources', '(oa{sv})', (handle, options))
        value = public('Start', '(osa{sv})', (handle, '', {}))
        assert len(value['streams']) == 1
        call('Close', None, None, destination=frontend, interface='org.freedesktop.portal.Session', path=handle)
        return value.get('restore_token')
    before = len(invocations()); token = capture(None); capture(token)
    assert bool(token) == (expected > 0)
    assert len(invocations()) == before + (1 if expected else 2)
    print(f'PASS {mode}: public preview/share picker count = {1 if expected else 2}', flush=True)
    # Cancellation through the router, including loss of its D-Bus owner.
    for action in ('request', 'session', 'owner'):
        handle = public('CreateSession', '(a{sv})', ({'session_handle_token': GLib.Variant('s', 's'+uuid.uuid4().hex)},))['session_handle']
        public('SelectSources', '(oa{sv})', (handle, {'types': GLib.Variant('u', 1)}))
        (root / 'choice').write_text('hold')
        before = len(invocations())
        request = call('Start', '(osa{sv})', (handle, '', {'handle_token': GLib.Variant('s', 'r'+uuid.uuid4().hex)}), destination=frontend,
                       interface='org.freedesktop.portal.ScreenCast').unpack()[0]
        pump(lambda: len(invocations()) > before)
        pid = invocations()[-1]['pid']
        # Only the router that owns this backend request may close it.
        fails(lambda: call('Close', None, None, interface='org.freedesktop.impl.portal.Request', path=request))
        if action == 'owner':
            os.kill(int(os.environ['PORTAL_TEST_FRONTEND_PID']), signal.SIGKILL)
        else:
            call('Close', None, None, destination=frontend,
                 interface='org.freedesktop.portal.'+('Request' if action == 'request' else 'Session'),
                 path=request if action == 'request' else handle)
        wait_for(dead)
        time.sleep(.1)
        assert len(invocations()) == before + 1
    print(f'PASS {mode}: public Request.Close, Session.Close, owner loss and sender authorization', flush=True)


@contextlib.contextmanager
def private_session(compositor, backend, mode):
    children = []; logs = []
    with tempfile.TemporaryDirectory(prefix='aqueous-portal-session-') as temporary:
        root = Path(temporary)
        env = {key: os.environ[key] for key in ('PATH', 'LANG', 'LC_ALL') if key in os.environ}
        for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_CONFIG_HOME', 'XDG_CONFIG_DIRS', 'XDG_CACHE_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME'):
            directory = root / key; directory.mkdir(mode=0o700); env[key] = str(directory)
        env.update(XDG_CURRENT_DESKTOP='Aqueous', XDG_SESSION_TYPE='wayland', PORTAL_TEST_ROOT=str(root),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(root/'no-system-bus'))
        def spawn(name, argv, **overrides):
            log = (root / (name+'.log')).open('w'); logs.append(log)
            proc = subprocess.Popen([str(arg) for arg in argv], env={**env, **overrides}, stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            children.append(proc)
            return proc
        try:
            bus_path = root/'bus'
            env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path='+str(bus_path)
            spawn('bus', ['dbus-daemon', '--session', '--nofork', '--address='+env['DBUS_SESSION_BUS_ADDRESS']])
            wait_for(bus_path.exists)
            config = root/'wm.toml'; config.write_text('[layout]\ndefault="floating"\n[input]\nfocus_new_windows=false\n')
            env['AQUEOUS_CONFIG'] = str(config)
            for key in ('LAYOUT', 'INPUT', 'OUTPUTS', 'RULES'):
                env['AQUEOUS_'+key] = str(root/('missing-'+key))
            spawn('compositor', [compositor, '-no-xwayland', '-c', 'printenv WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/display"'],
                  WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman')
            display = Path(env['XDG_RUNTIME_DIR'])/'display'
            env['WAYLAND_DISPLAY'] = wait_for(lambda: display.read_text().strip() if display.exists() else '')
            pw = root/'pipewire.conf'
            pw.write_text('''context.properties = { core.daemon = true core.name = pipewire-0 }
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
 { name = libpipewire-module-access args = { access.force = unrestricted } }
]
''')
            spawn('pipewire', ['pipewire', '-c', pw])
            wait_for(lambda: (Path(env['XDG_RUNTIME_DIR'])/'pipewire-0').exists())
            import shlex
            config = root/'capture.conf'
            config.write_text('[screencast]\nchooser_type=dmenu\nchooser_cmd='+shlex.join([sys.executable, str(Path(__file__).resolve()), '--chooser'])+'\n')
            overrides = {} if mode == 'default' else {'XDPW_PERSIST_MODE': mode}
            spawn('backend', [backend, '-c', config, '-l', 'DEBUG'], **overrides)
            def owns(name):
                result = subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus', '--object-path',
                                         '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.NameHasOwner', name],
                                        env=env, capture_output=True, text=True, timeout=2)
                return 'true' in result.stdout
            wait_for(lambda: owns('org.freedesktop.impl.portal.desktop.aqueous'))
            portals = root/'portals'; portals.mkdir()
            (portals/'aqueous.portal').write_bytes((ROOT/'packaging/portal/aqueous.portal').read_bytes())
            (portals/'portals.conf').write_text('[preferred]\ndefault=aqueous\n')
            spawn('permission-store', ['/usr/lib/xdg-permission-store'])
            frontend_proc = spawn('frontend', ['/usr/lib/xdg-desktop-portal', '--verbose'], XDG_DESKTOP_PORTAL_DIR=str(portals))
            env['PORTAL_TEST_FRONTEND_PID'] = str(frontend_proc.pid)
            wait_for(lambda: owns('org.freedesktop.portal.Desktop'))
            yield env
        except BaseException:
            for log in logs:
                print(f'{log.name}:\n'+Path(log.name).read_text()[-6000:], file=sys.stderr)
            raise
        finally:
            for proc in reversed(children):
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=3)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL); proc.wait()
            for log in logs:
                log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path)
    parser.add_argument('--compositor', type=Path, default=ROOT/'compositor/zig-out/bin/aqueous')
    parser.add_argument('--client', choices=['default', 'transient', 'none', 'permanent'])
    parser.add_argument('--chooser', action='store_true')
    args = parser.parse_args()
    if args.chooser:
        return chooser()
    if args.client:
        return client(args.client)
    if not args.backend:
        parser.error('--backend must name the rebuilt portal executable')
    for mode in ('default', 'transient', 'none', 'permanent'):
        with private_session(args.compositor.resolve(), args.backend.resolve(), mode) as env:
            subprocess.run([sys.executable, __file__, '--client', mode], env=env, check=True, timeout=45)


if __name__ == '__main__':
    main()
