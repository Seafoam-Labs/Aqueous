#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Reproduce the Aqueous XWayland resize-churn leak lead (WoW Forever report).

Drives fixtures/xwayland-resize-churn.c against a compositor and separates the
two Aqueous-specific mechanisms proposed in the investigation:

  mechanism 1  projection oscillation: renderFinish re-sends a projected
               ConfigureNotify while the committed surface size and the
               grid-rounded projection disagree. Detected when a passive or
               well-behaved (commit-mode) client keeps receiving
               size-changing configures it never asked for.
  mechanism 2  layout tug-of-war: a force-mode client re-asserts its own
               resolution like a game in forced window mode; a WM that keeps
               overriding it back produces an unbounded configure storm.

Growth is attributed per process: aqueous, Xwayland and the probe itself all
get RSS slopes per arm, so client-side, Xwayland-side and compositor-side
growth are distinguished.

Arms (per scaling mode): idle, grid, offgrid, force.
  idle     passive baseline; configure traffic after settle is already a defect
  grid     sizes that round-trip exactly through logical*scale
  offgrid  sizes that do not round-trip (odd pixels at 1.25/1.5/1.75)
  force    re-assert own offgrid sizes on every WM override

Headless mode starts an isolated compositor (headless backend, pixman) on one
fractional-scale output, like scripts/test-unmanaged-xwayland.py. Attach mode
runs the arms against the live $DISPLAY session instead.

Exit status: 0 no signal, 1 a mechanism was reproduced, 77 environment missing.
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
FIXTURE = Path(__file__).parent / 'fixtures/xwayland-resize-churn.c'


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--duration', type=int, default=15, help='seconds per arm')
    parser.add_argument('--scale', default='1.25', help='headless output scale')
    parser.add_argument('--attach', action='store_true',
                        help='use the live $DISPLAY session instead of a headless session')
    parser.add_argument('--scaling', default='native', choices=['native', 'legacy', 'both'],
                        help='Xwayland scaling mode(s) to exercise headlessly')
    parser.add_argument('--interval', type=int, default=250,
                        help='commit-mode resize interval in ms')
    parser.add_argument('--growth-kb-s', type=float, default=32.0,
                        help='RSS slope floor per arm to flag sustained growth')
    return parser.parse_args()


def proc_rss_kb(pid):
    try:
        for line in Path(f'/proc/{pid}/status').read_text().splitlines():
            if line.startswith('VmRSS:'):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def find_pids(comm):
    pids = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            if Path(f'/proc/{entry.name}/comm').read_text().strip() == comm:
                pids.append(int(entry.name))
        except OSError:
            pass
    return pids


class RssSampler(threading.Thread):
    """Sample VmRSS of named processes once per second while running."""

    def __init__(self, names):
        super().__init__(daemon=True)
        self.samples = {name: [] for name in names}
        self.names = names
        self.pids = {}
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            for name in self.names:
                pid = self.pids.get(name)
                if not pid or proc_rss_kb(pid) is None:
                    found = find_pids(name)
                    pid = found[0] if found else None
                    self.pids[name] = pid
                if pid:
                    rss = proc_rss_kb(pid)
                    if rss is not None:
                        self.samples[name].append((time.monotonic(), pid, rss))
            self.stop.wait(1.0)


def slope_kb_s(samples, start, end):
    """Least-squares KB/s over the steady window of one arm."""
    points = [(t - start, rss) for t, pid, rss in samples if start <= t <= end]
    if len(points) < 4:
        return 0.0
    mean_x = sum(x for x, _ in points) / len(points)
    mean_y = sum(y for _, y in points) / len(points)
    numerator = sum((x - mean_x) * (y - mean_y) for x, y in points)
    denominator = sum((x - mean_x) ** 2 for x, _ in points)
    return numerator / denominator if denominator else 0.0


