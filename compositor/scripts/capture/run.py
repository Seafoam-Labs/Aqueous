#!/usr/bin/env python3
"""Private compositor + portal + PipeWire capture experiments; no session service changes."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
COMPOSITOR = HERE.parents[1]
VARIANTS = {
    'baseline': {}, 'implicit-only': {'implicit_only': True}, 'buffers4': {'buffers': 4}, 'buffers8': {'buffers': 8},
    'hold1': {'hold': 1}, 'hold2': {'hold': 2}, 'hold4': {'hold': 4}, 'fps30': {'fps': 30},
    'full-copy': {'AQUEOUS_CAPTURE_FULL_COPY': '1'},
    'full-metadata': {'AQUEOUS_CAPTURE_FULL_METADATA': '1'},
    'full-redraw': {'WLR_SCENE_DEBUG_DAMAGE': 'rerender', 'AQUEOUS_CAPTURE_FULL_COPY': '1', 'AQUEOUS_CAPTURE_FULL_METADATA': '1'},
    'wait-source': {'AQUEOUS_CAPTURE_WAIT_SOURCE': '1'}, 'wait-copy': {'AQUEOUS_CAPTURE_WAIT_COPY': '1'},
    'shm': {'transport': 'shm', 'AQUEOUS_CAPTURE_FORCE_SHM': '1'},
    'no-overlay': {'overlay': False}, 'no-scanout': {'WLR_SCENE_DISABLE_DIRECT_SCANOUT': '1'},
    'no-planes': {'overlay': False, 'WLR_SCENE_DISABLE_DIRECT_SCANOUT': '1'},
    'wait-copy-buffers4': {'buffers': 4, 'AQUEOUS_CAPTURE_WAIT_COPY': '1'},
    'full-redraw-no-planes': {'overlay': False, 'WLR_SCENE_DISABLE_DIRECT_SCANOUT': '1', 'WLR_SCENE_DEBUG_DAMAGE': 'rerender', 'AQUEOUS_CAPTURE_FULL_COPY': '1', 'AQUEOUS_CAPTURE_FULL_METADATA': '1'},
    'bad-metadata': {'AQUEOUS_CAPTURE_BAD_METADATA': '1'},
    'mixed': {'fault': 'mixed'}, 'stale': {'fault': 'stale'}, 'missing': {'fault': 'missing'},
}
MATRIX = ['baseline', 'buffers4', 'buffers8', 'hold1', 'hold2', 'hold4', 'fps30',
          'full-copy', 'full-metadata', 'full-redraw', 'wait-source', 'wait-copy', 'shm',
          'no-overlay', 'no-scanout', 'no-planes', 'wait-copy-buffers4', 'full-redraw-no-planes']


def traces(directory):
    rows, invalid = [], 0
    for path in sorted(directory.glob('*.jsonl')):
        if path.name.startswith(('compositor', 'consumer', 'fixture', 'portal')):
            for line in path.read_bytes().splitlines():
                line = line.strip(b'\0 \t\r')
                if not line:
                    continue
                try:
                    row = json.loads(line)
                    row['unit'] = path.stem
                    rows.append(row)
                except (ValueError, UnicodeDecodeError):
                    invalid += 1
    return sorted(rows, key=lambda r: r.get('ns', 0)), invalid


def analyze(directory, summary, backend, variant):
    rows, invalid = traces(directory / 'trace')
    counts = Counter(r['event'] for r in rows)
    required = ('client_commit', 'copy_begin', 'frame_ready', 'queue', 'acquire', 'read_complete')
    missing_trace = [event for event in required if not counts[event]]
    clipped = bool(counts['trace_overflow'] or invalid or missing_trace)
    valid = (summary.get('frames', 0) >= 10 and not summary.get('failed') and not clipped
             and summary.get('tail_gap_ns', 0) <= 500_000_000)
    bad = bool(summary.get('bad_frames') or summary.get('metadata_bad') or summary.get('regressions'))
    starvation = [r for r in rows if r['event'] == 'dequeue_empty']
    dequeues = [r for r in rows if r['event'] == 'dequeue']
    recovery = [next((r['ns'] - e['ns'] for r in dequeues if r['ns'] > e['ns']), None) for e in starvation]
    active = set()
    plane_violations = []
    acquired = set()
    ownership_errors = []
    for row in rows:
        event = row['event']
        if event == 'capture_start': active.add(row['a'])
        if event == 'capture_stop': active.discard(row['a'])
        if row['a'] in active and ((event == 'scanout_result' and row['c'] == 2) or
                (event == 'committed_layer' and row['b'] and row['c'])):
            plane_violations.append(row)
        if row['unit'].startswith('consumer'):
            key = (row['unit'], row['a'])
            if event == 'acquire':
                if key in acquired: ownership_errors.append(row)
                acquired.add(key)
            if event == 'release': acquired.discard(key)
            if event == 'held_removed': ownership_errors.append(row)
    scanout = any(r['event'] == 'scanout_result' and r['c'] == 2 for r in rows)
    layers = any(r['event'] == 'committed_layer' and r['b'] and r['c'] for r in rows)
    statuses = {
        'scheduling': 'not reproduced under tested conditions' if valid and not ownership_errors and all(v is not None for v in recovery) else 'inconclusive',
        'synchronization': 'not exercised' if summary.get('transport') != 'dmabuf' else 'inconclusive' if bad or not valid else 'not reproduced under tested conditions',
        'damage': 'inconclusive' if bad or not valid or summary.get('metadata_seen', 0) < 2 else 'not reproduced under tested conditions',
        'planes': 'not exercised' if backend != 'drm' or not (scanout or layers) else 'inconclusive' if not valid or bad or plane_violations or counts['capture_stop'] < 20 else 'not reproduced under tested conditions',
    }
    # A pixel failure establishes corruption, not automatically its cause.
    # Confirmation requires the A/B/A trace analysis described in the plan.
    result = {'variant': variant, 'statuses': statuses, 'consumer': summary,
              'trace_events': dict(counts), 'trace_incomplete': clipped, 'missing_trace_events': missing_trace,
              'ownership_errors': ownership_errors, 'plane_lock_violations': plane_violations,
              'starvation_recovery_ns': recovery, 'scanout_exercised': scanout,
              'overlay_exercised': layers, 'unexpected_pixels': bad,
              'attribution': 'No root cause is inferred solely from an override suppressing corruption.'}
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


class Session:
    def __init__(self, directory, env):
        self.directory, self.env, self.children, self.files = directory, env, [], []

    def launch(self, command, label, extra_env=None):
        log = (self.directory / f'{label}.log').open('w')
        self.files.append(log)
        p = subprocess.Popen(list(map(str, command)), env=self.env | (extra_env or {}), stdin=subprocess.PIPE,
                             stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.children.append(p)
        return p

    def run(self, command, timeout=20):
        return subprocess.check_output(list(map(str, command)), env=self.env, text=True,
                                       stderr=subprocess.STDOUT, timeout=timeout)

    def wait(self, predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            dead = [(p.pid, p.returncode) for p in self.children if p.poll() is not None]
            if dead:
                raise RuntimeError(f'{message}: child exited {dead}; see {self.directory}')
            time.sleep(.02)
        raise TimeoutError(message)

    def close(self):
        for p in reversed(self.children):
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGTERM)
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL); p.wait()
        for f in self.files:
            f.close()


def request_output(runtime, **request):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(3); s.connect(str(runtime / 'aqueous/outputd.sock'))
        s.sendall(json.dumps(request).encode() + b'\n')
        with s.makefile('r') as f:
            result = json.loads(f.readline())
    if not result.get('ok'):
        raise RuntimeError(result)
    return result


def experiment(args, directory, variant):
    started_utc = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    opts = VARIANTS[variant]
    directory.mkdir()
    for name in ('runtime', 'home', 'config', 'cache', 'state', 'trace'):
        (directory / name).mkdir(mode=0o700)
    runtime = directory / 'runtime'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_', 'PIPEWIRE_'))}
    host_runtime, host_display = env.get('XDG_RUNTIME_DIR'), env.get('WAYLAND_DISPLAY')
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD'):
        env.pop(key, None)
    env.update(HOME=str(directory / 'home'), XDG_RUNTIME_DIR=str(runtime),
               XDG_CONFIG_HOME=str(directory / 'config'), XDG_CACHE_HOME=str(directory / 'cache'),
               XDG_STATE_HOME=str(directory / 'state'), AQUEOUS_CAPTURE_TRACE_DIR=str(directory / 'trace'),
               WLR_RENDERER='vulkan', WLR_RENDER_DRM_DEVICE=args.render_node,
               LD_LIBRARY_PATH=str(args.build / 'wlroots/lib'), AQUEOUS_OVERLAY_TRACE_BUDGET='1000')
    if args.no_trace:
        env.pop('AQUEOUS_CAPTURE_TRACE_DIR', None)
    if args.production_wlroots:
        env['LD_LIBRARY_PATH'] = str(args.production_wlroots.resolve())
    env.update({k: v for k, v in opts.items() if k.startswith(('AQUEOUS_', 'WLR_'))})
    for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
        p = directory / f'{name.lower()}.toml'; p.write_text(''); env[f'AQUEOUS_{name}'] = str(p)
    (directory / 'config.toml').write_text('''[layout]
gaps_outer = 0
gaps_inner = 0
border_width = 0
[opacity]
enabled = false
[blur]
enabled = false
[input]
focus_follows_mouse = false
''')
    (directory / 'rules.toml').write_text('''[[rule]]
app_id = "aqueous.capture-pattern"
overlay_plane = "prefer"
blur = false
opacity = 1.0
''')
    session = Session(directory, env)
    results = []
    try:
        session.launch(['dbus-daemon', '--session', '--nofork', '--print-address=1'], 'dbus')
        env['DBUS_SESSION_BUS_ADDRESS'] = session.wait(lambda: next((s for s in (directory / 'dbus.log').read_text().splitlines() if s.startswith('unix:')), None), 'private D-Bus socket')
        pw_config = directory / 'pipewire.conf'
        pw_config.write_text('''context.properties = { core.daemon = true core.name = pipewire-0 }
context.spa-libs = { support.* = support/libspa-support }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-adapter }
 { name = libpipewire-module-link-factory }
 { name = libpipewire-module-access args = { access.force = unrestricted } }
]
''')
        session.launch(['pipewire', '-c', pw_config], 'pipewire')
        session.wait(lambda: (runtime / 'pipewire-0').is_socket(), 'private PipeWire socket')
        if args.backend == 'nested':
            if not host_runtime or not host_display:
                raise RuntimeError('nested backend requires a host Wayland display')
            env['WAYLAND_DISPLAY'] = str(Path(host_runtime) / host_display)
            env['WLR_BACKENDS'] = 'wayland'
            env['WLR_WL_OUTPUTS'] = '2' if args.dual else '1'
        elif args.backend == 'headless':
            env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2' if args.dual else '1')
        else:
            env['WLR_BACKENDS'] = 'drm,libinput'
        overlay = opts.get('overlay', args.overlay)
        compositor_command = [args.compositor, '-no-xwayland', '-log-level', 'info',
                              '-drm-overlay-planes' if overlay else '-no-drm-overlay-planes', '-c', 'true']
        fault_env = {}
        if args.sync_fault:
            fault_env = {'LD_PRELOAD': str(args.sync_fault_library),
                         'AQUEOUS_TEST_SYNC_FAULT': args.sync_fault,
                         'AQUEOUS_TEST_SYNC_FAULT_AFTER': str(args.sync_fault_after)}
        session.launch(compositor_command, 'compositor', fault_env)
        env['WAYLAND_DISPLAY'] = session.wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'private compositor socket')
        session.wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'output service')
        outputs = request_output(runtime, op='list')['outputs']
        names = [o['name'] for o in outputs]
        selected = args.output or names[0]
        if args.backend != 'drm':
            changes = [dict(name=selected, mode=f'{args.width}x{args.height}@180', position=[0, 0])]
            if args.dual and len(names) > 1:
                changes.append(dict(name=names[1], mode='1920x1080@60', position=[args.width, 0]))
            request_output(runtime, op='set', changes=changes)
        cfg = directory / 'portal.conf'
        cfg.write_text(f'[screencast]\nchooser_type=none\noutput_name={selected}\nmax_fps={opts.get("fps", args.fps)}\n')
        session.launch([args.build / 'portal', '-c', cfg, '-l', 'DEBUG'], 'portal')
        dest = 'org.freedesktop.impl.portal.desktop.wlr' if args.unrenamed else 'org.freedesktop.impl.portal.desktop.aqueous'
        base = ['gdbus', 'call', '--session', '--dest', dest, '--object-path', '/org/freedesktop/portal/desktop', '--method']
        session.wait(lambda: 'wayland: registry listeners run' in (directory / 'portal.log').read_text(), 'portal registry')
        producer = session.launch([args.build / 'fixture', '--output', selected, '--fps', '180', '--seconds', str((args.seconds + 5) * args.cycles + 30),
                                   *(['--sparse'] if args.sparse else []), *(['--gpu'] if args.gpu_fixture else []), '--fault', opts.get('fault', 'none')], 'fixture')
        time.sleep(1)
        for cycle in range(args.cycles):
            cycle_dir = directory / f'cycle-{cycle:02d}'; cycle_dir.mkdir()
            (cycle_dir / 'planes-before.json').write_text(session.run([args.ctl, 'overlay-planes', '--json']))
            handle = f'/org/freedesktop/portal/desktop/session/capture/c{cycle}'
            req = f'/org/freedesktop/portal/desktop/request/capture/c{cycle}'
            for method, parameters in [('CreateSession', [req, handle, '', '{}']),
                                       ('SelectSources', [req, handle, '', "{'types': <uint32 1>, 'cursor_mode': <uint32 1>}"]),
                                       ('Start', [req, handle, '', '', '{}'])]:
                reply = session.run([*base, f'org.freedesktop.impl.portal.ScreenCast.{method}', *parameters])
                (cycle_dir / f'{method}.txt').write_text(reply)
                if not reply.startswith('(uint32 0,'):
                    raise RuntimeError(f'{method} failed: {reply}')
            match = re.search(r"'streams': <\[\(uint32 (\d+)", reply)
            if not match:
                raise RuntimeError(f'Cannot parse node ID: {reply}')
            command = [args.build / 'consumer', '--node', match[1], '--fps', str(opts.get('fps', args.fps)),
                       '--buffers', str(opts.get('buffers', args.buffers)), '--hold-periods', str(opts.get('hold', 0)),
                       '--seconds', str(args.seconds), '--transport', opts.get('transport', args.transport),
                       '--render-node', args.render_node, '--directory', cycle_dir, *(['--implicit-only'] if opts.get('implicit_only') else []), *(['--sparse'] if args.sparse else [])]
            consumer = session.launch(command, f'consumer-{cycle:02d}')
            time.sleep(min(.5, args.seconds / 4))
            (cycle_dir / 'planes-during.json').write_text(session.run([args.ctl, 'overlay-planes', '--json']))
            # Transition exercises intentionally invalidate a full-screen pixel
            # oracle; keep them separate from strict pixel comparison runs.
            if args.transitions:
                time.sleep(args.seconds / 3); producer.stdin.write(b'f'); producer.stdin.flush()
                time.sleep(args.seconds / 3); producer.stdin.write(b'f'); producer.stdin.flush()
            code = consumer.wait(timeout=args.seconds + 15)
            log = (directory / f'consumer-{cycle:02d}.log').read_text()
            summary = next((json.loads(s) for s in reversed(log.splitlines()) if s.startswith('{')), {})
            summary.update(exit_code=code, duration_seconds=args.seconds, requested_buffers=opts.get('buffers', args.buffers))
            summary['transport'] = ('dmabuf' if summary.get('dmabuf_frames', 0) else
                                    'shm' if summary.get('shm_frames', 0) else 'unknown')
            if code == 77: summary['coverage'] = 'not exercised'
            results.append(summary)
            close = ['gdbus', 'call', '--session', '--dest', dest, '--object-path', handle, '--method', 'org.freedesktop.impl.portal.Session.Close']
            expected_stop = bool(args.sync_fault and cycle == 0 and
                'ext: frame capture failed: unknown reason' in (directory / 'portal.log').read_text())
            try:
                session.run(close)
            except subprocess.CalledProcessError:
                if not expected_stop:
                    raise
            summary['expected_capture_failure'] = expected_stop
            time.sleep(.2)
            (cycle_dir / 'planes-after.json').write_text(session.run([args.ctl, 'overlay-planes', '--json']))
            time.sleep(.2)
            if producer.poll() is not None: raise RuntimeError('Fixture exited during capture; see fixture.log')
            if code not in (0, 3, 77) and not (expected_stop and code == 4):
                raise RuntimeError(f'Consumer failed ({code}); see {directory}')
        if args.sync_fault:
            marker = f'AQUEOUS_SYNC_FAULT injected {args.sync_fault} occurrence={args.sync_fault_after}'
            if (directory / 'compositor.log').read_text().count(marker) != 1:
                raise RuntimeError('Requested synchronization injection did not fire exactly once')
            if not results[0].get('expected_capture_failure') or any(r.get('exit_code') != 0 for r in results[1:]):
                raise RuntimeError('Expected failed capture followed by successful new session was not observed')
        manifest = {'variant': variant, 'kernel': session.run(['uname', '-a']).strip(),
                    'pipewire_version': session.run(['pipewire', '--version']).strip(), 'options': vars(args) | opts, 'environment': {k: v for k, v in env.items() if k.startswith(('WLR_', 'AQUEOUS_', 'PIPEWIRE_'))},
                    'started_utc': started_utc, 'outputs_before': outputs, 'outputs_active': request_output(runtime, op='list'), 'compositor_command': compositor_command, 'cycles': results, 'fixture_transport': 'egl' if args.gpu_fixture else 'shm',
                    'binaries': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (args.compositor, args.build / 'portal', args.build / 'consumer', (args.production_wlroots or args.build / 'wlroots/lib') / 'libwlroots-0.20.so')},
                    'compositor_libraries': session.run(['ldd', args.compositor])}
        (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2, default=str) + '\n')
    finally:
        (directory / 'invocation.json').write_text(json.dumps({'started_utc': started_utc, 'arguments': vars(args), 'variant': variant, 'cycles': results}, indent=2, default=str) + '\n')
        session.close()
    summary = results[0] if len(results) == 1 else {
        key: sum(r.get(key, 0) for r in results) for key in ('frames','bad_frames','metadata_bad','metadata_seen','regressions')}
    if len(results) > 1:
        summary['failed'] = any(r.get('failed') or r.get('exit_code') not in (0, 3) for r in results)
        summary['transport'] = results[0].get('transport') if len({r.get('transport') for r in results}) == 1 else 'mixed'
    summary.setdefault('transport', 'unknown')
    if args.sync_fault:
        # First session is expected to stop. Qualify subsequent sessions using
        # the ordinary pixel/transport oracle; retain the failed session data.
        summary = results[-1].copy()
        for key in ('bad_frames', 'metadata_bad', 'regressions'):
            summary[key] = sum(r.get(key, 0) for r in results)
    result = analyze(directory, summary, args.backend, variant)
    if args.sync_fault:
        result['sync_fault'] = {'operation': args.sync_fault, 'injected': True,
                               'failed_session': results[0], 'recovered_sessions': results[1:]}
    if args.transitions:
        result['statuses']['planes'] = 'inconclusive' if args.backend == 'drm' and (result['scanout_exercised'] or result['overlay_exercised']) else 'not exercised'
        result['statuses']['damage'] = result['statuses']['synchronization'] = 'inconclusive'
        result['transition_note'] = 'Fullscreen geometry changes require inspection of saved frames; the fixed full-output pixel oracle is not valid while windowed.'
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build', type=Path, required=True)
    p.add_argument('--artifacts', type=Path)
    p.add_argument('--compositor', type=Path, default=COMPOSITOR / 'zig-out/bin/aqueous')
    p.add_argument('--ctl', type=Path, default=COMPOSITOR / 'zig-out/bin/aqueousctl')
    p.add_argument('--backend', choices=['headless','nested','drm'], default='headless')
    p.add_argument('--render-node', default='/dev/dri/renderD128')
    p.add_argument('--output')
    p.add_argument('--transport', choices=['shm','dmabuf','auto'], default='dmabuf')
    p.add_argument('--variant', choices=[*VARIANTS, 'matrix', 'controls'], default='baseline')
    p.add_argument('--seconds', type=int, default=60)
    p.add_argument('--repetitions', type=int, default=3)
    p.add_argument('--cycles', type=int, default=1)
    p.add_argument('--buffers', type=int, choices=[2,4,8], default=2)
    p.add_argument('--fps', type=int, choices=[30,60], default=60)
    p.add_argument('--width', type=int, default=2560)
    p.add_argument('--height', type=int, default=1440)
    p.add_argument('--dual', action='store_true')
    p.add_argument('--no-trace', action='store_true', help='Timing comparison only; cannot establish trace-based coverage')
    p.add_argument('--production-wlroots', type=Path, help='Library directory for an ordinary-build comparison')
    p.add_argument('--gpu-fixture', action='store_true')
    p.add_argument('--sparse', action='store_true')
    p.add_argument('--overlay', action='store_true')
    p.add_argument('--transitions', action='store_true')
    p.add_argument('--unrenamed', action='store_true')
    p.add_argument('--sync-fault', choices=['acquire-import', 'completion-export', 'capture-reject'])
    p.add_argument('--sync-fault-library', type=Path)
    p.add_argument('--sync-fault-after', type=int, default=30)
    args = p.parse_args()
    if args.sync_fault:
        if not args.sync_fault_library or not args.sync_fault_library.is_file() or args.sync_fault_after < 1:
            p.error('sync fault injection requires a built --sync-fault-library and positive occurrence')
        args.sync_fault_library = args.sync_fault_library.resolve()
        if args.cycles < 2:
            p.error('sync fault tests require --cycles 2 or more to verify a new capture session recovers')
    if not 1 <= args.seconds <= 3600 or not 1 <= args.repetitions <= 100 or not 1 <= args.cycles <= 100:
        p.error('invalid duration, repetitions, or cycles')
    if not 256 <= args.width <= 8192 or not 1 <= args.height <= 8192:
        p.error('invalid dimensions')
    for key in ('build','compositor','ctl'):
        setattr(args, key, getattr(args, key).resolve())
    root = args.artifacts.resolve() if args.artifacts else Path(tempfile.mkdtemp(prefix='aqueous-capture-results-'))
    if root.exists() and any(root.iterdir()):
        p.error(f'artifact directory is not empty: {root}')
    root.mkdir(parents=True, exist_ok=True)
    if args.backend == 'drm' and (os.environ.get('WAYLAND_DISPLAY') or os.environ.get('DISPLAY')):
        p.error('DRM tests require a separate TTY with no running desktop on that seat; use headless for an active desktop')
    if not Path(args.render_node).exists():
        (root / 'matrix.json').write_text(json.dumps({'status': 'not exercised', 'reason': f'{args.render_node} unavailable', 'hypotheses': ['scheduling','synchronization','damage','planes']}, indent=2))
        print(f'SKIP GPU unavailable; artifacts: {root}'); return 77
    variants = (MATRIX if args.variant == 'matrix' else ['mixed', 'stale', 'missing', 'bad-metadata']
                if args.variant == 'controls' else [args.variant])
    matrix = []; failures = False
    for rep in range(args.repetitions):
        # Separate original-baseline returns make masking and drift visible.
        order = [v for variant in variants for v in (['baseline', variant, 'baseline'] if variant != 'baseline' else ['baseline'])]
        for index, variant in enumerate(order):
            directory = root / f'{rep:02d}-{index:02d}-{variant}'
            print(f'RUN {variant}: {directory}', flush=True)
            try:
                result = experiment(args, directory, variant)
                if variant in ('mixed','stale','missing','bad-metadata'):
                    detected = result['consumer'].get('metadata_bad', 0) if variant == 'bad-metadata' else result['consumer'].get('bad_frames', 0)
                    result['negative_control_detected'] = bool(detected)
                    failures |= not detected
                else:
                    failures |= (result['unexpected_pixels'] or (result['trace_incomplete'] and not args.no_trace and not args.production_wlroots) or
                                 result['consumer'].get('frames', 0) < 10 or
                                 bool(result['ownership_errors']) or bool(result['plane_lock_violations']))
            except Exception as e:
                result = {'variant': variant, 'status': 'inconclusive', 'error': str(e)}
                directory.mkdir(exist_ok=True)
                (directory / 'error.json').write_text(json.dumps(result, indent=2)); failures = True
                print(f'ERROR {e}', flush=True)
            result['artifacts'] = str(directory); matrix.append(result)
            (root / 'matrix.json').write_text(json.dumps(matrix, indent=2) + '\n')
    print(f'Artifacts: {root}', flush=True)
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
