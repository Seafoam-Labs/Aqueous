#!/usr/bin/env python3
"""Real Quickshell socket/UI test using DMS QML, without a desktop session.

DMS_SOURCE selects the host checkout. Reports its revision; callers must not
claim DMS 1.7 compatibility from a run against an older checkout.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
source = Path(os.environ['DMS_SOURCE']).resolve()
bridge = str(Path(sys.argv[1]).resolve())
qs = shutil.which(os.environ.get('QUICKSHELL', 'quickshell'))
assert qs
revision_file = source / '.aqueous-source-revision'
if revision_file.exists():
    revision = revision_file.read_text().strip()
else:
    revision = subprocess.check_output(['git', '-C', str(source), 'describe', '--tags', '--always'], text=True).strip()
print('DMS QML host under test:', revision, flush=True)
with tempfile.TemporaryDirectory(prefix='aq-ph-', dir='/tmp') as directory:
    work = Path(directory)
    for folder in ['run', 'config', 'state', 'cache', 'home', 'bin']:
        (work / folder).mkdir(mode=0o700)
    shutil.copytree(source / 'quickshell', work / 'quickshell', symlinks=True)
    shutil.copytree(source / 'dank-qml-common', work / 'dank-qml-common', symlinks=True)
    shutil.copytree(root / 'packaging/portal/dms', work / 'quickshell/Portal')
    harness = work / 'quickshell/PortalTest.qml'
    harness.write_text('''import QtQuick
import Quickshell
import Quickshell.Io
import "Portal"
ShellRoot {
    PortalDaemon { id: daemon }
    IpcHandler {
        target: "plugins"
        function status(plugin: string): string { return "loaded"; }
    }
    IpcHandler {
        target: "portalTest"
        function status(): string { return daemon.choosing ? "choosing" : "idle"; }
        function choose(index: int): string { daemon.choose(index); return "ok"; }
        function cancel(): string { daemon.cancel(); return "ok"; }
    }
}
''')
    # The bridge talks to the actual Quickshell IPC/socket implementation. The
    # only shim replaces DMS CLI session discovery for this isolated harness.
    (work / 'bin/dms').write_text('#!/usr/bin/python3\nimport os,sys\nos.execv(os.environ["TEST_QS"], [os.environ["TEST_QS"], "ipc", "-p", os.environ["TEST_HARNESS"]] + sys.argv[2:])\n')
    (work / 'bin/dms').chmod(0o755)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(work / 'run'),
               XDG_CONFIG_HOME=str(work / 'config'), XDG_STATE_HOME=str(work / 'state'),
               XDG_CACHE_HOME=str(work / 'cache'), HOME=str(work / 'home'),
               QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
               DMS_DISABLE_MATUGEN='1', DBUS_SESSION_BUS_ADDRESS='unix:path=' + str(work / 'no-bus'),
               PATH=str(work / 'bin') + ':' + os.environ['PATH'],
               TEST_QS=qs, TEST_HARNESS=str(harness))
    env.pop('LD_PRELOAD', None)
    log_path = work / 'host.log'
    with log_path.open('w') as log:
        shell = subprocess.Popen([qs, '-p', str(harness)], env=env, stdout=log, stderr=log)
        recorder = None
        def call(*args):
            return subprocess.run([qs, 'ipc', '-p', str(harness), 'call', 'portalTest', *args],
                                  env=env, capture_output=True, text=True, timeout=3)
        def wait_for(value):
            until = time.monotonic() + 10
            while time.monotonic() < until:
                assert shell.poll() is None, 'Host exited'
                result = call('status')
                if result.returncode == 0 and result.stdout.strip() == value:
                    return
                time.sleep(0.05)
            raise AssertionError('Host never reached ' + value)
        def start():
            proc = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, env=env)
            proc.stdin.write('Monitor: DP-1 test\nWindow: Résumé (id-2)\n'.encode())
            proc.stdin.close()
            proc.stdin = None
            return proc
        try:
            wait_for('idle')
            recorder = start()
            wait_for('choosing')
            assert call('choose', '1').returncode == 0
            out, err = recorder.communicate(timeout=5)
            assert recorder.returncode == 0 and out == 'Window: Résumé (id-2)\n'.encode(), (out, err)
            wait_for('idle')
            recorder = start()
            wait_for('choosing')
            call('cancel')
            out, err = recorder.communicate(timeout=5)
            assert recorder.returncode == 0 and not out, (out, err)
            wait_for('idle')
            recorder = start()
            wait_for('choosing')
            recorder.terminate()
            recorder.communicate(timeout=5)
            wait_for('idle')
            # A dead bridge must leave no socket or stale picker state.
            recorder = start()
            wait_for('choosing')
            call('choose', '0')
            out, err = recorder.communicate(timeout=5)
            assert recorder.returncode == 0 and out == b'Monitor: DP-1 test\n', (out, err)
            wait_for('idle')
            assert not list((work / 'run/aqueous-portal').glob('*.sock'))
        except BaseException:
            print(log_path.read_text(), file=sys.stderr)
            if recorder is not None and recorder.poll() is not None:
                print(recorder.communicate(), file=sys.stderr)
            raise
        finally:
            if recorder is not None and recorder.poll() is None:
                recorder.kill()
                recorder.communicate()
            shell.terminate()
            try:
                shell.wait(timeout=5)
            except subprocess.TimeoutExpired:
                shell.kill()
                shell.wait()
        text = log_path.read_text()
        for failure in ['ReferenceError', 'TypeError', 'Binding loop', 'Cannot assign', 'is not a type']:
            assert failure not in text, text
print('Real DMS QML and Quickshell: selection, cancellation, disconnect and repeated requests passed')
