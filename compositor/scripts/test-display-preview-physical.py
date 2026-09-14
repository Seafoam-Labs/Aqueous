#!/usr/bin/env python3
"""Inventory physical preview prerequisites, or exercise SDR in a disposable DRM session.

A report from this harness does not enable production hardware previews. Unrun
fault/manual cases remain explicit acceptance gaps.
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
import uuid

from ipc_test_client import Client

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = (
    'revert-placement', 'revert-scale', 'revert-transform', 'revert-mode',
    'revert-enable', 'timeout', 'owner-disconnect', 'keep', 'helper-prepared',
    'helper-committed', 'restart-preview', 'restart-prepared', 'restart-committed',
    'failed-test', 'failed-commit', 'partial-multi-output-commit',
    'hotplug-preview', 'hotplug-commit', 'lease-loss', 'suspend-resume',
    'rollback-fallback', 'rollback-failure',
)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory():
    connectors = []
    for path in sorted(Path('/sys/class/drm').glob('card*-*')):
        if not (path / 'status').exists():
            continue
        def read(name):
            try:
                return (path / name).read_text().strip()
            except OSError:
                return None
        try:
            edid = (path / 'edid').read_bytes()
        except OSError:
            edid = b''
        connectors.append(dict(sysfs=str(path), status=read('status'), modes=read('modes'),
                               edid_hex=edid.hex(), edid_sha256=hashlib.sha256(edid).hexdigest() if edid else None))
    devices = []
    for path in sorted(Path('/sys/class/drm').glob('card[0-9]*')):
        if '-' in path.name:
            continue
        device = path / 'device'
        devices.append(dict(card=path.name, device=str(device.resolve()),
                            driver=str((device / 'driver').resolve())))
    return dict(kernel=list(os.uname()), devices=devices, connectors=connectors)


def prerequisites(args, environ):
    if not args.dedicated_seat or not args.recovery_console:
        raise ValueError('--run-sdr requires --dedicated-seat and --recovery-console')
    if any(environ.get(key) for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET')):
        raise ValueError('Run from a dedicated TTY, outside the ordinary graphical session')
    if not args.drm_device or not args.connector:
        raise ValueError('Select a DRM card and every participating connector explicitly')
    if any(',' in name or not name or name == '*' for name in args.connector):
        raise ValueError('Connector selectors must be exact individual names')
    if not args.drm_device.is_absolute() or not args.drm_device.name.startswith('card'):
        raise ValueError('--drm-device must select an absolute DRM card path, not a render node')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulate', action='store_true', help='Exercise the harness on headless outputs; never hardware acceptance')
    parser.add_argument('--run-sdr', action='store_true', help='Run physical tests; default is read-only inventory')
    parser.add_argument('--dedicated-seat', action='store_true')
    parser.add_argument('--recovery-console', action='store_true')
    parser.add_argument('--drm-device', type=Path)
    parser.add_argument('--connector', action='append', default=[])
    parser.add_argument('--compositor', type=Path, default=ROOT / 'zig-out/bin/aqueous')
    parser.add_argument('--helper', type=Path, default=ROOT.parent / 'settingsApplication/zig-out/bin/aqueous-config')
    parser.add_argument('--fault-injection', action='store_true', help='Use a compositor built with output-retry-testing for backend fault cases')
    parser.add_argument('--driver', type=Path, help='Matching test-only helper with crash checkpoints')
    parser.add_argument('--wlroots-lib', type=Path)
    parser.add_argument('--artifacts', type=Path)
    args = parser.parse_args()
    if args.simulate and args.run_sdr:
        raise ValueError('--simulate and --run-sdr are mutually exclusive')
    if args.simulate:
        args.connector = ['HEADLESS-1', 'HEADLESS-2']
    if args.run_sdr:
        prerequisites(args, os.environ)
    work = args.artifacts or Path(tempfile.mkdtemp(prefix='aqueous-physical-preview-'))
    work.mkdir(parents=True, exist_ok=True)
    report_path = work / 'report.json'
    if report_path.exists():
        raise ValueError('Use a new artifact directory; acceptance evidence is never overwritten')
    report = dict(version=1, group='headless-simulation' if args.simulate else 'drm-sdr', acceptance_complete=False,
                  production_enabled=False, hardware_exercised=False,
                  inventory=inventory(), cases={name: dict(status='not_run') for name in REQUIRED})
    def save():
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    save()
    print(f'Artifacts: {work}', flush=True)
    if not args.run_sdr and not args.simulate:
        print('Inventory only. No compositor started; hardware acceptance remains pending.')
        return
    compositor = args.compositor.resolve()
    helper = args.helper.resolve()
    report['binaries'] = {str(p): sha(p) for p in (compositor, helper)}
    report['revision'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    names = subprocess.check_output(['git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=ROOT.parent).decode().split('\0')
    report['source_files'] = {name: sha(ROOT.parent / name) for name in sorted(set(names))
                              if name and (ROOT.parent / name).is_file() and
                              (name.startswith(('compositor/aqueous/', 'compositor/patches/', 'compositor/protocol/', 'settingsApplication/src/'))
                               or name in ('compositor/build.zig', 'compositor/build.zig.zon', 'settingsApplication/build.zig', 'compositor/scripts/test-display-preview-physical.py'))}
    if args.wlroots_lib:
        library = args.wlroots_lib.resolve() / 'libwlroots-0.20.so'
        report['binaries'][str(library)] = sha(library)
    report['working_diff_sha256'] = hashlib.sha256(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=ROOT)).hexdigest()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'WLR_'))}
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD'):
        env.pop(key, None)
    for variable, name in (('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'), ('XDG_STATE_HOME', 'state'),
                           ('XDG_CACHE_HOME', 'cache'), ('XDG_RUNTIME_DIR', 'run')):
        directory = work / name
        directory.mkdir(mode=0o700)
        env[variable] = str(directory.resolve())
    env.update(WLR_BACKENDS='drm,libinput', WLR_DRM_DEVICES=str(args.drm_device), WLR_RENDERER='vulkan',
               AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_OUTPUTS=','.join(args.connector),
               PATH=str(compositor.parent) + ':' + env['PATH'])
    if args.wlroots_lib:
        env['LD_LIBRARY_PATH'] = str(args.wlroots_lib.resolve())
    if args.simulate:
        env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman')
        env.pop('WLR_DRM_DEVICES', None)
    cfg = work / 'config/aqueous'
    cfg.mkdir()
    for name in ('wm', 'outputs', 'rules', 'input', 'layout', 'keybinds'):
        (cfg / f'{name}.toml').write_text('')
    report['helper'] = json.loads(subprocess.check_output([str(helper), 'version', '--json'], env=env, text=True))
    processes, clients, logs = [], [], []
    proc = query = None
    counter = 0

    def wait(predicate, seconds=8):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if proc is not None and proc.poll() is not None:
                raise AssertionError('Compositor exited; inspect its log and recovery console')
            value = predicate()
            if value:
                return value
            time.sleep(.05)
        raise AssertionError('Completion deadline exceeded')

    def start():
        nonlocal proc, query, counter
        counter += 1
        socket_file = work / 'run/socket'
        socket_file.unlink(missing_ok=True)
        boot = {k: v for k, v in env.items() if k not in ('AQUEOUS_SOCKET', 'WAYLAND_DISPLAY')}
        log = (work / f'compositor-{counter}.log').open('w'); logs.append(log)
        proc = subprocess.Popen(['dbus-run-session', '--', str(compositor), '-no-xwayland', '-log-level', 'debug',
                                 '-c', 'printenv AQUEOUS_SOCKET WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/socket"'],
                                env=boot, stdout=log, stderr=log, start_new_session=True)
        processes.append(proc)
        lines = wait(lambda: socket_file.read_text().splitlines() if socket_file.exists() and len(socket_file.read_text().splitlines()) == 2 else None)
        env.update(AQUEOUS_SOCKET=lines[0], WAYLAND_DISPLAY=lines[1])
        query = Client(lines[0]); clients.append(query)
        current = wait(lambda: (m if (m := model())['observation'] == 'current' else None))
        assert {o['connector'] for o in current['outputs']} == set(args.connector), 'Select all participating connectors'
        if args.simulate:
            assert all(o['preview_backend'] == 'headless' and not o['preview_acceptance_only'] for o in current['outputs'])
        else:
            assert all(o['preview_backend'] == 'drm' and o['preview_acceptance_only'] for o in current['outputs']), 'Use the isolated acceptance build'
        assert not query.capabilities['capabilities']['display_preview_hardware']
        if not args.simulate:
            assert query.capabilities['capabilities']['display_preview_acceptance_build']
        # dbus-run-session owns the process group; the compositor log records
        # the selected Vulkan device/driver and backend startup.
        report['hardware_exercised'] = not args.simulate
        return current

    def model():
        return query.call('display.snapshot')['result']

    def actual():
        return {o['connector']: o['actual'] for o in model()['outputs']}

    def call_helper(op, request=None, operation=None, crash=None):
        command = [str(args.driver.resolve() if crash else helper), op, '--shell', 'none']
        if request is not None:
            command += ['--request', '-']
        if operation:
            command += ['--operation-id', operation]
            if op == 'apply':
                command += ['--result', 'v1']
        result = subprocess.run(command, input=json.dumps(request) if request else None, env=env | ({'AQUEOUS_TEST_CRASH_AT': crash} if crash else {}),
                                text=True, capture_output=True, timeout=35)
        if crash:
            assert result.returncode == 97, (result.returncode, result.stdout, result.stderr)
            return
        value = json.loads(result.stdout)
        assert value['ok'], value
        return value

    def begin(fields, rejected=False, terminal='previewing'):
        m = wait(lambda: (v if (v := model())['observation'] == 'current' else None))
        snap = call_helper('snapshot')
        # Exercise the negotiated declaration API, preserving source ownership.
        request = dict(protocol=1, protected_apply=True, expected_generation=snap['generation'],
                       display_declaration_changes=dict(version=1, sources={'outputs': snap['display_source_ids']['outputs']},
                           operations=[dict(op='add', source='outputs', kind='output', parent=None,
                                            set=dict(name=args.connector[0], **fields))]))
        validated = call_helper('validate', request)
        assert validated['candidate_impact']['complete'], validated['candidate_impact']
        review = validated['candidate_review']
        params = dict(display_revision=m['display_revision'], expected_generation=snap['generation'],
                      candidate_digest=review['candidate_digest'], wm_source=validated['raw_files']['wm'],
                      outputs_source=validated['raw_files']['outputs'])
        owner = Client(env['AQUEOUS_SOCKET']); clients.append(owner)
        response = owner.call('display.preview.begin', params, ok=not rejected)
        if rejected:
            return response
        lease = response['result']
        token = lease['token']
        wait(lambda: status(token)['state'] == terminal)
        request.update(preview_token=token, candidate_digest=params['candidate_digest'])
        return owner, token, request

    def status(token):
        return query.call('display.preview.status', dict(token=token))['result']

    def reverted(token, before):
        result = wait(lambda: (v if (v := status(token))['state'] in ('reverted', 'invalidated', 'failed') else None), 20)
        assert result['state'] == 'reverted' and not result['rollback_partial'] and not result['fallback_used'], result
        assert actual() == before
        assert all(o['restored'] and o['hardware_matches'] for o in result['affected_outputs'])
        return result

    def restart():
        for client in clients:
            client.close()
        clients.clear()
        os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=5)
        return start()

    def record(name, action):
        try:
            report['cases'][name] = dict(status='passed', evidence=action())
        except BaseException as exc:
            report['cases'][name] = dict(status='failed', error=str(exc))
            raise
        finally:
            save()

    try:
        report['initial_snapshot'] = start(); save()
        output = next(o for o in model()['outputs'] if o['connector'] == args.connector[0])
        changes = {'placement': {'position': [output['actual']['x'] + 40, output['actual']['y']]},
                   'scale': {'scale': 1.25 if output['actual']['scale'] != 1.25 else 1},
                   'transform': {'transform': '90' if output['actual']['transform'] != '90' else 'normal'}}
        modes = [m for m in output['modes'] if m != output['actual']['mode'] and
                 (m['width'], m['height'], m['refresh_mhz']) != tuple(output['actual']['mode'][k] for k in ('width', 'height', 'refresh_mhz'))]
        if modes:
            mode = modes[0]
            changes['mode'] = {'mode': f"{mode['width']}x{mode['height']}@{mode['refresh_mhz']/1000:.3f}"}
        if len(args.connector) > 1:
            changes['enable'] = {'enabled': False}
        for name, fields in changes.items():
            def exercise(fields=fields):
                before = actual(); files = {p.name: sha(p) for p in cfg.glob('*.toml')}
                _, token, _ = begin(fields)
                observed = model()
                query.call('display.preview.revert', dict(token=token))
                result = reverted(token, before)
                assert files == {p.name: sha(p) for p in cfg.glob('*.toml')}
                return dict(candidate=observed, rollback=result)
            record('revert-' + name, exercise)
        if args.fault_injection:
            def fault(action):
                with socket.socket(socket.AF_UNIX) as channel:
                    channel.settimeout(5); channel.connect(str(work / 'run/aqueous/outputd.sock'))
                    channel.sendall(json.dumps(dict(op='test_output_retry', name=args.connector[0], action=action)).encode()+b'\n')
                    result=json.loads(channel.makefile().readline())
                    assert result['ok'],result
            def failed_test():
                before=actual(); fault('preview_test_failure')
                response=begin(changes['scale'],rejected=True)
                assert actual()==before
                return response
            record('failed-test',failed_test)
            # begin() normally waits for previewing. Failure injection uses the
            # same validated structured request, but reaches invalidated instead.
            for case, action in [('failed-commit','preview_commit_failure'),('partial-multi-output-commit','preview_partial_commit')]:
                if case=='partial-multi-output-commit' and len(args.connector)<2:
                    continue
                def failed_commit(action=action):
                    before=actual(); fault(action)
                    _,token,_=begin(changes['scale'], terminal='invalidated')
                    result=status(token)
                    assert actual()==before and all(o['restored'] and o['hardware_matches'] for o in result['affected_outputs']),result
                    return result
                record(case,failed_commit)
        for name in ('timeout', 'owner-disconnect'):
            def exercise(name=name):
                before = actual(); owner, token, _ = begin(changes['placement'])
                if name == 'owner-disconnect':
                    owner.close(); clients.remove(owner)
                return reverted(token, before)
            record(name, exercise)
        def keep():
            _, token, request = begin(changes['placement'])
            operation = str(int(time.time())) + '-' + uuid.uuid4().hex
            receipt = call_helper('apply', request, operation)
            assert receipt['display'] == 'kept' and status(token)['state'] == 'kept', receipt
            assert call_helper('operation-status', operation=operation) == receipt
            return receipt
        record('keep', keep)
        stages = [('restart-preview', None, True)]
        if args.driver:
            report['binaries'][str(args.driver.resolve())] = sha(args.driver)
            stages += [('helper-prepared', 'journal_prepared', False), ('helper-committed', 'journal_committed', False),
                       ('restart-prepared', 'journal_prepared', True), ('restart-committed', 'journal_committed', True)]
        for name, stage, reboot in stages:
            def exercise(stage=stage, reboot=reboot):
                before = {p.name: p.read_text() for p in cfg.glob('*.toml')}
                before_actual = actual()
                _, token, request = begin({'position': [actual()[args.connector[0]]['x'] + 20, 0]})
                candidate_actual = actual()
                operation = str(int(time.time())) + '-' + uuid.uuid4().hex
                if stage:
                    call_helper('apply', request, operation, stage)
                previous_session = query.session
                if reboot:
                    start_model = restart()
                    assert query.session != previous_session
                    assert not query.call('display.preview.status', dict(token=token), ok=False)['ok']
                else:
                    wait(lambda: status(token)['state'] in ('kept', 'invalidated'), 15)
                    start_model = model()
                after = {p.name: p.read_text() for p in cfg.glob('*.toml')}
                assert (after != before) == (stage == 'journal_committed')
                assert actual() == (candidate_actual if stage == 'journal_committed' else before_actual)
                receipt = call_helper('operation-status', operation=operation) if stage else None
                query.command('session.reload')
                wait(lambda: model()['config_generation'] == call_helper('snapshot')['generation'])
                return dict(recovered_snapshot=start_model, files=after, receipt=receipt)
            record(name, exercise)
        print('Automated SDR cases finished. Review report.json: unrun cases still block hardware acceptance.')
    finally:
        report['final_inventory'] = inventory(); save()
        for client in clients:
            client.close()
        for child in reversed(processes):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
        for log in logs:
            log.close()


if __name__ == '__main__':
    main()
