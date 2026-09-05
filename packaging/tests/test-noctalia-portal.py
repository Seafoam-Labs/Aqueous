#!/usr/bin/env python3
"""Test the packaged Noctalia dmenu command on a fresh headless Aqueous session."""
import configparser
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
compositor = os.environ.get('AQUEOUS_COMPOSITOR_BIN', str(root / 'compositor/zig-out/bin/aqueous'))
with tempfile.TemporaryDirectory(prefix='aq-np-', dir='/tmp') as directory:
    work = Path(directory)
    protocol = root / 'compositor/protocol/upstream/virtual-keyboard-unstable-v1.xml'
    for mode, output in [('client-header', 'virtual-keyboard-client.h'), ('private-code', 'virtual-keyboard.c')]:
        subprocess.run(['wayland-scanner', mode, str(protocol), str(work / output)], check=True)
    flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client', 'xkbcommon'], text=True)
    subprocess.run(['cc', '-Wall', '-Wextra', '-o', str(work / 'key'), '-I' + str(work),
                    str(root / 'packaging/tests/portal-send-key.c'), str(work / 'virtual-keyboard.c'),
                    *shlex.split(flags)], check=True)
    for folder in ['run', 'home', 'config/noctalia', 'cache', 'state']:
        (work / folder).mkdir(parents=True, mode=0o700)
    (work / 'config/noctalia/config.toml').write_text('[plugins]\nenabled = []\n')
    (work / 'wm.toml').write_text('[layout]\ndefault = "tile"\n')
    env = dict(os.environ, HOME=str(work / 'home'), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_RUNTIME_DIR=str(work / 'run'), XDG_STATE_HOME=str(work / 'state'),
               XDG_CACHE_HOME=str(work / 'cache'), XDG_CURRENT_DESKTOP='Aqueous', XDG_SESSION_TYPE='wayland',
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman',
               LIBGL_ALWAYS_SOFTWARE='1', AQUEOUS_CONFIG=str(work / 'wm.toml'))
    for key in ['LD_PRELOAD', 'DISPLAY', 'WAYLAND_DISPLAY']:
        env.pop(key, None)
    for name in ['LAYOUT', 'INPUT', 'OUTPUTS', 'RULES']:
        env['AQUEOUS_' + name] = str(work / ('missing-' + name))
    dbus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True)
    env['DBUS_SESSION_BUS_ADDRESS'] = dbus.stdout.readline().strip()
    processes = [dbus]
    logs = []
    def spawn(name, command):
        log = (work / (name + '.log')).open('w')
        logs.append(log)
        proc = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        processes.append(proc)
        return proc
    chooser = None
    try:
        wm = spawn('compositor', [compositor, '-no-xwayland', '-policy', 'internal', '-log-level', 'error', '-c', 'true'])
        until = time.monotonic() + 10
        while not list((work / 'run').glob('wayland-*')):
            assert wm.poll() is None
            assert time.monotonic() < until
            time.sleep(0.05)
        env['WAYLAND_DISPLAY'] = next(p.name for p in (work / 'run').glob('wayland-*') if not p.name.endswith('.lock'))
        shell = spawn('noctalia', ['noctalia'])
        until = time.monotonic() + 15
        while True:
            assert shell.poll() is None
            result = subprocess.run(['noctalia', 'msg', 'color-scheme-get'], env=env, capture_output=True, timeout=3)
            if result.returncode == 0:
                break
            assert time.monotonic() < until
            time.sleep(0.1)
        config = configparser.ConfigParser(interpolation=None)
        config.read(root / 'packaging/portal/noctalia.conf')
        command = shlex.split(config['screencast']['chooser_cmd'])
        labels = 'Monitor: HEADLESS-1 Résumé $(literal) "quoted"\nWindow: duplicate (id-2)\nWindow: duplicate (id-3)\n'
        for cancel in [False, True]:
            chooser = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            chooser.stdin.write(labels.encode())
            chooser.stdin.close()
            chooser.stdin = None
            time.sleep(1)
            assert chooser.poll() is None, chooser.communicate()
            # A newly bound virtual keyboard can race the layer-shell focus
            # transition. Repeat the same action; no navigation state changes.
            deadline = time.monotonic() + 5
            while chooser.poll() is None and time.monotonic() < deadline:
                subprocess.run([str(work / 'key'), '1' if cancel else '28'], env=env, check=True, timeout=2)
                time.sleep(0.1)
            out, err = chooser.communicate(timeout=5)
            if cancel:
                assert out == b'', (out, err)
            else:
                assert chooser.returncode == 0 and out.decode() == labels.splitlines()[0] + '\n', (out, err)
    except BaseException:
        for log in logs:
            print(Path(log.name).read_text())
        raise
    finally:
        if chooser and chooser.poll() is None:
            chooser.terminate()
            chooser.communicate(timeout=5)
        for proc in reversed(processes):
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
        for log in logs:
            log.close()
print('Fresh Noctalia session: packaged chooser selection and cancellation passed on two headless outputs')
