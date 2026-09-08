#!/usr/bin/env python3
"""Exercise basic mirroring in a private two-output compositor; retain artifacts.

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
    parser.add_argument('--validation', action='store_true', help='enable Vulkan validation layer')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-output-mirror-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, files, results = [], [], []
    if args.validation:
        env['VK_INSTANCE_LAYERS'] = 'VK_LAYER_KHRONOS_validation'

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
        return value

    def status(name=None, **extra):
        value = request(op='test_output_retry', name=name or names[1], **extra)
        assert value.get('ok'), value
        return value

    def draw():
        previous = latest('target', 'submitted')['frame']
        target.stdin.write(b'd')
        target.stdin.flush()
        return wait(lambda: (v := latest('target', 'submitted')) and v['frame'] > previous and v,
                    'target did not submit one frame')['frame']

    def snapshot(label):
        (work / f'{label}-scene.txt').write_text(run([args.ctl.resolve(), 'scene']))

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
        compositor = launch([args.compositor.resolve(), '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None), 'no socket')
        wait(lambda: (runtime / 'aqueous/outputd.sock').exists(), 'no output service')
        names = [o['name'] for o in request(op='list')['outputs']]
        assert len(names) == 2
        request(op='set', changes=[dict(name=names[0], mode='1280x720@240', position=[0, 0]),
                                   dict(name=names[1], mode='960x720@60', position=[1280, 0])])
        sidecar = launch([work / 'client', 'aqueous.mirror-destination', names[1], '1'], 'sidecar')
        wait(lambda: latest('sidecar', 'presented'), 'destination client did not present')
        target = launch([work / 'client', 'aqueous.mirror-source', names[0], '0'], 'target')
        wait(lambda: latest('target', 'presented'), 'source did not present')
        time.sleep(.2)
        def change(**fields):
            result = request(op='set', changes=[dict(name=names[1], **fields)])
            assert result.get('ok'), result
            time.sleep(.1)

        def pixels():
            return status(action='mirror_pixels')['mirror_pixels']

        def expect_color(frame):
            expected = 0x204060 if frame % 2 else 0xe03070
            def matches():
                p = pixels()
                return p[0] == expected and p[3:] == [0, 0]
            wait(matches, f'incorrect mirror content: {pixels()}', timeout=5)

        # Complete-graph validation must not change the existing output state.
        for fields in [dict(mirror_of=names[1]), dict(mirror_of=names[0], transform='90'),
                       dict(mirror_of=names[0], adaptive_sync=True)]:
            result = request(op='set', changes=[dict(name=names[1], **fields)])
            assert not result['ok'], result
        assert status()['policy_exposed']
        change(mirror_of=names[0])
        wait(lambda: status()['mirror_status'] == 'active', 'mirror did not become active')
        assert not status()['policy_exposed']
        discovery = json.loads(run([args.ctl.resolve(), 'outputs', '--json']))
        assert next(o for o in discovery if o['name'] == names[1])['mirror_of'] == names[0]
        windows = json.loads(run([args.ctl.resolve(), 'windows', '--json']))
        (work / 'windows-after-migration.json').write_text(json.dumps(windows, indent=2))
        assert 'aqueous.mirror-destination' in json.dumps(windows), 'occupied output lost its window'
        assert status(names[0])['render_locks'] == 1
        expect_color(latest('target', 'submitted')['frame'])
        for _ in range(4):
            frame = draw()
            expect_color(frame)
            wait(lambda: any(v.get('event') == 'presented' and v.get('frame') == frame for v in events('target')), 'source feedback stalled')
        outputs = request(op='list')['outputs']
        assert outputs[0]['current_mode']['refresh'] == 240, outputs
        assert outputs[1]['current_mode']['refresh'] == 60, outputs
        results.append(dict(case='mixed-refresh-letterbox-source-feedback', passed=True))

        for rate in (144, 120, 360):
            result = request(op='set', changes=[dict(name=names[0], mode=f'1280x720@{rate}', scale=1.25)])
            assert result['ok'], result
            change(mode='800x800@59.94')
            time.sleep(.15)
            expect_color(latest('target', 'submitted')['frame'])
        result = request(op='set', changes=[dict(name=names[0], mode='1280x720@240', scale=1)])
        assert result['ok'], result
        change(mode='960x720@60')
        time.sleep(.15)
        expect_color(latest('target', 'submitted')['frame'])
        results.append(dict(case='fractional-scale-resize-noninteger-refresh', passed=True))

        # Fixed-rate output must continue presenting if its source is idle.
        before = status()['commit_seq']
        time.sleep(.1)
        assert status()['commit_seq'] > before
        chain = request(op='set', changes=[dict(name=names[0], mirror_of=names[1])])
        assert not chain['ok'], chain
        change(mirror_of='missing-source')
        wait(lambda: pixels() == [0] * 5, 'missing source did not blank')
        assert status()['mirror_status'] == 'waiting_for_source'
        change(mirror_of=names[0])
        expect_color(latest('target', 'submitted')['frame'])

        locker = launch([work / 'shell-client', 'lock'], 'locker')
        wait(lambda: status()['session_locked'], 'lock not confirmed')
        wait(lambda: pixels() == [0] * 5, 'locked mirror retained desktop')
        locker.stdin.write(b'unlock\n')
        locker.stdin.flush()
        wait(lambda: not status()['session_locked'], 'unlock not processed')
        time.sleep(.15)  # focus reconfiguration may cause the fixture to redraw
        expect_color(latest('target', 'submitted')['frame'])
        results.append(dict(case='missing-source-lock-unlock', passed=True))

        for _ in range(5):
            change(mirror_of='')
            assert status()['policy_exposed']
            assert status(names[0])['render_locks'] == 0
            change(mirror_of=names[0])
            expect_color(latest('target', 'submitted')['frame'])
        # Independent destination failure must recover without another client commit.
        status(action='arm', stage='output_commit', count=3)
        wait(lambda: status()['retry']['total_failures'] >= 3, 'fault not reached')
        wait(lambda: not status()['retry']['pending'], 'mirror did not recover')
        expect_color(latest('target', 'submitted')['frame'])
        request(op='test_output_retry', name=names[0], action='destroy')
        wait(lambda: pixels() == [0] * 5, 'source unplug retained desktop')
        results.append(dict(case='toggle-failure-unplug', passed=True))
        if args.validation:
            log = (work / 'compositor.log').read_text()
            assert 'Validation Error' not in log and 'VUID-' not in log, 'Vulkan validation reported an error'
        (work / 'result.json').write_text(json.dumps(dict(passed=True, cases=results), indent=2))
        print('PASS basic mirroring', flush=True)
        return 0
    except Exception as error:
        if 'compositor' in locals() and compositor.poll() is None:
            try:
                snapshot('failure')
            except Exception:
                pass
        try:
            (work / 'failure-status.json').write_text(json.dumps(dict(status=status(), pixels=pixels()), indent=2))
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
