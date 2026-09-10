#!/usr/bin/env python3
"""Exercise system-bell protocol, feedback, audio and lifecycle in a private session."""
import argparse
import array
import math
import shutil
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import wave
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, default=ROOT / 'zig-out/bin/aqueousctl')
    parser.add_argument('--renderer', choices=('pixman', 'vulkan'), default='pixman')
    parser.add_argument('--real-audio', action='store_true', help='Verify WAV/Ogg and volume through a private PipeWire sink')
    parser.add_argument('--policy', choices=('internal', 'external'), default='internal')
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix='aqueous-bell-'))
    print(f'Artifacts: {work}', flush=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    children, logs = [], []
    compositor = None

    def run(command):
        return subprocess.check_output([str(p) for p in command], env=env, text=True,
                                       stderr=subprocess.STDOUT, timeout=30)

    def launch(command, label):
        out, err = (work / f'{label}.jsonl').open('w'), (work / f'{label}.log').open('w')
        logs.extend((out, err))
        child = subprocess.Popen([str(p) for p in command], env=env, stdin=subprocess.PIPE,
                                 stdout=out, stderr=err, start_new_session=True)
        children.append(child)
        return child

    def wait(predicate, description, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert compositor is None or compositor.poll() is None, 'compositor exited'
            value = predicate()
            if value:
                return value
            time.sleep(.01)
        raise AssertionError(description)

    def events(label, kind):
        result = []
        path = work / f'{label}.jsonl'
        for line in path.read_text().splitlines() if path.exists() else []:
            try:
                value = json.loads(line)
                if value['event'] == kind:
                    result.append(value)
            except ValueError:
                pass
        return result

    def command(value, child=None, label='bell'):
        before = len(events(label, 'command'))
        target = client if child is None else child
        target.stdin.write((value + '\n').encode()); target.stdin.flush()
        wait(lambda: len(events(label, 'command')) > before, f'{label}: {value}')

    def ctl(*values):
        return json.loads(run([args.ctl.resolve(), *values, '--json']))

    def window(label='bell', id=0):
        return next((w for w in ctl('windows') if w.get('app_id') == f'{label}-{id}'), None)

    def configure(mode='visual', path='sounds/a $bell.wav', volume=.5):
        (work / 'config.toml').write_text(
            '[layout]\ndefault = "floating"\n[blur]\nenabled = false\n'
            '[workspace_transition]\nenabled = false\n'
            f'[bell]\nmode = "{mode}"\nsound_file = {json.dumps(path)}\nvolume = {volume}\n')
        if compositor:
            ctl('session', 'reload')
        time.sleep(.55)  # Requests straddling reload still share the cooldown.

    def screenshot(output='HEADLESS-2'):
        path = work / f'{output}.png'
        run(['grim', '-o', output, path])
        with Image.open(path) as img:
            return img.convert('RGB').copy()

    def edge(image):
        return image.getpixel((image.width // 2, 1))

    def ring_visual(value='ring 0'):
        time.sleep(.55)
        before = screenshot()
        second = edge(screenshot('HEADLESS-1'))
        command(value)
        wait(lambda: edge(screenshot()) != edge(before), 'no visual bell', timeout=1)
        assert edge(screenshot('HEADLESS-1')) == second, 'bell affected another output'
        wait(lambda: edge(screenshot()) == edge(before), 'bell did not expire')
        assert screenshot().getpixel((before.width // 2, before.height // 2)) == before.getpixel((before.width // 2, before.height // 2))

    def starts():
        return events('audio', 'start')

    def ring_audio():
        time.sleep(.55)
        before = len(starts())
        command('ring 0')
        wait(lambda: len(starts()) == before + 1, 'no audio start')
        return starts()[-1]['pid']

    def reaped(pid):
        return not Path(f'/proc/{pid}').exists()

    try:
        protocols = Path(run(['pkg-config', '--variable=pkgdatadir', 'wayland-protocols']).strip())
        generated = []
        for name, xml in {
            'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
            'xdg-system-bell': protocols / 'staging/xdg-system-bell/xdg-system-bell-v1.xml',
            'security-context': protocols / 'staging/security-context/security-context-v1.xml',
            'session-lock': protocols / 'staging/ext-session-lock/ext-session-lock-v1.xml',
        }.items():
            run(['wayland-scanner', 'client-header', xml, work / f'{name}-client-protocol.h'])
            code = work / f'{name}.c'
            run(['wayland-scanner', 'private-code', xml, code]); generated.append(code)
        run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
             ROOT / 'scripts/fixtures/xdg-system-bell.c', *generated, '-lwayland-client', '-o', work / 'client'])
        for name in ('runtime', 'home', 'config', 'cache', 'state', 'bin', 'sounds'):
            (work / name).mkdir(mode=0o700)
        with wave.open(str(work / 'sounds/a $bell.wav'), 'wb') as wav:
            wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
            wav.writeframes(b'\0\0' * 800)
        fake = work / 'bin/pw-play'
        fake.write_text('''#!/usr/bin/python3
import json, os, signal, sys, time
from pathlib import Path
root = Path(os.environ['BELL_TEST_ROOT'])
mode = (root / 'audio-mode').read_text()
with (root / 'audio.jsonl').open('a') as out:
    out.write(json.dumps({'event':'start', 'pid':os.getpid(), 'argv':sys.argv[1:], 'header':os.read(0,4).decode('ascii')})+'\\n')
if mode == 'ignore': signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode in ('hold', 'ignore'): time.sleep(30)
if mode == 'fail': sys.exit(1)
''')
        fake.chmod(0o755)
        fake_source = fake.read_text()
        (work / 'audio-mode').write_text('ok')
        env.update(HOME=str(work / 'home'), XDG_RUNTIME_DIR=str(work / 'runtime'),
                   XDG_CONFIG_HOME=str(work / 'config'), XDG_CACHE_HOME=str(work / 'cache'),
                   XDG_STATE_HOME=str(work / 'state'), WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2',
                   WLR_RENDERER=args.renderer, BELL_TEST_ROOT=str(work),
                   PATH=str(work / 'bin') + ':' + env['PATH'])
        for name in ('CONFIG', 'RULES', 'OUTPUTS', 'INPUT', 'LAYOUT'):
            path = work / f'{name.lower()}.toml'; path.write_text('')
            env[f'AQUEOUS_{name}'] = str(path)
        if args.real_audio:
            for tool in ('pipewire', 'wireplumber', 'dbus-daemon', 'pw-record', 'pw-play', 'ffmpeg'):
                assert shutil.which(tool), f'{tool} required for --real-audio'
            env['PIPEWIRE_RUNTIME_DIR'] = str(work / 'runtime')
            env['PIPEWIRE_REMOTE'] = 'bell-test'
            launch(['dbus-daemon', '--session', '--nofork', '--print-address=1'], 'dbus')
            env['DBUS_SESSION_BUS_ADDRESS'] = wait(lambda: (work / 'dbus.jsonl').read_text().strip(), 'no private D-Bus')
            pw_config = work / 'pipewire.conf'
            pw_config.write_text('''
context.properties = { core.daemon = true core.name = bell-test default.clock.rate = 48000 }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-metadata }
    { name = libpipewire-module-spa-node-factory }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-access }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-link-factory }
]
context.objects = [
    { factory = adapter args = {
        factory.name = support.null-audio-sink
        node.driver = true
        node.name = bell-test-sink
        node.description = "Bell test sink"
        media.class = Audio/Sink
        audio.position = [ FL FR ]
    } }
]
''')
            launch(['pipewire', '-c', pw_config], 'pipewire')
            wait(lambda: (work / 'runtime/bell-test').exists(), 'no private PipeWire')
            # The policy-only profile never loads audio/Bluetooth hardware monitors.
            launch(['wireplumber', '--profile=policy'], 'wireplumber')
            wait(lambda: 'bell-test-sink' in run(['pw-dump']), 'no test sink')
        configure()
        compositor = launch([args.compositor.resolve(), '-policy', args.policy, '-no-xwayland', '-log-level', 'debug', '-c', 'true'], 'compositor')
        env['WAYLAND_DISPLAY'] = wait(lambda: next((p.name for p in (work / 'runtime').glob('wayland-*') if p.is_socket()), None), 'no display')
        wait(lambda: (work / 'runtime/aqueous/outputd.sock').exists(), 'no control socket')
        client = launch([work / 'client', 'bell'], 'bell')
        wait(lambda: events('bell', 'ready'), 'no bell global')
        assert events('bell', 'global')[0]['version'] == 1
        command('roleless'); command('null'); command('premap 1'); command('ring 1'); command('destroy 1')
        if args.policy == 'external':
            command('rebind'); command('roleless'); command('null')
            client.stdin.write(b'quit\n'); client.stdin.flush(); assert client.wait(timeout=5) == 0
            compositor.send_signal(signal.SIGTERM); assert compositor.wait(timeout=8) == 0
            print('PASS external-policy registry, requests, rebind and shutdown', flush=True)
            return
        command('create 0'); wait(window, 'window not mapped')
        ctl('window', 'activate', '--id', str(window()['id']), '--seat', 'default')
        ring_visual(); ring_visual('null')
        focus_before = window()['states']
        command('rebind'); command('subsurface 0'); command('popup 0'); ring_visual('ring 0 2000')
        assert window()['states'] == focus_before
        print('PASS registry, null/roleless/pre-map, visual expiry, multiple bindings and focus', flush=True)

        command('sandbox')
        normal = env['WAYLAND_DISPLAY']; env['WAYLAND_DISPLAY'] = 'bell-sandbox'
        sandbox = launch([work / 'client', 'sandbox'], 'sandbox')
        env['WAYLAND_DISPLAY'] = normal
        wait(lambda: events('sandbox', 'ready'), 'sandbox registry failed')
        command('create 0', sandbox, 'sandbox'); wait(lambda: window('sandbox'), 'sandbox window')
        command('ring 0', sandbox, 'sandbox'); command('destroy 0', sandbox, 'sandbox')
        sandbox.stdin.write(b'quit\n'); sandbox.stdin.flush(); assert sandbox.wait(timeout=5) == 0
        print('PASS security-context client and surface lifetime', flush=True)

        configure('both'); pid = ring_audio(); wait(lambda: reaped(pid), 'audio zombie')
        assert starts()[-1]['header'] == 'RIFF'
        assert starts()[-1]['argv'] == ['--media-role=Notification', '--volume', '0.5000', '/proc/self/fd/0']
        ring_visual()
        escaped_name = 'sounds/a "quote" \\ bell.wav'
        shutil.copyfile(work / 'sounds/a $bell.wav', work / escaped_name)
        configure('both', escaped_name); pid = ring_audio(); wait(lambda: reaped(pid), 'escaped path player')
        assert starts()[-1]['header'] == 'RIFF'
        configure('both')
        (work / 'audio-mode').write_text('ignore')
        pid = ring_audio(); before = len(starts())
        command('ring 0 2000'); time.sleep(.55); command('ring 0 2000')
        assert len(starts()) == before, 'overlapping players'
        wait(lambda: reaped(pid), 'timeout failed', timeout=3)
        print('PASS custom path, volume, flood, timeout and reaping', flush=True)

        configure('sound', volume=.25)
        before = edge(screenshot()); pid = ring_audio()
        assert edge(screenshot()) == before, 'sound-only mode flashed'
        assert starts()[-1]['argv'][2] == '0.2500'
        command('lock'); wait(lambda: events('bell', 'locked'), 'session did not lock')
        wait(lambda: reaped(pid), 'lock did not stop sound')
        count = len(starts()); command('ring 0'); command('null'); time.sleep(.6)
        assert len(starts()) == count
        command('unlock'); time.sleep(.3); assert len(starts()) == count
        pid = ring_audio(); configure('off'); wait(lambda: reaped(pid), 'off did not stop sound')
        count = len(starts()); command('ring 0'); time.sleep(.6); assert len(starts()) == count
        print('PASS sound-only, locking, unlock and disabling', flush=True)

        configure('both')
        pid = ring_audio()
        run(['wlr-randr', '--output', 'HEADLESS-2', '--off'])
        wait(lambda: reaped(pid), 'output power-off did not stop sound')
        run(['wlr-randr', '--output', 'HEADLESS-2', '--on'])
        ctl('window', 'move', '--id', str(window()['id']), '--output', 'HEADLESS-2')
        time.sleep(.3)
        pid = ring_audio()
        run(['wlr-randr', '--output', 'HEADLESS-2', '--scale', '1.5', '--transform', '90'])
        wait(lambda: reaped(pid), 'output geometry change did not stop sound')
        ring_visual()
        run(['wlr-randr', '--output', 'HEADLESS-2', '--scale', '1', '--transform', 'normal'])
        configure('visual'); command('fullscreen 0'); time.sleep(.2); ring_visual()
        print('PASS output power, geometry, scale, rotation and fullscreen', flush=True)


        for path in ('', 'missing.wav', 'sounds', 'fifo'):
            if path == 'fifo': os.mkfifo(work / path)
            configure('both', path=path)
            count = len(starts()); ring_visual(); assert len(starts()) == count
        configure('both', volume=0); count = len(starts()); ring_visual(); assert len(starts()) == count
        if args.real_audio:
            fake.unlink()
            # Source builds resolve pw-play via PATH, which now reaches the real player.
            tone = work / 'sounds/tone.wav'
            samples = array.array('h', [int(8000 * math.sin(2 * math.pi * 440 * i / 8000)) for i in range(6400)])
            with wave.open(str(tone), 'wb') as wav:
                wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed')); wav.writeframes(samples.tobytes())
            ogg = work / 'sounds/tone.ogg'
            run(['ffmpeg', '-v', 'error', '-i', tone, '-c:a', 'libvorbis', ogg])
            peaks = []
            for index, (sound, volume) in enumerate(((tone, .5), (tone, .25), (ogg, .5))):
                configure('sound', str(sound), volume)
                recorded = work / f'recorded-{index}.wav'
                recorder = launch(['pw-record', '--target=bell-test-sink', '-P', '{ stream.capture.sink = true }',
                                   '--rate=8000', '--channels=1', '--format=s16', recorded], f'recorder-{index}')
                time.sleep(.3)
                command('ring 0'); time.sleep(1.3)
                recorder.send_signal(signal.SIGINT); recorder.wait(timeout=3)
                # pw-cat exit codes on interruption vary; validate the captured PCM below.
                with wave.open(str(recorded), 'rb') as wav:
                    result = array.array('h', wav.readframes(wav.getnframes()))
                peaks.append(max(map(abs, result), default=0))
            assert peaks[0] > 100, f'no recorded WAV sound: {peaks}'
            assert .35 < peaks[1] / peaks[0] < .65, f'volume not applied: {peaks}'
            assert peaks[2] > 100, f'no recorded Ogg sound: {peaks}'
            print(f'PASS real PipeWire WAV/Ogg playback and volume, recorded peaks {peaks}', flush=True)
        configure('visual'); command('unmap 0'); command('ring 0'); command('destroy 0')
        print('PASS missing/invalid file fallback, zero volume, unmap and destroy', flush=True)
        fake.write_text(fake_source); fake.chmod(0o755)
        (work / 'audio-mode').write_text('ignore')
        command('create 0'); wait(window, 'shutdown test window')
        configure('both'); pid = ring_audio()
        command('destroy 0')
        client.stdin.write(b'quit\n'); client.stdin.flush(); assert client.wait(timeout=5) == 0
        compositor.send_signal(signal.SIGTERM); assert compositor.wait(timeout=8) == 0
        assert reaped(pid), 'playback child survived shutdown'
        print('PASS live playback/client destruction and clean compositor shutdown', flush=True)
    finally:
        for child in reversed(children):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
        for log in logs: log.close()


if __name__ == '__main__':
    main()
