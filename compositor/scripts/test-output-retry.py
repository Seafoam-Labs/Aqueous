#!/usr/bin/env python3
"""Inject output failures in a private two-output compositor; retain all artifacts.

Requires a build with -Doutput-retry-testing=true. No live-session input or
configuration is changed. Recovery is observed before any screenshot request.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--negative-control', action='store_true')
    parser.add_argument('--negative-stage', choices=('scene_build', 'output_commit'), default='scene_build')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-output-retry-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, files, results = [], [], []

    def run(command, timeout=20):
        return subprocess.check_output([str(v) for v in command], env=env, text=True, stderr=subprocess.STDOUT, timeout=timeout)

    def launch(command, label):
        out = (work / f'{label}.jsonl').open('w')
        err = (work / f'{label}.log').open('w')
        files.extend((out, err))
        child = subprocess.Popen([str(v) for v in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, description, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert compositor.poll() is None, 'private compositor exited'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(description)

    def events(label):
        values = []
        for line in (work / f'{label}.jsonl').read_text().splitlines():
            try:
                values.append(json.loads(line))
            except ValueError:
                pass
        return values

    def latest(label, event='sample'):
        return next((v for v in reversed(events(label)) if v['event'] == event), None)

    def request(**data):
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(str(runtime / 'aqueous/outputd.sock'))
            client.sendall(json.dumps(data).encode() + b'\n')
            with client.makefile('r') as response:
                value = json.loads(response.readline())
        assert value.get('ok'), value
        return value

    def status(**extra):
        value = request(op='test_output_retry', name=names[0], **extra)
        samples.write(json.dumps(value) + '\n')
        samples.flush()
        return value

    def arm(stage, count, disabled=False, overlay=False):
        return status(action='arm', stage=stage, count=count, disable_retry=disabled, simulate_overlay=overlay)

    def draw():
        previous = latest('target', 'submitted')['frame']
        target.stdin.write(b'd')
        target.stdin.flush()
        return wait(lambda: (v := latest('target', 'submitted')) and v['frame'] > previous and v,
                    'target did not submit one frame')['frame']

    def snapshot(label):
        (work / f'{label}-scene.txt').write_text(run([args.ctl.resolve(), 'scene']))

    def verify_pixels(frame, label):
        # Only call after passive presentation/recovery confirmation. Screencopy
        # itself can schedule a repaint, so it cannot establish recovery.
        path = work / f'{label}.png'
        run(['grim', '-o', names[0], path])
        with Image.open(path) as image:
            actual = image.convert('RGB').getpixel((image.width // 4, image.height // 4))
        expected = (32, 64, 96) if frame % 2 else (224, 48, 112)
        assert all(abs(a - b) <= 2 for a, b in zip(actual, expected)), (actual, expected)
        time.sleep(.05)

    def memory_kb():
        state = Path(f'/proc/{compositor.pid}/status').read_text()
        return sum(int(line.split()[1]) for line in state.splitlines() if line.startswith(('VmRSS:', 'VmSwap:')))

    try:
        (work / 'run.json').write_text(json.dumps(vars(args), default=str, indent=2))
        (work / 'binaries.json').write_text(json.dumps({str(p.resolve()): hashlib.sha256(p.read_bytes()).hexdigest()
                                                      for p in (args.compositor, args.ctl)}, indent=2))
        definitions = {
            'xdg-shell': Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml'),
            'presentation-time': Path('/usr/share/wayland-protocols/stable/presentation-time/presentation-time.xml'),
        }
        generated = []
        for name, xml in definitions.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            generated.append(code)
        run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/output-retry.c', *generated, '-lwayland-client', '-o', work / 'client'])
        shell_definitions = {
            'xdg-activation': '/usr/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml',
            'shortcuts': '/usr/share/wayland-protocols/unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml',
            'virtual-keyboard': ROOT / 'protocol/upstream/virtual-keyboard-unstable-v1.xml',
            'layer-shell': ROOT / 'protocol/upstream/wlr-layer-shell-unstable-v1.xml',
            'session-lock': '/usr/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml',
            'aqueous-shell': ROOT / 'protocol/aqueous-shell-v1.xml',
            'ext-workspace': ROOT / 'protocol/upstream/ext-workspace-v1.xml',
            'pointer-constraints': '/usr/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml',
        }
        shell_generated = [generated[0]]
        for name, xml in shell_definitions.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code])
            shell_generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', f'-I{work}', ROOT / 'scripts/fixtures/shell-client.c',
             *shell_generated, '-lwayland-client', '-lxkbcommon', '-o', work / 'shell-client'])
        runtime = work / 'runtime'
        runtime.mkdir(mode=0o700)
        for name in ('home', 'config', 'cache', 'state'):
            (work / name).mkdir()
        env.update(XDG_RUNTIME_DIR=str(runtime), HOME=str(work / 'home'), XDG_CONFIG_HOME=str(work / 'config'),
                   XDG_CACHE_HOME=str(work / 'cache'), XDG_STATE_HOME=str(work / 'state'),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER=args.renderer,
                   WLR_SCENE_DISABLE_DIRECT_SCANOUT='1')
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'
            path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        (work / 'config.toml').write_text('''[layout]
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
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'info', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no socket')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        names = [o['name'] for o in request(op='list')['outputs']]
        assert len(names) == 2
        request(op='set', changes=[dict(name=names[0], mode='1280x720@180', position=[0, 0]),
                                   dict(name=names[1], mode='960x540@60', position=[1280, 0])])
        samples = (work / 'retry-samples.jsonl').open('w')
        files.append(samples)
        status()  # Fail clearly when fault injection was not compiled in.
        sidecar = launch([work / 'client', 'aqueous.retry-sidecar', names[1], '1'], 'sidecar')
        wait(lambda: latest('sidecar', 'presented'), 'sidecar did not present')
        target = launch([work / 'client', 'aqueous.retry-target', names[0], '0'], 'target')
        wait(lambda: latest('target', 'presented'), 'target did not present')
        time.sleep(.3)

        def recovered(previous_failures, expected_failures, frame, timeout=5):
            def check():
                s = status()
                r = s['retry']
                return s if (r['total_failures'] >= previous_failures + expected_failures and not r['pending']
                             and r['recovery_commit'] is None and r['presented_commit'] is not None) else None
            s = wait(check, 'no autonomous commit/presentation recovery', timeout)
            wait(lambda: any(v['event'] == 'presented' and v['frame'] == frame for v in events('target')),
                 'client frame did not receive presentation feedback')
            assert latest('target', 'submitted')['frame'] == frame, 'client committed again during recovery'
            assert not s['timer_armed'] and s['render_locks'] == 0, s
            return s

        if args.negative_control:
            before = arm(args.negative_stage, 1, True)['retry']['total_failures']
            frame = draw()
            recovered(before, 1, frame, timeout=1)
            raise AssertionError('negative control unexpectedly recovered')

        for stage, count in [('scene_build', 1), ('output_commit', 1), ('output_commit', 4)]:
            label = f'{stage}-{count}'
            before = arm(stage, count)['retry']['total_failures']
            frame = draw()
            s = recovered(before, count, frame)
            snapshot(label)
            verify_pixels(frame, label)
            results.append(dict(case=label, passed=True, state=s))
            print(f'PASS {label}: one client commit recovered autonomously', flush=True)

        # Model the promotion branch without claiming real DRM plane coverage.
        before = arm('output_commit', 1, overlay=True)['retry']['total_failures']
        frame = draw()
        wait(lambda: any(v['event'] == 'presented' and v['frame'] == frame for v in events('target')), 'fallback did not present')
        assert status()['retry']['total_failures'] == before, 'immediate successful fallback scheduled delayed recovery'
        for stage in ('fallback_build', 'fallback_commit'):
            before = arm(stage, 1, overlay=True)['retry']['total_failures']
            frame = draw()
            recovered(before, 1, frame)
        results.append(dict(case='overlay-fallback-control-flow', passed=True))
        print('PASS overlay fallback control flow: immediate success and both failure stages', flush=True)

        before = arm('output_commit', -1)['retry']['total_failures']
        frame = draw()
        wait(lambda: status()['retry']['failures'] >= 8, 'backoff did not reach cap')
        first = status()
        memory_first = memory_kb()
        side_first = latest('sidecar')['presented']
        end = time.monotonic() + 3.2
        while time.monotonic() < end:
            s = status()
            assert s['retry']['pending'] and s['render_locks'] == 0
            time.sleep(.05)
        last = status()
        attempts = last['retry']['total_failures'] - first['retry']['total_failures']
        assert 2 <= attempts <= 4, f'unbounded/stalled capped retries: {attempts}'
        assert latest('sidecar')['presented'] - side_first > 40, 'second output stalled'
        memory_growth = memory_kb() - memory_first
        assert memory_growth < 64 * 1024, f'retry resource growth: {memory_growth} KiB'
        arm('output_commit', 0)  # Clearing injection must not schedule a frame.
        recovered(before, 8, frame, timeout=2)
        snapshot('persistent-recovered')
        results.append(dict(case='persistent', passed=True, attempts=attempts))
        print('PASS persistent failure: bounded retries, healthy second output, autonomous recovery', flush=True)

        # Repeated damage must not shorten or perpetually postpone backoff.
        arm('scene_build', -1)
        frame = draw()
        wait(lambda: status()['retry']['failures'] >= 8, 'storm did not reach capped backoff')
        first = status()
        end = time.monotonic() + 1.3
        while time.monotonic() < end:
            frame = draw()
            time.sleep(.025)
        last = status()
        assert 1 <= last['retry']['total_failures'] - first['retry']['total_failures'] <= 2
        arm('scene_build', 0)
        recovered(first['retry']['total_failures'], 1, frame, timeout=2)
        verify_pixels(frame, 'damage-storm')
        results.append(dict(case='damage-during-backoff', passed=True))
        print('PASS new damage respects backoff and latest content is recovered', flush=True)

        # Lock confirmation must wait for presentation on the failing output.
        arm('output_commit', -1)
        draw()
        wait(lambda: status()['retry']['failures'] >= 8, 'lock case did not reach backoff')
        locker = launch([work / 'shell-client', 'lock'], 'locker')
        wait(lambda: 'ready' in (work / 'locker.jsonl').read_text(), 'locker not ready')
        time.sleep(.25)
        assert not status()['session_locked'], 'lock confirmed despite failed commits'
        arm('output_commit', 0)
        wait(lambda: status()['session_locked'], 'lock did not confirm after presentation', timeout=3)
        assert 'locked' in (work / 'locker.jsonl').read_text()
        arm('scene_build', -1)
        status(action='damage')
        wait(lambda: status()['retry']['pending'], 'unlock case did not fail')
        locker.stdin.write(b'unlock\n')
        locker.stdin.flush()
        wait(lambda: not status()['session_locked'], 'unlock not processed')
        arm('scene_build', 0)
        wait(lambda: not status()['retry']['pending'], 'unlock recovery did not commit')
        time.sleep(.2)
        results.append(dict(case='lock-unlock-during-recovery', passed=True))
        print('PASS lock confirmation and unlock recovery use current scene state', flush=True)

        # A successful disable cancels recovery; enable starts a fresh frame.
        arm('scene_build', -1)
        draw()
        wait(lambda: status()['retry']['pending'], 'no failure before disable')
        request(op='set', changes=[dict(name=names[0], enabled=False)])
        disabled = wait(lambda: (s := status()) and not s['retry']['pending'] and s, 'retry not cancelled on disable')
        assert not disabled['timer_armed']
        count = disabled['retry']['total_failures']
        time.sleep(.2)
        assert status()['retry']['total_failures'] == count
        arm('scene_build', 0)
        request(op='set', changes=[dict(name=names[0], enabled=True)])
        wait(lambda: status()['commit_seq'] > disabled['commit_seq'], 're-enable did not commit')
        time.sleep(.2)
        arm('scene_build', -1)
        draw()
        wait(lambda: status()['retry']['pending'], 'no failure before reconfigure')
        arm('scene_build', 0)
        request(op='set', changes=[dict(name=names[0], mode='1280x720@144')])
        wait(lambda: not status()['retry']['pending'], 'reconfiguration did not cancel old retry')
        time.sleep(.2)
        arm('scene_build', -1)
        draw()
        wait(lambda: status()['retry']['pending'], 'no failure before destroy')
        request(op='test_output_retry', name=names[0], action='destroy')
        time.sleep(.2)
        assert compositor.poll() is None
        assert len(request(op='list')['outputs']) == 1
        results.append(dict(case='disable-reconfigure-destroy', passed=True))
        print('PASS lifecycle: disable, reconfigure and destroy with armed recovery', flush=True)
        (work / 'result.json').write_text(json.dumps(dict(passed=True, cases=results), indent=2))
        return 0
    except Exception as error:
        if 'compositor' in locals() and compositor.poll() is None:
            try:
                snapshot('failure')
            except Exception:
                pass
        (work / 'result.json').write_text(json.dumps(dict(passed=False, error=str(error), cases=results), indent=2))
        print(f'FAIL: {error}\nArtifacts: {work}', flush=True)
        return 1
    finally:
        for child in reversed(children):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for child in reversed(children):
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
            child.stdin.close()
        for file in files:
            file.close()


if __name__ == '__main__':
    raise SystemExit(main())
