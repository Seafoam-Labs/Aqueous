#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Headless integration tests for the [[window]] keep_render rule.

A kept, mapped window must keep receiving ~60 Hz frame callbacks whenever the
scene is not delivering them (inactive workspace, minimized, output soft-off,
idle session), must not be double-paced while visible on a live output, and
must never be sent the xdg-toplevel `suspended` configure state. Removing the
rule restores normal idling and suspension after a hot reload.

Runs an isolated headless compositor (pixman) following the Session pattern of
scripts/probe-buffer-retention.py. The fps probe is the ready-made
fixtures/buffer-retention-client.c in `wine` mode: it commits a fresh buffer
whenever none has been released, so its frame rate tracks callback delivery
exactly. `pool` mode is unusable in this harness: an honest pool client
deadlocks because the scene holds the current buffer until a new commit
replaces it (the existing probe reports the same stall on a healthy session).

One long-lived probe arm streams per-second CSV rows; each case measures
frames/sec over a window of rows, so the client survives workspace switches,
minimize, output power changes and rule reloads.

Exit status: 0 all cases passed, 1 failure, 77 required environment missing.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'scripts/fixtures'
XDG_XML = Path('/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml')
PROBE_APP_ID = 'aq-buffer-retention-probe'
STATES_APP_ID = 'aq-keep-render-states'
KEEP_RULE = f'[[window]]\napp_id = "{PROBE_APP_ID}"\nkeep_render = true\n'
STATES_RULE = f'[[window]]\napp_id = "{STATES_APP_ID}"\nkeep_render = true\n'
# Headless timing is noisy on loaded machines; keep the bands generous.
IDLE_FPS_MAX = 5.0
KEPT_FPS_MIN, KEPT_FPS_MAX = 35.0, 80.0
VISIBLE_FPS_MIN, VISIBLE_FPS_MAX = 30.0, 100.0


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--ctl', type=Path, help='Defaults to aqueousctl beside the selected compositor')
    parser.add_argument('--duration', type=float, default=6.0,
                        help='seconds per fps measurement window (default 6)')
    parser.add_argument('--size', default='320x240', help='probe window size, e.g. 640x480')
    return parser.parse_args()


