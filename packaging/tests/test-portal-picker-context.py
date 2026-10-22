#!/usr/bin/env python3
"""Verify exported-parent placement and modal focus for real GTK pickers."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('portal_session', Path(__file__).with_name('test-portal-session.py'))
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


def parent(connector):
    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('GdkWayland', '4.0')
    from gi.repository import Gtk, Gdk, GdkWayland, GLib
    app = Gtk.Application(application_id='org.aqueous.PortalParentTest', flags=32)
    def activate(app):
        window = Gtk.ApplicationWindow(application=app, title='Portal parent '+connector)
        display = Gdk.Display.get_default()
        monitors = display.get_monitors()
        monitor = next(monitors.get_item(i) for i in range(monitors.get_n_items()) if monitors.get_item(i).get_connector() == connector)
        window.fullscreen_on_monitor(monitor)
        window.present()
        def export():
            GdkWayland.WaylandToplevel.export_handle(window.get_surface(), lambda surface, handle, data: print('wayland:'+handle, flush=True), None)
            return False
        GLib.timeout_add(300, export)
    app.connect('activate', activate)
    app.run([])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--parent')
    parser.add_argument('--backend', type=Path)
    parser.add_argument('--compositor', type=Path, default=ROOT/'compositor/zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT/'compositor/zig-out/bin/aqueousctl')
    parser.add_argument('--picker', action='append', type=Path, default=[])
    args = parser.parse_args()
    if args.parent:
        return parent(args.parent)
    if not args.backend or not args.picker:
        parser.error('--backend and at least one --picker are required')
    with tempfile.TemporaryDirectory(prefix='aqueous-picker-context-') as directory:
        work = Path(directory)
        xml = ROOT/'compositor/protocol/upstream/virtual-keyboard-unstable-v1.xml'
        for mode, target in [('client-header', 'virtual-keyboard-client.h'), ('private-code', 'virtual-keyboard.c')]:
            subprocess.run(['wayland-scanner', mode, str(xml), str(work/target)], check=True)
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True))
        key = work/'key'
        subprocess.run(['cc', '-Wall', '-Wextra', '-o', str(key), '-I'+str(work), str(ROOT/'packaging/tests/portal-send-key.c'), str(work/'virtual-keyboard.c'), *flags], check=True)
        with session.private_session(args.compositor.resolve(), args.backend.resolve(), 'default') as env:
            env.update(GDK_BACKEND='wayland', GSK_RENDERER='cairo', GTK_A11Y='none')
            def ctl(*argv):
                return json.loads(subprocess.check_output([str(args.ctl.resolve()), *argv, '--json'], env=env, text=True, timeout=5))
            keyboard = subprocess.Popen([str(key), '--stdin'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            assert keyboard.stdout.readline().strip() == 'ready'
            try:
                check_pickers(args, work, env, ctl, keyboard)
            finally:
                keyboard.stdin.close(); keyboard.wait(timeout=5)


def check_pickers(args, work, env, ctl, keyboard):
    for connector in ('HEADLESS-1', 'HEADLESS-2'):
        parent_log = (work/'parent.log').open('w+')
        app = subprocess.Popen([sys.executable, __file__, '--parent', connector], env=env, stdout=parent_log, stderr=subprocess.PIPE)
        try:
            def exported():
                assert app.poll() is None, app.stderr.read().decode()
                lines = (work/'parent.log').read_text().splitlines()
                return next((line for line in lines if line.startswith('wayland:')), None)
            handle = session.wait_for(exported)
            parent_window = session.wait_for(lambda: next((w for w in ctl('windows') if w['title'] == 'Portal parent '+connector), None))
            for binary in args.picker:
                ctl('window', 'activate', '--id', str(parent_window['id']), '--seat', 'default')
                child = subprocess.Popen([str(binary.resolve())], env={**env, 'AQUEOUS_PORTAL_PARENT_WINDOW': handle}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    child.stdin.write(b'Monitor: HEADLESS-1\nMonitor: HEADLESS-2\n'); child.stdin.close(); child.stdin = None
                    def focused():
                        assert child.poll() is None, child.communicate()
                        windows = ctl('windows')
                        picker = next((w for w in windows if w['title'] in ('Share a source', 'Select a source to share')), None)
                        if picker and 'focused' in picker['states']:
                            return picker
                    picker = session.wait_for(focused)
                    # Parent and picker must occupy the same output, including
                    # when new-window focus is disabled and the parent is fullscreen.
                    pg, cg = parent_window['geometry'], picker['geometry']
                    assert pg['x'] <= cg['x'] < pg['x']+pg['width'], (parent_window, picker)
                    assert pg['y'] <= cg['y'] < pg['y']+pg['height'], (parent_window, picker)
                    # Keep one keyboard alive across focus transitions.
                    deadline = time.monotonic() + 3
                    while child.poll() is None and time.monotonic() < deadline:
                        keyboard.stdin.write('1\n'); keyboard.stdin.flush()
                        time.sleep(.1)
                    out, err = child.communicate(timeout=2)
                    assert child.returncode == 0 and not out, (child.returncode, out, err)
                    print(f'PASS {binary.name} {connector}: exported parent, modal focus, Escape cancellation', flush=True)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
        finally:
            app.terminate(); app.wait(timeout=5); parent_log.close()

if __name__ == '__main__':
    main()
