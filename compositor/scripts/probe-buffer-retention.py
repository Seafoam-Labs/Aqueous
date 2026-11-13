#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce the native-Wayland client-side buffer leak without the game.

The WoW Forever suspect (DX12 client under Wine's Wayland driver) grows the
*client's* RAM when a compositor retains committed wl_buffers: Wine never
blocks on presentation, so every frame whose buffer is still unreleased costs
a fresh shm allocation inside the game process. fixtures/buffer-retention-
client.c reproduces that bookkeeping with plain wl_shm:

  pool  honest client recycling a fixed pool. Healthy compositor: frame rate
        tracks the compositor, stalled_s stays 0. Retention: frames collapse
        and stalled_s climbs.
  wine  Wine-like client that allocates a fresh buffer whenever none is
        released. Healthy compositor: live_buffers and live_kb settle at the
        working set (~2-4). Retention: live_kb and RSS climb linearly with
        frames while frame rate stays high: the exact "game leaks, compositor
        looks fine" signature.

Headless mode starts an isolated compositor like scripts/test-unmanaged-
xwayland.py. Attach mode runs the arms against the live WAYLAND_DISPLAY
session, where compositor features (mirroring, warming, capture) that only
exist in the real session are part of the experiment.

Exit status: 0 no signal, 1 retention reproduced, 77 environment missing.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT / 'zig-out/bin/aqueous'))
FIXTURE = Path(__file__).parent / 'fixtures/buffer-retention-client.c'
XDG_XML = Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml')


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--duration', type=int, default=15, help='seconds per arm')
    parser.add_argument('--attach', action='store_true', help='use the live WAYLAND_DISPLAY')
    parser.add_argument('--size', default='640x480', help='window size, e.g. 1280x720')
    parser.add_argument('--pool', type=int, default=3, help='pool arm buffer count')
    parser.add_argument('--rules', type=Path,
                        help='rules.toml for the isolated session, e.g. a keep_render rule '
                             '(ignored with --attach, which uses the live session rules)')
    parser.add_argument('--growth-kb-s', type=float, default=1024.0,
                        help='live_kb slope floor to flag client-side growth')
    return parser.parse_args()


