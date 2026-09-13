#!/usr/bin/env python3
"""Compare two Aqueous builds with identical clients in private headless sessions.

Reports CPU, voluntary context switches (a wakeup proxy), presentation intervals,
and protocol commit throughput. Requires matched optimized builds. No physical
scanout, input-to-photon latency, or GPU power conclusions follow from this test.
Clients are untimed by default; --timing requires support in both compared builds.
Child count/topology options configure the rendered subsurface workload.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import select
import signal
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def percentile(values, p):
    values = sorted(values)
    if not values:
        return None
    index = (len(values) - 1) * p
    lower = int(index)
    upper = min(lower + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (index - lower)


def snapshot(pid):
    root = Path(f'/proc/{pid}')
    fields = (root / 'stat').read_text().rsplit(')', 1)[1].split()
    ticks = int(fields[11]) + int(fields[12])
    voluntary = involuntary = runtime_ns = main_voluntary = 0
    tids = []
    for task in (root / 'task').iterdir():
        try:
            status = task.joinpath('status').read_text()
        except FileNotFoundError:
            continue
        tids.append(int(task.name))
        switches = int(re.search(r'^voluntary_ctxt_switches:\s+(\d+)', status, re.M)[1])
        voluntary += switches
        if int(task.name) == pid:
            main_voluntary = switches
        runtime_ns += int(task.joinpath('schedstat').read_text().split()[0])
        involuntary += int(re.search(r'^nonvoluntary_ctxt_switches:\s+(\d+)', status, re.M)[1])
    rss = int(re.search(r'^VmRSS:\s+(\d+)', root.joinpath('status').read_text(), re.M)[1])
    return dict(cpu_s=ticks / os.sysconf('SC_CLK_TCK'), runtime_ns=runtime_ns,
                main_voluntary=main_voluntary, voluntary=voluntary,
                involuntary=involuntary, rss_kib=rss, tids=tids, wall_ns=time.monotonic_ns())


def event(process, wanted, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        assert process.poll() is None, f'client exited with {process.returncode}'
        if select.select([process.stdout], [], [], min(.2, end - time.monotonic()))[0]:
            line = process.stdout.readline()
            assert line, 'client closed stdout'
            value = json.loads(line)
            if value['event'] == wanted:
                return value
    raise TimeoutError(f'client did not send {wanted}')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before', type=Path, required=True)
    p.add_argument('--after', type=Path, required=True)
    p.add_argument('--before-wlroots', type=Path, required=True)
    p.add_argument('--after-wlroots', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--renderer', choices=['vulkan', 'pixman'], default='vulkan')
    p.add_argument('--seconds', type=float, default=4)
    p.add_argument('--repetitions', type=int, default=5)
    p.add_argument('--workload', action='append', choices=['idle', 'scene', 'empty', 'subsurface', 'subsurface-scene'])
    p.add_argument('--verify-capture', action='store_true', help='Separate correctness run: verify synchronized tile colors with grim after measuring')
    p.add_argument('--children', type=int, choices=[1, 8, 32, 64], default=8)
    p.add_argument('--topology', choices=['flat', 'nested'], default='flat')
    p.add_argument('--timing', choices=['none', 'unused', 'deadline'], default='none')
    p.add_argument('--compositor-cpus', default='4,5,6,7')
    p.add_argument('--client-cpus', default='8')
    args = p.parse_args()
    assert 0 < args.seconds < 60 and args.repetitions > 0
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    print(f'Artifacts: {out}', flush=True)
    cpu_set = lambda raw: set(map(int, raw.split(',')))
    compositor_cpus, client_cpus = cpu_set(args.compositor_cpus), cpu_set(args.client_cpus)
    assert not compositor_cpus & client_cpus
    assert (compositor_cpus | client_cpus) <= os.sched_getaffinity(0)
    builds = {'before': (args.before.resolve(), args.before_wlroots.resolve()),
              'after': (args.after.resolve(), args.after_wlroots.resolve())}
    metadata = dict(arguments=vars(args), platform=platform.platform(),
                    cpu=Path('/proc/cpuinfo').read_text(),
                    build_hashes={label: {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in (exe, prefix / 'lib/libwlroots-0.20.so')}
                                  for label, (exe, prefix) in builds.items()})
    out.joinpath('metadata.json').write_text(json.dumps(metadata, default=str, indent=2))
    definitions = {'xdg-shell': 'stable/xdg-shell/xdg-shell.xml',
                   'presentation-time': 'stable/presentation-time/presentation-time.xml',
                   'commit-timing-v1': 'staging/commit-timing/commit-timing-v1.xml'}
    proto_root = Path(subprocess.check_output(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols'], text=True).strip())
    generated = []
    for name, xml in definitions.items():
        subprocess.run(['wayland-scanner', 'client-header', proto_root / xml, out / f'{name}-client-protocol.h'], check=True)
        code = out / f'{name}.c'
        subprocess.run(['wayland-scanner', 'private-code', proto_root / xml, code], check=True)
        generated.append(code)
    subprocess.run(['cc', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', f'-I{out}',
                    ROOT / 'scripts/fixtures/benchmark-commit-timing.c', *generated,
                    '-lwayland-client', '-o', out / 'client'], check=True)
    results = []
    for workload in args.workload or ['idle', 'scene', 'empty', 'subsurface']:
        for repetition in range(args.repetitions):
            # Pair adjacent old/new runs and reverse order on alternate pairs.
            for label in (['before', 'after'] if repetition % 2 == 0 else ['after', 'before']):
                exe, prefix = builds[label]
                trial = out / f'{workload}-{repetition + 1}-{label}'
                trial.mkdir()
                runtime = trial / 'runtime'; runtime.mkdir(mode=0o700)
                env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))
                       and k not in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD')}
                for directory in ['home', 'config', 'cache', 'state']:
                    (trial / directory).mkdir()
                env.update(HOME=str(trial / 'home'), XDG_RUNTIME_DIR=str(runtime),
                           XDG_CONFIG_HOME=str(trial / 'config'), XDG_CACHE_HOME=str(trial / 'cache'),
                           XDG_STATE_HOME=str(trial / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1',
                           WLR_RENDERER=args.renderer, WLR_SCENE_DISABLE_DIRECT_SCANOUT='1',
                           LD_LIBRARY_PATH=str(prefix / 'lib'), AQUEOUS_RENDER_METRICS='1',
                           AQUEOUS_RENDER_GPU_METRICS='0')
                for name in ['CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT']:
                    path = trial / f'{name.lower()}.toml'; path.write_text('')
                    env[f'AQUEOUS_{name}'] = str(path)
                (trial / 'config.toml').write_text('''[layout]
gaps_outer = 0
gaps_inner = 0
border_width = 0
[blur]
enabled = false
[opacity]
enabled = false
[input]
focus_follows_mouse = false
''')
                children = []
                with (trial / 'compositor.log').open('w') as log, (trial / 'client.log').open('w') as client_log:
                    try:
                        compositor = subprocess.Popen([exe, '-no-xwayland', '-log-level', 'info', '-c', 'true'],
                            env=env, stdout=log, stderr=log, start_new_session=True,
                            preexec_fn=lambda: os.sched_setaffinity(0, compositor_cpus))
                        children.append(compositor)
                        end = time.monotonic() + 10
                        while not (runtime / 'aqueous/outputd.sock').exists():
                            assert compositor.poll() is None, 'compositor exited during startup'
                            assert time.monotonic() < end, 'no output socket'
                            time.sleep(.02)
                        def request(value):
                            with socket.socket(socket.AF_UNIX) as sock:
                                sock.settimeout(5); sock.connect(str(runtime / 'aqueous/outputd.sock'))
                                sock.sendall(json.dumps(value).encode() + b'\n')
                                result = json.loads(sock.makefile().readline())
                            assert result['ok'], result
                            return result
                        output_name = request({'op': 'list'})['outputs'][0]['name']
                        request({'op': 'set', 'changes': [{'name': output_name, 'mode': '1280x720@120'}]})
                        env['WAYLAND_DISPLAY'] = next(path.name for path in runtime.glob('wayland-*') if path.is_socket())
                        time.sleep(.3)
                        maps = Path(f'/proc/{compositor.pid}/maps').read_text()
                        assert str(prefix / 'lib/libwlroots-0.20.so') in maps, 'wrong wlroots loaded'
                        (trial / 'maps.txt').write_text(maps)
                        client = None
                        if workload != 'idle':
                            client = subprocess.Popen([out / 'client', workload, str(args.seconds), str(args.children), args.topology, args.timing], env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=client_log, text=True,
                                start_new_session=True, preexec_fn=lambda: os.sched_setaffinity(0, client_cpus))
                            children.append(client)
                            event(client, 'ready', 10)
                            client.stdin.write('w\n'); client.stdin.flush()
                            event(client, 'warmup', 5)
                        else:
                            time.sleep(1)
                        time.sleep(.2)
                        log_start = (trial / 'compositor.log').stat().st_size
                        before = snapshot(compositor.pid)
                        if client:
                            client.stdin.write('g\n'); client.stdin.flush()
                            sample = event(client, 'result', args.seconds + 10)
                        else:
                            time.sleep(args.seconds)
                            sample = {}
                        after = snapshot(compositor.pid)
                        if workload in ('scene', 'subsurface-scene'):
                            assert sample['presented'] > 0 and sample['commits'] > 0, 'rendered workload stalled'
                        assert compositor.poll() is None
                        elapsed = (after['wall_ns'] - before['wall_ns']) / 1e9
                        assert before['tids'] == after['tids'], 'worker threads changed during measurement'
                        cpu = (after['runtime_ns'] - before['runtime_ns']) / 1e9
                        lines = (trial / 'compositor.log').read_text()[log_start:]
                        prep = [int(v) / 1e6 for v in re.findall(r'kind=scene .*?pre_render_ns=(\d+)', lines)]
                        intervals = [n / 1e6 for n in sample.get('intervals_ns', [])]
                        latency = [n / 1e6 for n in sample.get('latencies_ns', [])]
                        actual = sample.get('elapsed_ns', int(elapsed * 1e9)) / 1e9
                        value = dict(build=label, workload=workload, repetition=repetition + 1,
                            elapsed_s=elapsed, cpu_percent=cpu / elapsed * 100,
                            tick_cpu_percent=(after['cpu_s'] - before['cpu_s']) / elapsed * 100,
                            main_voluntary_switches_per_s=(after['main_voluntary'] - before['main_voluntary']) / elapsed,
                            voluntary_switches_per_s=(after['voluntary'] - before['voluntary']) / elapsed,
                            involuntary_switches_per_s=(after['involuntary'] - before['involuntary']) / elapsed,
                            rss_mib=after['rss_kib'] / 1024, threads=len(after['tids']),
                            commits_per_s=sample.get('commits', 0) / actual,
                            transactions_per_s=sample.get('transactions', 0) / actual,
                            cpu_ns_per_commit=cpu * 1e9 / sample['commits'] if sample.get('commits') else None,
                            presented_fps=sample.get('presented', 0) / actual,
                            interval_median_ms=percentile(intervals, .5), interval_p95_ms=percentile(intervals, .95), interval_p99_ms=percentile(intervals, .99),
                            latency_median_ms=percentile(latency, .5), latency_p95_ms=percentile(latency, .95), latency_p99_ms=percentile(latency, .99),
                            cpu_ns_per_frame=cpu * 1e9 / sample['presented'] if sample.get('presented') else None,
                            prepare_median_ms=percentile(prep, .5), prepare_p95_ms=percentile(prep, .95),
                            scene_frames=len(prep), sample=sample, start=before, end=after)
                        (trial / 'result.json').write_text(json.dumps(value, indent=2))
                        if args.verify_capture:
                            assert workload == 'subsurface-scene'
                            from PIL import Image
                            capture = trial / 'capture.png'
                            subprocess.run(['grim', '-o', output_name, str(capture)], env=env, check=True, timeout=5,
                                           stdout=client_log, stderr=client_log)
                            pixels = Image.open(capture).convert('RGB')
                            columns = min(args.children, 8); rows = args.children // columns
                            colors = [pixels.getpixel((int((i % columns + .5) * 1280 / columns),
                                                       int((i // columns + .5) * 720 / rows)))
                                      for i in range(args.children)]
                            assert len({c[0] for c in colors}) == 1, colors
                            for i, color in enumerate(colors):
                                assert color[1:] == (i + 1 + (args.topology == 'nested'), 0x55), colors
                            value['capture_colors'] = colors
                            (trial / 'result.json').write_text(json.dumps(value, indent=2))
                        if client:
                            client.stdin.write('q\n'); client.stdin.flush()
                            cleanup = event(client, 'cleanup', 5)
                            assert cleanup['buffers_released']
                            assert client.wait(timeout=5) == 0
                        results.append(value)
                        out.joinpath('results.json').write_text(json.dumps(results, indent=2))
                        print(f'{workload} {repetition + 1} {label}: CPU={value["cpu_percent"]:.2f}% '
                              f'commits/s={value["commits_per_s"]:.0f} FPS={value["presented_fps"]:.2f} '
                              f'voluntary/s={value["voluntary_switches_per_s"]:.1f}', flush=True)
                    finally:
                        for child in reversed(children):
                            if child.poll() is None:
                                os.killpg(child.pid, signal.SIGTERM)
                                try:
                                    child.wait(timeout=3)
                                except subprocess.TimeoutExpired:
                                    os.killpg(child.pid, signal.SIGKILL); child.wait()
                            if child.stdin: child.stdin.close()
                            if child.stdout: child.stdout.close()
    summary = {}
    keys = ['cpu_percent', 'main_voluntary_switches_per_s', 'voluntary_switches_per_s', 'commits_per_s', 'transactions_per_s',
            'cpu_ns_per_commit', 'presented_fps', 'interval_median_ms', 'interval_p95_ms',
            'latency_median_ms', 'latency_p95_ms', 'latency_p99_ms', 'interval_p99_ms', 'cpu_ns_per_frame', 'prepare_median_ms', 'prepare_p95_ms', 'rss_mib']
    for workload in dict.fromkeys(v['workload'] for v in results):
        summary[workload] = {}
        for label in builds:
            rows = [v for v in results if v['workload'] == workload and v['build'] == label]
            summary[workload][label] = {}
            for key in keys:
                values = [v[key] for v in rows if v[key] is not None]
                if values:
                    summary[workload][label][key] = dict(median=statistics.median(values), minimum=min(values), maximum=max(values))
    out.joinpath('summary.json').write_text(json.dumps(summary, indent=2))
    print(f'Complete: {out / "summary.json"}', flush=True)


if __name__ == '__main__':
    main()
