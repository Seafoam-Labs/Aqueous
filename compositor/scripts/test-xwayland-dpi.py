#!/usr/bin/env python3
"""X11 DPI worker recovery and optional isolated compositor/toolkit coverage."""
import argparse
import json
import math
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def compile_fixture(work, name, libraries, cpp=False):
    source = ROOT / 'scripts/fixtures' / (name + ('.cpp' if cpp else '.c'))
    binary = work / name
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', *libraries], text=True))
    subprocess.run(['c++' if cpp else 'cc', '-Wall', '-Wextra', '-Werror', '-g',
                    str(source), '-o', str(binary), *flags], check=True)
    return binary


def wait(check, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError('timed out waiting for ' + repr(check))


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def worker_test(work, fixture):
    subprocess.run([fixture], check=True)
    if not shutil.which('Xvfb'):
        print('SKIP independent worker lifecycle tests: Xvfb not installed', flush=True)
        return
    # Xvfb allocates a free display; never connect to the user's X server.
    read_fd, write_fd = os.pipe()
    with (work / 'xvfb.log').open('w') as log:
        process = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0',
                                    '1280x720x24', '-nolisten', 'tcp', '-noreset'],
                                   pass_fds=(write_fd,), stdout=log, stderr=log)
        os.close(write_fd)
        try:
            import select
            assert select.select([read_fd], [], [], 5)[0], (work / 'xvfb.log').read_text()
            number = os.read(read_fd, 64).decode().strip()
            assert number.isdecimal(), (work / 'xvfb.log').read_text()
            subprocess.run([fixture, ':' + number], check=True, timeout=40)
        finally:
            os.close(read_fd)
            stop(process)


