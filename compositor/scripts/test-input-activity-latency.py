#!/usr/bin/env python3
"""Compare native input delivery with the activity observer bypassed/idle/active.

Requires -Dinput-activity-testing=true -Dvulkan-effects=false. Uses only a private
headless display and synthetic devices. No physical input or host display access.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import select
import socket
import statistics
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MODES = ('bypass', 'idle', 'active')
CATEGORIES = ('key', 'button')


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)]


def distribution(values):
    return dict(n=len(values), median_us=statistics.median(values),
                p95_us=percentile(values, .95), p99_us=percentile(values, .99),
                max_us=max(values))


def paired_interval(deltas, rng):
    means = [statistics.mean(rng.choices(deltas, k=len(deltas))) for _ in range(5000)]
    low, high = percentile(means, .025), percentile(means, .975)
    return dict(mean_delta_us=statistics.mean(deltas), ci95_us=[low, high],
                increase_detected=low > 0, rounds=len(deltas))


class Client:
    def __init__(self, binary, env, work, name, latency=False):
        self.log = (work / f'{name}.jsonl').open('w')
        self.err = (work / f'{name}.log').open('w')
        self.process = subprocess.Popen([binary, *(['--latency'] if latency else [])],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.err)
        self.buffer = b''
        self.events = []
        try:
            self.wait(lambda e: e['event'] == 'connected')
        except BaseException:
            self.close()
            raise

    def wait(self, predicate, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                event = json.loads(line)
                self.log.write(line.decode() + '\n')
                self.events.append(event)
                if predicate(event):
                    return event
            remaining = deadline - time.monotonic()
            assert remaining > 0, 'client event timed out'
            assert select.select([self.process.stdout], [], [], remaining)[0], 'client event timed out'
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, f'client exited: {self.process.poll()}'
            self.buffer += chunk

    def command(self, value):
        self.process.stdin.write((value + '\n').encode())
        self.process.stdin.flush()
        self.wait(lambda e: e['event'] == 'command')

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.log.close()
        self.err.close()
        self.process.stdin.close()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--rounds', type=int, default=12)
    parser.add_argument('--samples', type=int, default=100, help='per category/mode/round, excluding warmup')
    parser.add_argument('--period-ms', type=float, default=2, help='minimum spacing between synthetic presses')
    parser.add_argument('--seed', type=int, default=20260918)
    parser.add_argument('--max-p95-increase-us', type=float,
                        help='optional budget: fail if upper paired p95 confidence bound exceeds this')
    args = parser.parse_args()
    assert args.rounds >= 6 and args.samples >= 50 and args.period_ms >= 1
    work = Path(tempfile.mkdtemp(prefix='aq-latency-'))
    print(f'Artifacts: {work}', flush=True)
    binary = args.compositor.resolve()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    for name in ('runtime', 'config', 'home', 'state', 'cache'):
        (work / name).mkdir(mode=0o700)
    env.update(XDG_RUNTIME_DIR=str(work / 'runtime'), XDG_CONFIG_HOME=str(work / 'config'),
               HOME=str(work / 'home'), XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'),
               XDG_CONFIG_DIRS=str(work / 'config'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman')
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
    client_binary = work / 'client'
    subprocess.run(['cc', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror', f'-I{work}',
                    ROOT / 'scripts/fixtures/input-activity-client.c', *generated,
                    '-lwayland-client', '-o', client_binary], check=True)
    control, child_control = socket.socketpair()
    control.settimeout(5)
    replies = control.makefile('rb')
    log = (work / 'compositor.log').open('w')
    compositor = subprocess.Popen([binary, '-no-xwayland', '-log-level', 'error',
                                   '-input-activity-test-fd', str(child_control.fileno()), '-c', 'true'],
                                  env=env, pass_fds=[child_control.fileno()], stdout=log, stderr=log)
    child_control.close()
    clients, samples, blocks = [], [], []
    rng = random.Random(args.seed)

    def inject(command):
        control.sendall((command + '\n').encode())
        reply = replies.readline().decode().strip()
        assert reply == 'ok' or reply.startswith('sample '), (command, reply)
        return reply

    def wait(predicate, message):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            assert compositor.poll() is None, (work / 'compositor.log').read_text()
            if result := predicate():
                return result
            time.sleep(.01)
        raise AssertionError(message)

    try:
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        ipc = wait(lambda: next((work / 'runtime').glob('aqueous/*/ipc.sock'), None), 'no IPC')
        env['AQUEOUS_SOCKET'] = str(ipc)
        wait(lambda: (ipc.parent / 'activity.sock').exists(), 'no bootstrap')
        owner = Client(client_binary, env, work, 'owner'); clients.append(owner)
        app = Client(client_binary, env, work, 'app', latency=True); clients.append(app)
        app.command('window')
        # Create both physical test devices before timed samples and let the app
        # bind its wl_keyboard/wl_pointer. Device creation is never measured.
        inject('key 0 30 0'); inject('button 0 272 0')
        app.command('sync')
        ctl = binary.parent / 'aqueousctl'
        def window():
            windows = json.loads(subprocess.check_output([ctl, 'windows', '--json'], env=env))
            return next((w for w in windows if w.get('app_id') == 'aqueous-activity-test-window'), None)
        win = wait(window, 'application did not map')
        activation = json.loads(subprocess.check_output([ctl, 'window', 'activate', '--id', win['id'], '--seat', 'default', '--json'], env=env))
        assert activation['ok'], activation
        g = win['geometry']
        inject(f'warp {g["x"] + g["width"] // 2} {g["y"] + g["height"] // 2}')
        app.command('sync')
        inject(f'owner {owner.process.pid}')
        owner.command('cap'); owner.command('authorize')
        assert next(e for e in reversed(owner.events) if e['event'] == 'authorization')['status'] == 0

        def sample(category):
            wall_start = time.monotonic()
            _, start, end = inject(f'sample {category}').split()
            event = app.wait(lambda e: e['event'] == f'{category}-delivered' and e['pressed'])
            start, end = int(start), int(end)
            assert event['time_ns'] >= start and end >= start
            inject(f'{category} 0 {30 if category == "key" else 272} 0')
            app.wait(lambda e: e['event'] == f'{category}-delivered' and not e['pressed'])
            remaining = args.period_ms / 1000 - (time.monotonic() - wall_start)
            if remaining > 0:
                time.sleep(remaining)
            return dict(ingress_us=(end - start) / 1000,
                        delivery_us=(event['time_ns'] - start) / 1000)

        subscribed = False
        for round_id in range(args.rounds):
            order = list(MODES)
            rng.shuffle(order)
            for mode in order:
                inject('observe 1')
                if subscribed:
                    owner.command('unsubscribe')
                    subscribed = False
                if mode == 'active':
                    owner.command('subscribe'); owner.command('ready 1')
                    assert next(e for e in reversed(owner.events) if e['event'] == 'state')['status'] == 0
                    subscribed = True
                if mode == 'bypass':
                    inject('observe 0')
                time.sleep(.12)
                owner.command('sync')
                activity_before = sum(e['event'] == 'activity' for e in owner.events)
                rows = {category: [] for category in CATEGORIES}
                for i in range(20 + args.samples):
                    # Balanced keyboard/mouse load; alternate the leading category.
                    for category in CATEGORIES[::1 if i % 2 else -1]:
                        row = sample(category)
                        if i >= 20:
                            rows[category].append(row)
                            samples.append(dict(round=round_id, mode=mode, category=category, **row))
                owner.command('sync')
                activity_count = sum(e['event'] == 'activity' for e in owner.events) - activity_before
                assert (activity_count > 0) == (mode == 'active'), (mode, activity_count)
                for category, values in rows.items():
                    blocks.append(dict(round=round_id, mode=mode, category=category,
                                       activity_notifications=activity_count,
                                       **{metric: distribution([v[metric] for v in values])
                                          for metric in ('ingress_us', 'delivery_us')}))
            print(f'Completed round {round_id + 1}/{args.rounds}', flush=True)

        summary, comparisons = {}, {}
        for category in CATEGORIES:
            summary[category], comparisons[category] = {}, {}
            for mode in MODES:
                summary[category][mode] = {
                    metric: distribution([s[metric] for s in samples if s['category'] == category and s['mode'] == mode])
                    for metric in ('ingress_us', 'delivery_us')}
            for mode in ('idle', 'active'):
                comparisons[category][mode] = {}
                for metric in ('ingress_us', 'delivery_us'):
                    comparisons[category][mode][metric] = {}
                    for statistic in ('median_us', 'p95_us'):
                        deltas = []
                        for round_id in range(args.rounds):
                            by_mode = {b['mode']: b[metric][statistic] for b in blocks
                                       if b['category'] == category and b['round'] == round_id}
                            deltas.append(by_mode[mode] - by_mode['bypass'])
                        comparisons[category][mode][metric][statistic] = paired_interval(deltas, rng)
        with binary.open('rb') as executable:
            executable_sha256 = hashlib.file_digest(executable, 'sha256').hexdigest()
        cpu = next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                    if line.startswith('model name')), platform.processor())
        report = dict(compositor=str(binary), compositor_sha256=executable_sha256,
                      platform=platform.platform(), cpu=cpu,
                      build_policy=json.loads((binary.parent.parent / 'share/aqueous/build-policy.json').read_text()),
                      clock='CLOCK_MONOTONIC', seed=args.seed, rounds=args.rounds,
                      samples_per_block=args.samples, period_ms=args.period_ms,
                      method='Same-process observer/timer bypass; randomized paired blocks; 5000 block bootstrap resamples',
                      limitations='Synthetic headless native Wayland only; excludes physical device, GPU/display and Pearl animation latency. Bypass is not a historical binary comparison.',
                      summary=summary, comparisons=comparisons, blocks=blocks)
        (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
        (work / 'samples.jsonl').write_text(''.join(json.dumps(s) + '\n' for s in samples))
        failed = False
        for category in CATEGORIES:
            print(f'{category}: application delivery (microseconds)')
            for mode in MODES:
                stats = summary[category][mode]['delivery_us']
                print(f'  {mode:6s}: median {stats["median_us"]:.2f}; p95 {stats["p95_us"]:.2f}; p99 {stats["p99_us"]:.2f}')
            for mode in ('idle', 'active'):
                delta = comparisons[category][mode]['delivery_us']['p95_us']
                low, high = delta['ci95_us']
                print(f'  {mode} minus bypass: paired p95 delta {delta["mean_delta_us"]:+.2f} us, 95% CI [{low:+.2f}, {high:+.2f}]')
                if args.max_p95_increase_us is not None and high > args.max_p95_increase_us:
                    failed = True
        assert not failed, f'p95 increase budget exceeded; see {work / "results.json"}'
        print(f'Completed latency comparison: {work / "results.json"}', flush=True)
    finally:
        for client in clients:
            client.close()
        if compositor.poll() is None:
            compositor.terminate()
        try:
            compositor.wait(timeout=10)
        except subprocess.TimeoutExpired:
            compositor.kill(); compositor.wait()
        replies.close(); control.close(); log.close()


if __name__ == '__main__':
    main()
