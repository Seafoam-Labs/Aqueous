#!/usr/bin/env python3
"""Exercise startup rejection and teardown with real Vulkan devices, no host outputs.

Requires an output-retry-testing build and a software ICD. Pass --hardware-count
when VK_DRIVER_FILES also exposes hardware ICDs. No fault hooks exist in releases.
"""
import argparse
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('compositor', type=Path)
parser.add_argument('--hardware-count', type=int, default=0)
parser.add_argument('--render-device', help='Also verify an explicit hardware restriction')
parser.add_argument('--xwayland', action='store_true', help='Also verify deferred Xwayland startup')
args = parser.parse_args()
total = args.hardware_count + 1

with tempfile.TemporaryDirectory(prefix='aqueous-candidates-') as directory:
    work = Path(directory)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_')) and
           k not in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD')}
    for name in ('runtime', 'home', 'config', 'cache', 'state'):
        (work / name).mkdir(mode=0o700)
    env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
               XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2')
    for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        path = work / f'{name.lower()}.toml'
        path.write_text('')
        env[f'AQUEOUS_{name}'] = str(path)

    def run(label, failures='', expected=1, success=True, extra=None, copy=False, xwayland=False):
        marker = work / 'desktop-started'
        marker.unlink(missing_ok=True)
        log_path = work / 'compositor.log'
        child_env = env | {'AQUEOUS_TEST_VULKAN_FAILURES': failures} | (extra or {})
        with log_path.open('w') as log:
            # The startup command is the boundary being tested: no rejected
            # candidate may publish the session or run user startup commands.
            child = subprocess.Popen([str(args.compositor.resolve()), *([] if xwayland else ['-no-xwayland']),
                                      '-c', f'touch {marker}'], env=child_env,
                                     stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 45
                while (child.poll() is None and time.monotonic() < deadline and
                       (not marker.exists() or (xwayland and 'Starting Xwayland on :' not in log_path.read_text()))):
                    time.sleep(.05)
                text = log_path.read_text()
                assert marker.exists() == success, (label, text)
                if success:
                    assert child.poll() is None, (label, text)
                else:
                    assert child.wait(timeout=5) != 0, (label, text)
                    assert 'VulkanRendererUnavailable' in text, (label, text)
                    assert not list((work / 'runtime').glob('wayland-*')), (label, text)
                candidates = re.findall(r'Trying Vulkan candidate \d+/\d+: .* \((hardware|software)\)', text)
                assert len(candidates) == expected, (label, candidates, text)
                assert candidates == sorted(candidates), (label, candidates)
                if xwayland:
                    assert text.count('Starting Xwayland on :') == 1, (label, text)
                if success and copy:
                    assert text.count('Vulkan CPU-copy frame committed') >= 2, (label, text)
                if success and expected <= args.hardware_count and not copy and not failures:
                    assert 'CPU-copy frame committed' not in text, (label, text)
                if success:
                    os.killpg(child.pid, signal.SIGTERM)
                    assert child.wait(timeout=10) == 0, (label, log_path.read_text())
                text = log_path.read_text()
                assert 'VUID-' not in text and 'Validation Error' not in text and 'panic:' not in text, (label, text)
                print(f'PASS: {label}')
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()

    run('default Vulkan selection', copy=args.hardware_count == 0)
    run('forced copy', extra={'AQUEOUS_VULKAN_PRESENTATION': 'copy'}, copy=True)
    if args.hardware_count:
        run('direct commit failure uses copy on same GPU', '1:direct', copy=True)
    for phase in ('renderer', 'effects', 'allocator', 'commit'):
        for rejected in range(1, total + 1):
            failures = ','.join(f'{i}:{phase}' for i in range(1, rejected + 1))
            run(f'{phase}: reject {rejected}, then retry or exhaust', failures,
                expected=min(rejected + 1, total), success=rejected < total,
                copy=rejected == args.hardware_count)
    run('force software respects restriction', extra={'WLR_RENDERER_FORCE_SOFTWARE': '1'}, copy=True)
    if args.xwayland:
        run('Xwayland starts only for accepted candidate', '1:commit' if total > 1 else '',
            expected=min(2, total), xwayland=True)
    if args.render_device:
        run('explicit hardware failure cannot select another GPU', '1:effects', success=False,
            extra={'WLR_RENDER_DRM_DEVICE': args.render_device})