def runtime_test(work, args, probe, qt, gtk):
    for mode in ('legacy', 'native'):
        case = work / mode
        case.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_', 'QT_', 'GDK_'))}
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        for key, name in (('HOME', 'home'), ('XDG_RUNTIME_DIR', 'run'), ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state')):
            path = case / name
            path.mkdir(mode=0o700)
            env[key] = str(path)
        config = case / 'config/aqueous'
        config.mkdir()
        (config / 'wm.toml').write_text('[workspace_transition]\nenabled = false\n')
        output_config = config / 'outputs.toml'
        output_config.write_text('[[output]]\nname="HEADLESS-1"\nscale=1.25\nprimary=true\n'
                                 '[[output]]\nname="HEADLESS-2"\nscale=1.0\nposition=[1024,0]\n')
        env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer)
        process = None
        with (case / 'compositor.log').open('w') as log:
            try:
                command = 'printenv DISPLAY > "$XDG_RUNTIME_DIR/display"; ' + shlex.quote(str(probe)) + ' > "$XDG_RUNTIME_DIR/initial.json"'
                command += '; printenv AQUEOUS_SOCKET > "$XDG_RUNTIME_DIR/ipc"'
                process = subprocess.Popen([args.compositor.resolve(), '-xwayland-scaling', mode, '-c', command],
                                           env=env, stdout=log, stderr=log)

                def running():
                    assert process.poll() is None, (case / 'compositor.log').read_text()

                def initial_ready():
                    running()
                    p = case / 'run/initial.json'
                    return p.exists() and p.stat().st_size

                wait(initial_ready)
                initial = json.loads((case / 'run/initial.json').read_text())
                assert initial['dpi'] == (120 if mode == 'native' else 0), initial
                env['DISPLAY'] = (case / 'run/display').read_text().strip()
                env['WAYLAND_DISPLAY'] = next(p.name for p in (case / 'run').glob('wayland-*') if p.is_socket())
                env['AQUEOUS_SOCKET'] = wait(lambda: (case / 'run/ipc').read_text().strip() if (case / 'run/ipc').exists() else None)

                def request(op, **fields):
                    running()
                    with socket.socket(socket.AF_UNIX) as channel:
                        channel.settimeout(5)
                        channel.connect(str(case / 'run/aqueous/outputd.sock'))
                        channel.sendall(json.dumps(dict(op=op, **fields)).encode() + b'\n')
                        return json.loads(channel.makefile().readline())

                def effective(dpi, source='HEADLESS-1'):
                    state = request('list')['xwayland_scaling']
                    if mode == 'legacy':
                        assert state['dpi_status'] == 'unmanaged' and state['published_dpi'] is None, state
                        return state
                    return state if state['published_dpi'] == dpi and state['source_output'] == source else None

                for scale in (1, 1.25, 1.5, 2, 1.25):
                    changed = request('set', changes=[dict(name='HEADLESS-1', scale=scale)])
                    assert changed['ok'], changed
                    wait(lambda: effective(96 * scale))
                    # Wait for actual committed output scale in legacy too.
                    wait(lambda: any(o['name'] == 'HEADLESS-1' and o['scale'] == scale for o in request('list')['outputs']))
                    sample = json.loads(subprocess.check_output([probe], env=env, text=True, timeout=5))
                    assert sample['dpi'] == (96 * scale if mode == 'native' else 0), sample
                    toolkit_env = dict(env, QT_QPA_PLATFORM='xcb', GDK_BACKEND='x11')
                    if qt:
                        q = json.loads(subprocess.check_output([qt], env=toolkit_env, text=True, timeout=10))
                        expected = scale if mode == 'native' else 1
                        assert abs(q['dpr'] - expected) < .001, q
                        assert abs(q['buffer_width'] - q['logical_width'] * expected) <= 1, q
                    if gtk:
                        g = json.loads(subprocess.check_output([gtk], env=toolkit_env, text=True, timeout=10))
                        integer_scale = math.ceil(scale) if mode == 'native' else 1
                        assert g['scale'] == integer_scale, g
                        if mode == 'native':
                            assert abs(g['font_dpi'] * g['scale'] - 96 * scale) < .01, g
                    print(f'PASS {mode}: scale={scale}, X11 DPI and toolkit buffers', flush=True)

                before = request('list')['xwayland_scaling']
                rejected = request('set', changes=[dict(name='HEADLESS-1', scale=0)])
                assert not rejected['ok'], rejected
                time.sleep(.2)
                assert request('list')['xwayland_scaling'] == before
                if mode == 'native':
                    if args.helper:
                        from ipc_test_client import Client
                        ipc = Client(env['AQUEOUS_SOCKET'])
                        try:
                            model = wait(lambda: (m if (m := ipc.call('display.snapshot')['result'])['observation'] == 'current' else None))
                            snapshot = json.loads(subprocess.check_output([args.helper.resolve(), 'snapshot', '--shell', 'none'], env=env, text=True))
                            source = output_config.read_text().replace('scale=1.25', 'scale=1.5')
                            candidate = dict(protocol=1, expected_generation=snapshot['generation'], raw_files={'outputs': source})
                            reviewed = json.loads(subprocess.check_output([args.helper.resolve(), 'validate', '--shell', 'none', '--request', '-'],
                                                  input=json.dumps(candidate), env=env, text=True))
                            preview = ipc.call('display.preview.begin', dict(display_revision=model['display_revision'],
                                candidate_digest=reviewed['candidate_review']['candidate_digest'], expected_generation=snapshot['generation'],
                                wm_source=snapshot['raw_files']['wm'], outputs_source=source))['result']
                            wait(lambda: effective(144))
                            ipc.call('display.preview.revert', dict(token=preview['token']))
                            wait(lambda: effective(120))
                            print('PASS native: actual display preview and revert restore DPI', flush=True)
                        finally:
                            ipc.close()
                    # A policy-only primary change must update DPI even without
                    # a geometry change or a window/focus transition.
                    output_config.write_text(output_config.read_text().replace('primary=true', 'primary=false') + 'primary=true\n')
                    wait(lambda: effective(96, 'HEADLESS-2'))
                    changed = request('set', changes=[dict(name='HEADLESS-2', enabled=False)])
                    assert changed['ok'], changed
                    wait(lambda: effective(120, 'HEADLESS-1'))
                    # wlroots restarts servers that have survived five seconds.
                    time.sleep(6)
                    def xwayland_pid():
                        # wlroots double-forks. Match both the process name and
                        # this test's unique runtime directory, never DISPLAY alone.
                        marker = ('XDG_RUNTIME_DIR=' + env['XDG_RUNTIME_DIR']).encode()
                        for child in Path('/proc').glob('[0-9]*'):
                            try:
                                if (child / 'comm').read_text().strip() == 'Xwayland' and marker in (child / 'environ').read_bytes().split(b'\0'):
                                    return int(child.name)
                            except (FileNotFoundError, PermissionError, ProcessLookupError):
                                pass
                        return None

                    previous = xwayland_pid()
                    assert previous is not None
                    os.kill(previous, signal.SIGKILL)
                    wait(lambda: (pid if (pid := xwayland_pid()) and pid != previous else None))

                    def republished():
                        sample = subprocess.run([probe], env=env, text=True, capture_output=True, timeout=5)
                        return sample.returncode == 0 and json.loads(sample.stdout)['dpi'] == 120

                    wait(republished)
                    wait(lambda: effective(120, 'HEADLESS-1'))
                    print('PASS native: embedded Xwayland restart republishes DPI', flush=True)
                if args.ctl:
                    outputs = json.loads(subprocess.check_output([args.ctl.resolve(), 'outputs', '--json'], env=env, text=True))
                    assert all(o['xwayland_scaling']['mode'] == mode for o in outputs), outputs
                print(f'PASS {mode}: startup publication, rejected transaction, primary/fallback and diagnostics', flush=True)
            except Exception:
                print((case / 'compositor.log').read_text()[-12000:], file=sys.stderr)
                raise
            finally:
                stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path)
    parser.add_argument('--ctl', type=Path)
    parser.add_argument('--helper', type=Path, help='aqueous-config binary for actual display preview/revert coverage')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='vulkan')
    parser.add_argument('--toolkits', action='store_true', help='Require Qt 6 Widgets and GTK 3 development packages')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='aqueous-dpi-') as temp:
        work = Path(temp)
        fixture = work / 'xwayland-dpi-test'
        subprocess.run(['zig', 'build-exe', str(ROOT / 'aqueous/xwayland_dpi_test.zig'),
                        '-lc', '-lxcb', '-fllvm', '-femit-bin=' + str(fixture)], check=True)
        worker_test(work, fixture)
        if args.compositor:
            probe = compile_fixture(work, 'xwayland-dpi-probe', ['x11'])
            qt = compile_fixture(work, 'xwayland-dpi-qt', ['Qt6Widgets'], cpp=True) if args.toolkits else None
            gtk = compile_fixture(work, 'xwayland-dpi-gtk', ['gtk+-3.0']) if args.toolkits else None
            runtime_test(work, args, probe, qt, gtk)


if __name__ == '__main__':
    main()