def wait_for(check, description, timeout=15, alive=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if alive is not None:
            assert alive(), 'compositor exited while waiting; see compositor.log'
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError(f'timed out: {description}')


class Session:
    """Isolated headless compositor, private runtime/config (probe-buffer-retention pattern)."""

    def __init__(self, base, compositor, wm_config):
        runtime = base / 'runtime'
        runtime.mkdir(mode=0o700, parents=True)
        config = base / 'config'
        config.mkdir(exist_ok=True)
        self.rules = config / 'rules.toml'
        self.rules.write_text('')
        env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
        env.update(XDG_STATE_HOME=str(base / 'state'), XDG_CACHE_HOME=str(base / 'cache'),
                   XDG_RUNTIME_DIR=str(runtime), XDG_CONFIG_HOME=str(config), HOME=str(base),
                   WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman',
                   AQUEOUS_CONFIG=str(wm_config), AQUEOUS_RULES=str(self.rules))
        for key in ('WAYLAND_DISPLAY', 'DISPLAY', 'LD_PRELOAD', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        self.env = env
        self.log_path = base / 'compositor.log'
        self.log = self.log_path.open('w+')
        self.compositor = subprocess.Popen(
            [str(compositor), '-no-xwayland', '-c', 'true'],
            env=env, stdout=self.log, stderr=self.log)
        env['WAYLAND_DISPLAY'] = wait_for(
            lambda: next((p.name for p in runtime.glob('wayland-*') if p.is_socket()), None),
            'no Wayland socket', alive=self.alive)

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


class Probe:
    """Long-lived wine-mode fps arm; streams the per-second CSV rows."""

    def __init__(self, binary, env, seconds, width, height, log_path):
        self.rows = []
        self.lock = threading.Lock()
        self.err = log_path.open('w')
        self.proc = subprocess.Popen(
            [str(binary), 'wine', str(seconds), str(width), str(height), '1'],
            env=env, stdout=subprocess.PIPE, stderr=self.err, text=True, bufsize=1)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line or line.startswith('SUMMARY'):
                continue
            try:
                row = [int(value) for value in line.split(',')]
            except ValueError:
                continue
            with self.lock:
                self.rows.append(row)

    def alive(self):
        return self.proc.poll() is None

    def snapshot(self):
        with self.lock:
            return list(self.rows)

    def measure(self, seconds, session):
        """Frames/sec over a window of fresh CSV rows (t_ms, frames, ...)."""
        assert self.alive(), 'fps probe exited early; see probe.log'
        count = len(self.snapshot())
        first = wait_for(lambda: (lambda rows: rows[count] if len(rows) > count else None)(self.snapshot()),
                         'no fresh probe row', timeout=5, alive=session.alive)
        target_ms = first[0] + seconds * 1000
        deadline = time.monotonic() + seconds + 8
        while True:
            assert session.alive(), 'compositor exited during measurement'
            assert self.alive(), 'fps probe exited during measurement; see probe.log'
            last = self.snapshot()[-1]
            if last[0] >= target_ms:
                break
            if time.monotonic() > deadline:
                raise AssertionError('probe rows stopped arriving during measurement')
            time.sleep(0.05)
        span = (last[0] - first[0]) / 1000
        assert span > 0, 'degenerate measurement window'
        return (last[1] - first[1]) / span, last

    def close(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.err.close()


def build_probe(work):
    subprocess.run(['wayland-scanner', 'client-header', str(XDG_XML),
                    str(work / 'xdg-shell-client-protocol.h')], check=True)
    subprocess.run(['wayland-scanner', 'private-code', str(XDG_XML),
                    str(work / 'xdg-shell-protocol.c')], check=True)
    flags = shlex.split(subprocess.check_output(
        ['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
    binary = work / 'probe'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', '-I', str(work),
                    str(FIXTURES / 'buffer-retention-client.c'), str(work / 'xdg-shell-protocol.c'),
                    '-o', str(binary), *flags], check=True)
    return binary


def build_states_fixture(work):
    """Best-effort xdg-shell-states fixture; returns (binary, suspended_bit) or raises."""
    protocols = Path('/usr/share/wayland-protocols')
    xmls = {
        'xdg-shell': protocols / 'stable/xdg-shell/xdg-shell.xml',
        'ext-foreign-toplevel-list': protocols / 'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
        'ext-image-capture-source': protocols / 'staging/ext-image-capture-source/ext-image-capture-source-v1.xml',
        'ext-image-copy-capture': protocols / 'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml',
    }
    generated = []
    for name, xml in xmls.items():
        if not xml.exists():
            raise FileNotFoundError(f'missing protocol {xml}')
        subprocess.run(['wayland-scanner', 'client-header', str(xml),
                        str(work / f'{name}-client-protocol.h')], check=True, capture_output=True)
        code = work / f'{name}-states.c'
        subprocess.run(['wayland-scanner', 'private-code', str(xml), str(code)],
                       check=True, capture_output=True)
        generated.append(str(code))
    header = (work / 'xdg-shell-client-protocol.h').read_text()
    match = re.search(r'XDG_TOPLEVEL_STATE_SUSPENDED\s*=\s*(\d+)', header)
    if not match:
        raise ValueError('XDG_TOPLEVEL_STATE_SUSPENDED not found in generated xdg-shell header')
    suspended_bit = 1 << int(match.group(1))
    binary = work / 'states'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2', f'-I{work}',
                    str(FIXTURES / 'xdg-shell-states.c'), *generated,
                    '-lwayland-client', '-o', str(binary)], check=True, capture_output=True)
    return binary, suspended_bit


def log_tail(path, lines=40):
    try:
        return '\n'.join(path.read_text().splitlines()[-lines:])
    except OSError:
        return '(log unavailable)'


def main():
    args = parse_args()
    compositor = args.compositor.resolve()
    ctl = (args.ctl or compositor.with_name('aqueousctl')).resolve()
    for tool in ('cc', 'pkg-config', 'wayland-scanner', 'wlr-randr'):
        if subprocess.run(['which', tool], capture_output=True).returncode:
            print(f'SKIP: {tool} is required')
            return 77
    for path in (compositor, ctl, XDG_XML, FIXTURES / 'buffer-retention-client.c'):
        if not path.exists():
            print(f'SKIP: {path} missing')
            return 77
    width, _, height = args.size.partition('x')
    work = Path(tempfile.mkdtemp(prefix='aqueous-keep-render-'))
    print(f'Artifacts: {work}', flush=True)

    states_binary, suspended_bit, states_skip = None, None, None
    try:
        probe_binary = build_probe(work)
    except (subprocess.CalledProcessError, FileNotFoundError) as err:
        print(f'SKIP: fps fixture build failed: {err}')
        return 77
    try:
        states_binary, suspended_bit = build_states_fixture(work)
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError, OSError) as err:
        states_skip = f'xdg-shell-states fixture unavailable: {err}'

    # Floating layout: minimize is only permitted for floating presentations
    # (wm/state/store.zig canMinimizeFrom). Transitions/effects off so nothing
    # but the keep-render timer can drive the frame loop while hidden.
    wm_config = work / 'wm.toml'
    wm_config.write_text('[layout]\ndefault = "floating"\ngaps_outer = 0\ngaps_inner = 0\n'
                         'border_width = 0\n[blur]\nenabled = false\n[opacity]\nenabled = false\n'
                         '[workspace_transition]\nenabled = false\n'
                         '[input]\nfocus_follows_mouse = false\nfocus_new_windows = false\n')
    session = Session(work / 'session', compositor, wm_config)
    env = session.env
    probe = None
    states_proc = None
    states_out = None
    results = []

    def ctl_json(*values):
        result = subprocess.run([str(ctl), *values, '--json'], env=env, text=True,
                                capture_output=True, timeout=20)
        assert result.returncode == 0, f'aqueousctl {values}: {result.stdout} {result.stderr}'
        value = json.loads(result.stdout)
        if isinstance(value, dict) and 'ok' in value:
            assert value['ok'], f'aqueousctl {values}: {value}'
        return value

    def probe_window():
        return next((w for w in ctl_json('windows') if w.get('app_id') == PROBE_APP_ID), None)

    def states_events(kind=None):
        events = []
        for line in (work / 'states.jsonl').read_text().splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if kind is None or value.get('event') == kind:
                events.append(value)
        return events

    def set_rules(text):
        session.rules.write_text(text)
        ctl_json('session', 'reload')

    def workspace_ids():
        records = ctl_json('shell', 'snapshot')['upsert']
        output = next(r for r in records if r['kind'] == 'output' and r['name'] == output_name)
        home = output['active_workspace']
        other = min((r for r in records if r['kind'] == 'workspace'
                     and r['output'] == output['id'] and r['id'] != home),
                    key=lambda r: r['number'])['id']
        return home, other

    def activate(workspace_id):
        ctl_json('workspace', 'activate', '--id', workspace_id)

    def wait_states(window_id, wanted, present):
        def check():
            window = next((w for w in ctl_json('windows') if w['id'] == window_id), None)
            if window is None:
                return None
            return window if (wanted in window['states']) == present else None
        return wait_for(check, f'window {window_id} states {wanted} present={present}',
                        alive=session.alive)

    def report(name, fps, last):
        results.append((name, fps))
        print(f'PASS {name} fps={fps:.1f} (live_buffers={last[3]}, live_kb={last[4]})', flush=True)

    def measure_kept(name):
        fps, last = probe.measure(args.duration, session)
        assert KEPT_FPS_MIN <= fps <= KEPT_FPS_MAX, \
            f'{name}: kept window fps {fps:.1f} outside {KEPT_FPS_MIN}..{KEPT_FPS_MAX}'
        report(name, fps, last)

    def measure_idle(name):
        fps, last = probe.measure(args.duration, session)
        assert fps < IDLE_FPS_MAX, f'{name}: hidden window fps {fps:.1f}, expected < {IDLE_FPS_MAX}'
        report(name, fps, last)

    try:
        output_name = ctl_json('outputs')[0]['name']
        # Long enough to survive every case; terminated in finally regardless.
        lifetime = int(args.duration * 10 + 90)
        probe = Probe(probe_binary, env, lifetime, width, height, work / 'probe.log')
        window = wait_for(probe_window, 'probe window never mapped', alive=session.alive)
        window_id = window['id']
        home_ws, other_ws = workspace_ids()
        wait_states(window_id, 'visible', True)
        time.sleep(1.0)

        # 1. Without the rule a hidden window idles.
        activate(other_ws)
        wait_states(window_id, 'visible', False)
        time.sleep(1.0)
        measure_idle('no-rule-hidden-idles')

        # 4. Hot reload adds and removes the effect on the same hidden window.
        set_rules(KEEP_RULE)
        time.sleep(1.0)
        measure_kept('hot-reload-add-remove/add')
        set_rules('')
        time.sleep(1.0)
        measure_idle('hot-reload-add-remove/remove')

        # 2. With the rule the hidden window sustains ~60 Hz.
        set_rules(KEEP_RULE)
        time.sleep(1.0)
        measure_kept('rule-hidden-sustains')

        # 3. Minimized (floating presentation) keeps the same pacing.
        ctl_json('window', 'state', '--id', window_id, '--minimized', 'true')
        wait_states(window_id, 'minimized', True)
        time.sleep(1.0)
        measure_kept('minimized-sustains')
        ctl_json('window', 'state', '--id', window_id, '--minimized', 'false')
        wait_states(window_id, 'minimized', False)
        time.sleep(0.5)

        # 5. Idle session: nothing else runs (no captures, no animations, no
        # ctl traffic during the window) - only the keep-render timer can pace.
        wait_states(window_id, 'visible', False)
        time.sleep(2.0)
        measure_kept('idle-session-sustains')

        # 6. Soft-disabled output: the timer is independent of output state.
        subprocess.run(['wlr-randr', '--output', output_name, '--off'],
                       env=env, check=True, capture_output=True, timeout=15)
        time.sleep(1.0)
        measure_kept('output-off-sustains')
        subprocess.run(['wlr-randr', '--output', output_name, '--on'],
                       env=env, check=True, capture_output=True, timeout=15)
        time.sleep(1.0)

        # 8. Suspended configure bit (best-effort second fixture).
        if states_skip:
            print(f'SKIP suspended-bit: {states_skip}', flush=True)
        else:
            states_out = (work / 'states.jsonl').open('w')
            states_err = (work / 'states.log').open('w')
            states_proc = subprocess.Popen(
                [str(states_binary), '7', STATES_APP_ID], env=env,
                stdin=subprocess.PIPE, stdout=states_out, stderr=states_err, text=True)
            states_window = wait_for(
                lambda: next((w for w in ctl_json('windows') if w.get('app_id') == STATES_APP_ID), None),
                'states window never mapped', alive=session.alive)
            wait_for(lambda: states_events('configure'), 'no initial configure', alive=session.alive)
            set_rules(KEEP_RULE + STATES_RULE)
            time.sleep(0.5)
            serial_before = states_events('configure')[-1]['serial']
            # Hide the states window on the probe's inactive workspace.
            ctl_json('window', 'move', '--id', states_window['id'], '--workspace-id', home_ws)

            def configure_after(serial):
                events = [e for e in states_events('configure') if e['serial'] > serial]
                return events[-1] if events else None

            def nudge_configure():
                # Force a fresh configure pair by visiting both workspaces.
                activate(home_ws)
                time.sleep(0.4)
                activate(other_ws)

            kept_configure = None
            try:
                kept_configure = wait_for(lambda: configure_after(serial_before),
                                          'configure after hide', timeout=8, alive=session.alive)
            except AssertionError:
                nudge_configure()
                kept_configure = wait_for(lambda: configure_after(serial_before),
                                          'configure after hide (nudged)', timeout=8, alive=session.alive)
            assert not kept_configure['states'] & suspended_bit, \
                f'kept hidden window got SUSPENDED: {kept_configure}'
            serial_kept = kept_configure['serial']
            # Removing the rule restores suspension on the next manage cycle.
            set_rules(KEEP_RULE)
            suspended_configure = None
            try:
                suspended_configure = wait_for(
                    lambda: (lambda e: e if e and e['states'] & suspended_bit else None)(
                        configure_after(serial_kept)),
                    'suspended configure after rule removal', timeout=8, alive=session.alive)
            except AssertionError:
                nudge_configure()
                suspended_configure = wait_for(
                    lambda: (lambda e: e if e and e['states'] & suspended_bit else None)(
                        configure_after(serial_kept)),
                    'suspended configure after rule removal (nudged)', timeout=8, alive=session.alive)
            results.append(('suspended-bit', None))
            print(f'PASS suspended-bit (kept states={kept_configure["states"]}, '
                  f'restored states={suspended_configure["states"]})', flush=True)
            states_proc.stdin.write('q')
            states_proc.stdin.flush()
            states_proc.wait(timeout=5)
            states_proc = None

        # 7. Visible on the live output: scene-paced only, never double-paced.
        activate(home_ws)
        wait_states(window_id, 'visible', True)
        time.sleep(1.0)
        fps, last = probe.measure(args.duration, session)
        assert VISIBLE_FPS_MIN < fps < VISIBLE_FPS_MAX, \
            f'visible-not-double-paced: fps {fps:.1f} outside {VISIBLE_FPS_MIN}..{VISIBLE_FPS_MAX}'
        report('visible-not-double-paced', fps, last)
    except BaseException:
        print(f'FAIL: compositor log: {session.log_path}', flush=True)
        print(log_tail(session.log_path), flush=True)
        if probe is not None and not probe.alive():
            print(f'probe log: {work / "probe.log"}', flush=True)
            print(log_tail(work / 'probe.log', 20), flush=True)
        raise
    finally:
        if states_proc is not None and states_proc.poll() is None:
            states_proc.terminate()
            try:
                states_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                states_proc.kill()
                states_proc.wait()
        if states_out is not None:
            states_out.close()
        if probe is not None:
            probe.close()
        session.close()

    print(f'All {len(results)} keep-render cases passed '
          f'({sum(1 for _, fps in results if fps is not None)} fps windows, '
          f'duration={args.duration:g}s). Artifacts: {work}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())