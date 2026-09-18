#!/usr/bin/env python3
"""Validate the real service bootstrap in a private compositor and temporary unit.
Requires a production pixman build with -Dinstance-name=aqueous-activity-fixture.
Does not start/stop any desktop or Pearl service belonging to the real session.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
UNIT = 'aqueous-activity-fixture-pearl.service'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, required=True)
    args = parser.parse_args()
    binary = args.compositor.resolve()
    work = Path(tempfile.mkdtemp(prefix='aq-as-'))
    print(f'Artifacts: {work}', flush=True)
    bus = f'unix:path=/run/user/{os.getuid()}/bus'
    host_env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS=bus)
    existing = subprocess.run(['systemctl', '--user', 'show', UNIT, '-p', 'LoadState', '--value'], env=host_env, text=True, capture_output=True)
    assert existing.stdout.strip() == 'not-found', 'refusing to replace an existing test unit'
    generated = []
    for name, xml in {
        'activity': ROOT / 'protocol/aqueous-input-activity-v1.xml',
        'xdg-shell': Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml'),
        'session-lock': Path('/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml'),
    }.items():
        subprocess.run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'], check=True)
        code = work / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', xml, code], check=True)
        generated.append(code)
    client = work / 'client'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/input-activity-client.c', *generated,
                    '-lwayland-client', '-o', client], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD'):
        env.pop(key, None)
    for name in ('home', 'config', 'runtime', 'cache', 'state'):
        (work / name).mkdir(mode=0o700)
    env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'), XDG_CONFIG_HOME=str(work / 'config'),
               XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'), XDG_CONFIG_DIRS=str(work / 'config'),
               DBUS_SESSION_BUS_ADDRESS=bus, WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
    log = (work / 'compositor.log').open('w')
    compositor = subprocess.Popen([binary, '-no-xwayland', '-c', 'true'], env=env, stdout=log, stderr=log)
    started = False
    locker_fd = None
    try:
        ipc = None
        for _ in range(500):
            assert compositor.poll() is None, (work / 'compositor.log').read_text()
            ipc = next((work / 'runtime').glob('aqueous-activity-fixture/*/ipc.sock'), None)
            if ipc and (ipc.parent / 'activity.sock').exists():
                break
            time.sleep(.01)
        assert ipc, 'no private compositor endpoint'
        display = next(p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket())
        launch = ['systemd-run', '--user', f'--unit={UNIT}', '--collect', '--wait', '--pipe', '--service-type=exec',
                  '--property=KillMode=process', f'--setenv=AQUEOUS_SOCKET={ipc}', f'--setenv=WAYLAND_DISPLAY={display}',
                  f'--setenv=XDG_RUNTIME_DIR={work / "runtime"}', '--property=UnsetEnvironment=WAYLAND_SOCKET']
        # Same wrapper and endpoint under an ordinary process must not obtain a grant.
        ordinary_env = dict(env, AQUEOUS_SOCKET=str(ipc), WAYLAND_DISPLAY=display)
        subprocess.run([binary.parent / 'aqueous-activity-launch', '/bin/sh', '-c',
                        'test -z "${AQUEOUS_INPUT_ACTIVITY_FD-}"'], env=ordinary_env, check=True, timeout=5)
        started = True
        result = subprocess.run([*launch, binary.parent / 'aqueous-activity-launch', client, '--bootstrap-smoke', work / 'locker.pid'],
                                env=host_env, text=True, capture_output=True, timeout=15)
        (work / 'service.log').write_text(result.stdout + result.stderr)
        assert result.returncode == 0 and 'BOOTSTRAP_OK' in result.stdout, result.stdout + result.stderr
        locker = int((work / 'locker.pid').read_text())
        locker_fd = os.pidfd_open(locker)
        print('PASS: actual service MainPID verification, capability exec handoff, headless unsupported state, shared display and locker survival', flush=True)
    finally:
        if started:
            subprocess.run(['systemctl', '--user', 'kill', '--kill-whom=all', '--signal=KILL', UNIT], env=host_env, capture_output=True)
            subprocess.run(['systemctl', '--user', 'stop', UNIT], env=host_env, capture_output=True)
            if locker_fd is not None:
                try:
                    signal.pidfd_send_signal(locker_fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.close(locker_fd)
        compositor.terminate(); compositor.wait(timeout=10); log.close()


if __name__ == '__main__':
    main()