def proc_rss_kb(pid):
    try:
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith('VmRSS:'):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def wait_for(check, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError('condition timed out')


class Session:
    """Isolated headless compositor hosting the arms."""

    def __init__(self, base, rules=None):
        runtime = base / 'runtime'
        runtime.mkdir(mode=0o700, parents=True)
        config = base / 'config'
        config.mkdir(exist_ok=True)
        (config / 'rules.toml').write_text(rules.read_text() if rules else '')
        env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
        env.update(XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                   XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(config), HOME=str(base),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman',
                   AQUEOUS_CONFIG=str(ROOT / 'scripts/fixtures/overview-wm.toml'),
                   AQUEOUS_RULES=str(config / 'rules.toml'))
        for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        self.env = env
        self.log = (base / 'compositor.log').open('w+')
        self.compositor = subprocess.Popen(
            [str(BIN), '-c', 'printf %s "$DISPLAY" > "$XDG_RUNTIME_DIR/test-display"'],
            env=env, stdout=self.log, stderr=self.log)
        env['WAYLAND_DISPLAY'] = wait_for(lambda: next(
            (p.name for p in runtime.glob('wayland-*') if p.is_socket()), None))

    def alive(self):
        return self.compositor.poll() is None

    def close(self):
        if self.compositor.poll() is None:
            self.compositor.terminate()
            try:
                self.compositor.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.compositor.kill()
                self.compositor.wait()
        self.log.close()


class AttachSession:
    def __init__(self):
        if not os.environ.get('WAYLAND_DISPLAY'):
            raise SystemExit('--attach requires WAYLAND_DISPLAY from the Aqueous session')
        self.env = os.environ.copy()

    def alive(self):
        return True

    def close(self):
        pass


class AqueousRss(threading.Thread):
    """Sample the compositor's RSS so compositor-side growth is attributed."""

    def __init__(self):
        super().__init__(daemon=True)
        self.samples = []
        self.stop = threading.Event()

    def run(self):
        pid = None
        while not self.stop.is_set():
            if pid is None or proc_rss_kb(pid) is None:
                pid = next((int(p.name) for p in Path('/proc').iterdir()
                            if p.name.isdigit()
                            and (Path(f'/proc/{p.name}/comm').read_text().strip() == 'aqueous'
                                 if (Path(f'/proc/{p.name}/comm').exists()) else False)), None)
            if pid:
                rss = proc_rss_kb(pid)
                if rss is not None:
                    self.samples.append((time.monotonic(), rss))
            self.stop.wait(1.0)


def run_arm(binary, env, name, mode, seconds, width, height, pool):
    process = subprocess.Popen(
        [str(binary), mode, str(seconds), str(width), str(height), str(pool)],
        env=env, stdout=subprocess.PIPE, text=True, bufsize=1)
    rows, summary = [], None
    assert process.stdout is not None
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        if line.startswith('SUMMARY'):
            summary = [int(value) for value in line.split(',')[2:]]
        else:
            rows.append([int(value) for value in line.split(',')])
    code = process.wait(timeout=10)
    assert code == 0, f'{name}: probe exited {code} (a compositor protocol error also kills it)'
    assert summary is not None, f'{name}: no SUMMARY line'
    # t, frames, unreleased, live_buffers, live_kb, rss_kb, stalled_ms
    steady = [row for row in rows if row[0] >= 4000]
    first, last = (steady[0], steady[-1]) if len(steady) >= 2 else (rows[0], rows[-1])
    span = max(1, last[0] - first[0]) / 1000
    return {
        'name': name, 'mode': mode,
        'frames_per_s': (last[1] - first[1]) / span,
        'unreleased': summary[1], 'live_buffers': summary[2],
        'live_kb_per_s': (last[4] - first[4]) / span,
        'rss_kb_per_s': (last[5] - first[5]) / span,
        'stalled_s': summary[5] // 1000,
    }


def main():
    args = parse_args()
    for tool in ('cc', 'pkg-config', 'wayland-scanner'):
        if subprocess.run(['which', tool], capture_output=True).returncode:
            print(f'SKIP: {tool} is required')
            return 77
    if not XDG_XML.exists():
        print(f'SKIP: {XDG_XML} missing (wayland-protocols)')
        return 77
    width, _, height = args.size.partition('x')
    tmp = tempfile.TemporaryDirectory(prefix='aqueous-retention-')
    base = Path(tmp.name)
    subprocess.run(['wayland-scanner', 'client-header', str(XDG_XML),
                    str(base / 'xdg-shell-client-protocol.h')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', str(XDG_XML),
                    str(base / 'xdg-shell-protocol.c')], check=True)
    flags = shlex.split(subprocess.check_output(
        ['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    binary = base / 'probe'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-g', '-I', str(base),
                    str(FIXTURE), str(base / 'xdg-shell-protocol.c'),
                    '-o', str(binary), *flags], check=True)

    session = AttachSession() if args.attach else Session(base / 'session', args.rules)
    watcher = AqueousRss()
    watcher.start()
    findings, results = [], []
    try:
        for mode, pool in (('pool', args.pool), ('wine', 1)):
            if not session.alive():
                raise AssertionError('compositor exited during the run')
            print(f'== {mode} arm ({args.duration}s) ==', flush=True)
            start = time.monotonic()
            arm = run_arm(binary, session.env, mode, mode, args.duration, width, height, pool)
            window = (start, time.monotonic())
            aqueous = [s for s in watcher.samples if window[0] <= s[0] <= window[1]]
            slope = 0.0
            if len(aqueous) >= 4:
                xs = [t - window[0] for t, _ in aqueous]
                ys = [r for _, r in aqueous]
                mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
                den = sum((x - mx) ** 2 for x in xs)
                slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0
            arm['aqueous_kb_per_s'] = slope
            results.append(arm)
            print('   ' + ', '.join(f'{k}={arm[k]:.1f}' for k in
                  ('frames_per_s', 'live_kb_per_s', 'rss_kb_per_s', 'aqueous_kb_per_s'))
                  + f", unreleased={arm['unreleased']}, live={arm['live_buffers']},"
                    f" stalled={arm['stalled_s']}s")
    finally:
        watcher.stop.set()
        session.close()
        tmp.cleanup()

    by_mode = {arm['mode']: arm for arm in results}
    pool, wine = by_mode.get('pool'), by_mode.get('wine')
    if pool and (pool['stalled_s'] >= max(3, args.duration // 3)
                 or pool['frames_per_s'] < 5):
        findings.append(
            f'pool arm stalled {pool["stalled_s"]}s at {pool["frames_per_s"]:.1f} fps: the '
            'compositor is not returning committed buffers promptly to an honest client')
    if wine and wine['live_kb_per_s'] > args.growth_kb_s and wine['frames_per_s'] > 10:
        findings.append(
            f'wine arm grew {wine["live_kb_per_s"]:.0f} KB/s of live shm at '
            f'{wine["frames_per_s"]:.0f} fps with {wine["live_buffers"]} buffers never '
            'released: client-side buffer retention reproduced (the WoW Forever shape)')
    if findings:
        print('\nREPRODUCED:')
        print('\n'.join(findings))
        return 1
    print('\nNo retention signature: buffers are released and both arms stay bounded.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