def grid_sizes(scale_num, scale_den):
    """One pair of exact round-trip sizes and one pair of off-grid sizes.

    A physical size round-trips exactly under round(P/scale)->round(L*scale)
    when it is a multiple of the reduced scale numerator; sizes one pixel off
    the grid exercise the projection rounding instead.
    """
    step = scale_num
    base_w, base_h = 1000, 600
    aligned_w = (base_w // step) * step
    aligned_h = (base_h // step) * step
    grid = (aligned_w, aligned_h, aligned_w + step, aligned_h + step)
    offgrid = (aligned_w + 1, aligned_h + 2, aligned_w + 3, aligned_h + 1)
    return grid, offgrid


def parse_fraction(value):
    if '.' in value:
        digits, _, tail = value.partition('.')
        den = 10 ** len(tail)
        num = int(digits) * den + int(tail)
    else:
        num, den = int(value), 1
    from math import gcd
    common = gcd(num, den)
    return num // common, den // common


def wait_for(check, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError('condition timed out')


class Session:
    """Headless compositor/Xwayland session, one fractional-scale output."""

    def __init__(self, base, scale, scaling):
        self.runtime = base / 'runtime'
        self.runtime.mkdir(mode=0o700, parents=True)
        config = base / 'config'
        config.mkdir(exist_ok=True)
        (config / 'rules.toml').write_text('')
        outputs = config / 'outputs.toml'
        outputs.write_text(f'[[output]]\nname = "HEADLESS-1"\nposition = [0, 0]\nscale = {scale}\n')
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('AQUEOUS_')}
        self.env.update(XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                        XDG_RUNTIME_DIR=str(self.runtime), XDG_CONFIG_HOME=str(config),
                        HOME=str(base), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
                        WLR_RENDERER='pixman',
                        AQUEOUS_CONFIG=str(ROOT / 'scripts/fixtures/overview-wm.toml'),
                        AQUEOUS_OUTPUTS=str(outputs), AQUEOUS_RULES=str(config / 'rules.toml'))
        for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            self.env.pop(key, None)
        self.log = (base / 'compositor.log').open('w+')
        self.compositor = subprocess.Popen(
            [str(BIN), '-xwayland-scaling', scaling, '-c',
             'printf %s "$DISPLAY" > "$XDG_RUNTIME_DIR/test-display"'],
            env=self.env, stdout=self.log, stderr=self.log)
        self.env['WAYLAND_DISPLAY'] = wait_for(lambda: next(
            (p.name for p in self.runtime.glob('wayland-*') if p.is_socket()), None))
        self.env['DISPLAY'] = wait_for(lambda: (self.runtime / 'test-display').read_text().strip()
                                       if (self.runtime / 'test-display').exists() else None)

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
    """Attach the arms to the live session (the WoW-on-Aqueous reproduction)."""

    def __init__(self):
        if not os.environ.get('DISPLAY'):
            raise SystemExit('--attach requires DISPLAY from the Aqueous session')
        self.env = os.environ.copy()

    def alive(self):
        return True

    def close(self):
        pass


def run_arm(binary, env, name, mode, seconds, interval, sizes):
    """Run one probe arm; return per-second rows parsed from the fixture."""
    process = subprocess.Popen(
        [str(binary), mode, str(seconds), str(interval), *[str(s) for s in sizes]],
        env=env, stdout=subprocess.PIPE, text=True, bufsize=1)
    rows = []
    summary = None
    assert process.stdout is not None
    for line in process.stdout:
        line = line.strip()
        if not line:
            continue
        if line.startswith('SUMMARY'):
            summary = [int(value) for value in line.split(',')[2:]]
        else:
            rows.append([int(value) for value in line.split(',')])
    assert process.wait(timeout=10) == 0, f'{name}: probe exited nonzero'
    assert summary is not None, f'{name}: no SUMMARY line'
    # t, configures, size_changes, moves, requests, overrides, pixmaps, rss
    steady_start = seconds * 0.4
    duration = max(1.0, seconds - steady_start)
    baseline = rows[0] if rows else [0] * 8
    last = rows[-1] if rows else [0] * 8
    return {
        'name': name, 'mode': mode, 'rows': rows,
        'size_changes_per_s': (last[2] - baseline[2]) / duration,
        'moves_per_s': (last[3] - baseline[3]) / duration,
        'requests_per_s': (last[4] - baseline[4]) / duration,
        'overrides_per_s': (last[5] - baseline[5]) / duration,
        'rss_growth_kb': last[7] - baseline[7],
    }


def analyze(arms, scaling):
    """Return human-readable findings for one scaling mode's arms."""
    findings = []
    by_name = {arm['name'].split('/')[-1]: arm for arm in arms}
    idle = by_name.get('idle')
    if idle and idle['size_changes_per_s'] > 1.0:
        findings.append(
            f'[{scaling}] passive window reconfigured {idle["size_changes_per_s"]:.1f}x/s '
            'with no client requests: unsolicited configure traffic')
    grid = by_name.get('grid')
    offgrid = by_name.get('offgrid')
    if offgrid and grid and idle and idle['size_changes_per_s'] < 1.0:
        excess = offgrid['size_changes_per_s'] - offgrid['requests_per_s']
        grid_excess = grid['size_changes_per_s'] - grid['requests_per_s']
        if excess > 0.5 and excess > grid_excess + 0.5:
            findings.append(
                f'[{scaling}] mechanism 1 (projection round-trip churn): offgrid arm received '
                f'{excess:.1f} size-changing configures/s beyond its own requests, versus '
                f'{grid_excess:.1f}/s for the grid-aligned control. Each extra configure is '
                'one more WM_SIZE for a Wine client to rebuild drawables for')
    force = by_name.get('force')
    if force and force['overrides_per_s'] > 5.0:
        findings.append(
            f'[{scaling}] mechanism 2 (layout tug-of-war): force arm was overridden '
            f'{force["overrides_per_s"]:.1f}x/s while re-asserting its own size; '
            'a game client in this loop rebuilds drawables/device state continuously')
    return findings


def report_growth(sampler, arms, growth_floor, lines):
    end = time.monotonic()
    lines.append('')
    lines.append(f'{"arm":<22} {"cfg/s":>7} {"over/s":>7} ' +
                 ' '.join(f'{name + " KB/s":>15}' for name in sampler.samples))
    for arm in arms:
        start = arm['window'][0]
        stop = arm['window'][1]
        slopes = {name: slope_kb_s(samples, start, stop) for name, samples in sampler.samples.items()}
        lines.append(f'{arm["name"]:<22} {arm["size_changes_per_s"]:>7.1f} '
                     f'{arm["overrides_per_s"]:>7.1f} ' +
                     ' '.join(f'{slopes[name]:>15.1f}' for name in sampler.samples))
        for name, slope in slopes.items():
            if slope >= growth_floor:
                idle_slope = arm.get('idle_slope', {}).get(name, 0.0)
                if slope > 2 * max(idle_slope, 1.0):
                    lines.append(f'  NOTE: {name} grew {slope:.1f} KB/s during {arm["name"]} '
                                 f'(idle baseline {idle_slope:.1f} KB/s)')


def main():
    args = parse_args()
    for tool in ('cc', 'pkg-config'):
        if subprocess.run(['which', tool], capture_output=True).returncode:
            print(f'SKIP: {tool} is required to build the fixture')
            return 77
    flags = shlex.split(subprocess.check_output(
        ['pkg-config', '--cflags', '--libs', 'x11'], text=True))
    tmp = tempfile.TemporaryDirectory(prefix='aqueous-resize-churn-')
    base = Path(tmp.name)
    binary = base / 'probe'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-g',
                    str(FIXTURE), '-o', str(binary), *flags], check=True)
    scale_num, scale_den = parse_fraction(args.scale)
    grid, offgrid = grid_sizes(scale_num, scale_den)
    arms_plan = [
        ('idle', 'idle', 0, (0, 0, 0, 0)),
        ('grid', 'commit', args.interval, grid),
        ('offgrid', 'commit', args.interval, offgrid),
        ('force', 'force', args.interval, offgrid),
    ]
    scalings = ['native', 'legacy'] if args.scaling == 'both' else [args.scaling]
    if args.attach:
        scalings = ['session']

    findings, output, reproduced = [], [], False
    sampler = RssSampler(['aqueous', 'Xwayland'])
    sampler.start()
    sessions = []
    try:
        for scaling in scalings:
            session = (AttachSession() if args.attach
                       else Session(base / f'session-{scaling}', args.scale, scaling))
            sessions.append(session)
            if isinstance(session, Session):
                sampler.pids['aqueous'] = session.compositor.pid
            arms = []
            for name, mode, interval, sizes in arms_plan:
                if not session.alive():
                    raise AssertionError('compositor exited during the run')
                print(f'== {scaling}/{name} ({args.duration}s) ==', flush=True)
                window_start = time.monotonic()
                arm = run_arm(binary, session.env, f'{scaling}/{name}', mode,
                              args.duration, interval, sizes)
                arm['window'] = (window_start, time.monotonic())
                print('   ' + ', '.join(f'{key}={arm[key]:.1f}' for key in
                      ('size_changes_per_s', 'moves_per_s', 'requests_per_s',
                       'overrides_per_s')) + f', probe growth {arm["rss_growth_kb"]} KB')
                arms.append(arm)
            idle_window = next(a['window'] for a in arms if a['name'].endswith('/idle'))
            for arm in arms:
                arm['idle_slope'] = {
                    name: slope_kb_s(samples, *idle_window)
                    for name, samples in sampler.samples.items()
                }
            findings += analyze(arms, scaling)
            report_growth(sampler, arms, args.growth_kb_s, output)
    finally:
        sampler.stop.set()
        for session in sessions:
            session.close()
        tmp.cleanup()

    print('\n'.join(output))
    if findings:
        reproduced = True
        print('\nREPRODUCED:')
        print('\n'.join(findings))
    else:
        print('\nNo configure storm or sustained growth detected in this environment.')
    return 1 if reproduced else 0


if __name__ == '__main__':
    sys.exit(main())
