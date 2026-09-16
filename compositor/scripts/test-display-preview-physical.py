#!/usr/bin/env python3
"""Inventory physical preview prerequisites, or exercise selected HDR/VRR/SDR groups in a disposable DRM session.

A report from this harness does not enable production hardware previews. Unrun
fault/manual cases remain explicit acceptance gaps.
"""
import argparse
import hashlib
import importlib.util
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
    'rollback-fallback', 'rollback-failure', 'delayed-presentation',
    'rejected-presentation', 'session-loss', 'negative-rotated-secondary',
    'raw-equivalence', 'profile-equivalence', 'reference-workload',
    'visual-hdr', 'panel-vrr', 'mixed-heads', 'unsupported-mode',
    'baseline-keep', 'transition-on', 'transition-off',

)


GROUPS = ('sdr', 'hdr', 'vrr', 'hdr_vrr', 'auto_hdr')


def group_fields(group, enabled=True):
    return {
        'sdr': {}, 'hdr': {'hdr': enabled}, 'vrr': {'adaptive_sync': enabled},
        'hdr_vrr': {'hdr': enabled, 'adaptive_sync': enabled},
        'auto_hdr': {'hdr': True, 'auto_hdr': enabled},
    }[group]


def transition_cases(group):
    cases = {'transition-off': group_fields(group, False)} if group != 'sdr' else {}
    if group in ('hdr', 'hdr_vrr', 'auto_hdr'):
        cases.update({'hdr-peak': {'hdr_level': '400'}, 'hdr-auto-peak': {'hdr_level': 'auto'},
                      'sdr-white': {'sdr_white_level': 350}})
    if group == 'hdr_vrr':
        cases.update({'hdr-off-vrr-on': {'hdr': False}, 'vrr-off-hdr-on': {'adaptive_sync': False}})
    if group == 'auto_hdr':
        cases.update({'auto-boost-zero': {'auto_hdr_boost': 0}, 'auto-boost-full': {'auto_hdr_boost': 1}})
    return cases


def required_cases(group, simulate=False, reference=False):
    names = list(REQUIRED)
    if group == 'sdr':
        for name in ('transition-on', 'transition-off', 'visual-hdr', 'panel-vrr'):
            names.remove(name)
    else:
        names.extend(name for name in transition_cases(group) if name not in names)
        if group not in ('hdr', 'hdr_vrr', 'auto_hdr'): names.remove('visual-hdr')
        if group not in ('vrr', 'hdr_vrr'): names.remove('panel-vrr')
    if group == 'hdr_vrr': names.append('combined-across-heads')
    if group == 'sdr' and not reference: names.remove('reference-workload')
    if simulate: names.remove('unsupported-mode')  # Headless accepts custom modes.
    return names


def summarize(cases):
    return {status: [name for name, result in cases.items() if result['status'] == status]
            for status in ('passed', 'failed', 'unsupported', 'not_run')}


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
        raise ValueError('Physical execution requires --dedicated-seat and --recovery-console')
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
    parser.add_argument('--run-group', choices=GROUPS, help='Physical feature group; each run needs fresh artifacts')
    parser.add_argument('--reference-client', type=Path, help='Prebuilt preview-reference; otherwise compile in artifacts')
    parser.add_argument('--visual-seconds', type=int, default=0, help='Leave baseline and reference scene visible for manual observation after tests')
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
    if args.run_sdr and args.run_group:
        raise ValueError("Select --run-sdr or --run-group")
    group = args.run_group or "sdr"
    physical = args.run_sdr or args.run_group is not None
    if args.visual_seconds < 0:
        raise ValueError("--visual-seconds must be nonnegative")
    if args.simulate and physical:
        raise ValueError('--simulate cannot be combined with physical --run-sdr/--run-group')
    if args.simulate:
        args.connector = ['HEADLESS-1', 'HEADLESS-2']
    if physical:
        prerequisites(args, os.environ)
    work = args.artifacts or Path(tempfile.mkdtemp(prefix='aqueous-physical-preview-'))
    work.mkdir(parents=True, exist_ok=True)
    report_path = work / 'report.json'
    if report_path.exists():
        raise ValueError('Use a new artifact directory; acceptance evidence is never overwritten')
    report = dict(version=1, group='headless-simulation' if args.simulate else 'drm-' + group, acceptance_complete=False,
                  production_enabled=False, hardware_exercised=False,
                  inventory=inventory(), cases={name: dict(status='not_run') for name in required_cases(group, args.simulate, args.reference_client is not None)})
    def save():
        report['summary'] = summarize(report['cases'])
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    save()
    print(f'Artifacts: {work}', flush=True)
    if not physical and not args.simulate:
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
                               or name in ('compositor/build.zig', 'compositor/build.zig.zon', 'settingsApplication/build.zig', 'compositor/scripts/test-display-preview-physical.py', 'compositor/scripts/build-preview-reference.py', 'compositor/scripts/fixtures/preview-reference-client.c'))}
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
               AQUEOUS_DISPLAY_PREVIEW_ACCEPTANCE_FEATURES=group,
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
    workload = None
    workload_counter = 0

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

    def begin(fields, rejected=False, terminal='previewing', connector=None, form='structured'):
        m = wait(lambda: (v if (v := model())['observation'] == 'current' else None))
        snap = call_helper('snapshot')
        # Exercise the negotiated declaration API, preserving source ownership.
        request = dict(protocol=1, protected_apply=True, expected_generation=snap['generation'],
                       display_declaration_changes=dict(version=1, sources={'outputs': snap['display_source_ids']['outputs']},
                           operations=[dict(op='add', source='outputs', kind='output', parent=None,
                                            set=dict(name=connector or args.connector[0], **fields))]))
        def validate_current():
            result = call_helper('validate', request)
            impact = result['candidate_impact']
            if not rejected and not impact['complete'] and impact['display'] is None:
                return None
            return result
        validated = wait(validate_current)
        if form == 'raw':
            request.pop('display_declaration_changes')
            request['raw_files'] = {key: validated['raw_files'][key] for key in ('wm', 'outputs')}
            raw = call_helper('validate', request)
            assert raw['candidate_review']['candidate_digest'] == validated['candidate_review']['candidate_digest']
            validated = raw
        elif form == 'profile':
            # Force a fallback profile in both raw and structured representations.
            # Replace only the disposable run's output document for this preview.
            def toml(fields):
                return ''.join(key + ' = ' + json.dumps(value) + '\n' for key, value in fields.items())
            text = '[display]\nfallback_profile = "reference"\n[[output]]\nname = "DISCONNECTED"\nscale = 1.0\n'
            text += '[[display.profile]]\nname = "reference"\n[[display.profile.output]]\n'
            text += toml(dict(name=connector or args.connector[0], **fields))
            request.pop('display_declaration_changes')
            request['raw_files'] = {'outputs': text}
            validated = call_helper('validate', request)
            structured = dict(protocol=1, expected_generation=snap['generation'], protected_apply=True,
                display_declaration_changes=dict(version=1, sources={'outputs':snap['display_source_ids']['outputs']},
                    operations=[dict(op='delete', source='outputs', id=d['id'], **({'members':'delete'} if d['kind']=='profile' else {}))
                        for d in snap['display_declarations'] if d['source']=='outputs' and d['parent_id'] is None] + [
                        dict(op='add',source='outputs',kind='policy',set={'fallback_profile':'reference'}),
                        dict(op='add',source='outputs',kind='output',parent=None,set={'name':'DISCONNECTED', 'scale':1.0}),
                        dict(op='add',source='outputs',kind='profile',ref='reference',set={'name':'reference'}),
                        dict(op='add',source='outputs',kind='output',parent='new:reference',set=dict(name=connector or args.connector[0], **fields))]))
            compared = call_helper('validate', structured)
            assert compared['candidate_impact']['display']['effective_outputs'] == validated['candidate_impact']['display']['effective_outputs']
        if not rejected:
            assert validated['candidate_impact']['complete'], validated['candidate_impact']
        m = wait(lambda: (v if (v := model())['observation'] == 'current' else None))
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

    def evidence(token):
        return query.call('display.preview.evidence', dict(token=token))['result']

    def status(token):
        return query.call('display.preview.status', dict(token=token))['result']

    def reverted(token, before):
        result = wait(lambda: (v if (v := status(token))['state'] in ('reverted', 'invalidated', 'failed') else None), 20)
        assert result['state'] == 'reverted' and not result['rollback_partial'] and not result['fallback_used'], result
        assert actual() == before
        assert all(o['restored'] and o['hardware_matches'] for o in result['affected_outputs'])
        return dict(lease=result, features=evidence(token))

    def restart():
        for client in clients:
            client.close()
        clients.clear()
        os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=5)
        current = start()
        start_workload()
        return current

    def record(name, action):
        try:
            report['cases'][name] = dict(status='passed', evidence=action())
        except BaseException as exc:
            report['cases'][name] = dict(status='failed', error=str(exc))
            raise
        finally:
            # Each case owns a lease connection. Release terminal owners so the
            # next helper can connect within the native server's client bound.
            for client in clients[:]:
                if client is not query:
                    client.close(); clients.remove(client)
            save()

    def exercise(fields, connector=None, form='structured'):
        before = actual(); files = {p.name: sha(p) for p in cfg.glob('*.toml')}
        _, token, _ = begin(fields, connector=connector, form=form)
        observed = model(); target = evidence(token)
        actual_target = next(o['actual'] for o in observed['outputs'] if o['connector'] == (connector or args.connector[0]))
        for key, value in fields.items():
            if key == 'position': assert [actual_target['x'], actual_target['y']] == value
            elif key == 'hdr_level' and value != 'auto': assert actual_target[key] == int(value)
            elif key in ('hdr', 'adaptive_sync', 'auto_hdr', 'auto_hdr_boost', 'sdr_white_level', 'scale', 'transform', 'enabled'):
                assert actual_target[key] == value, (key, actual_target)
        assert all(o['observed']['target_matches'] and
                   (not o['target']['enabled'] or o['observed']['presented']) for o in target['outputs'])
        query.call('display.preview.revert', dict(token=token))
        result = reverted(token, before)
        assert files == {p.name: sha(p) for p in cfg.glob('*.toml')}
        if fields.get('enabled') is False:
            start_workload()  # Move the reference back to the restored primary.
        return dict(candidate=observed, presentation=target, rollback=result, config_digests=files)

    def keep_fields(fields):
        _, token, request = begin(fields)
        target = evidence(token)
        operation = str(int(time.time())) + '-' + uuid.uuid4().hex
        receipt = call_helper('apply', request, operation)
        assert receipt['display'] == 'kept' and status(token)['state'] == 'kept', receipt
        assert call_helper('operation-status', operation=operation) == receipt
        return dict(receipt=receipt, presentation=target)

    def recovery_fields():
        current = actual()[args.connector[0]]
        if group == 'sdr':
            return {'scale': 1.25 if current['scale'] != 1.25 else 1.0}
        key = 'auto_hdr' if group == 'auto_hdr' else 'adaptive_sync' if group == 'vrr' else 'hdr'
        fields = {key: not current[key], 'scale': 1.25 if current['scale'] != 1.25 else 1.0}
        if group == 'hdr_vrr': fields['adaptive_sync'] = not current['adaptive_sync']
        return fields

    def start_workload():
        nonlocal workload, workload_counter
        if not reference:
            return
        if workload is not None and workload.poll() is None:
            workload.terminate(); workload.wait(timeout=5)
        scene = 'hdr' if group in ('hdr', 'hdr_vrr') else 'sdr'
        workload_counter += 1
        reference_log = work / f'reference-{counter}-{workload_counter}.jsonl'
        log = reference_log.open('w'); logs.append(log)
        workload = subprocess.Popen([str(reference), scene, str(max(300, args.visual_seconds + 180))],
                                    env=env, stdout=log, stderr=log, start_new_session=True)
        processes.append(workload)
        def ready():
            assert workload.poll() is None, 'Reference client exited; inspect reference log'
            return '"ready":true' in reference_log.read_text()
        wait(ready)

    reference = None
    if args.reference_client or (physical and group != 'sdr'):
        if args.reference_client:
            reference = args.reference_client.resolve()
        else:
            spec = importlib.util.spec_from_file_location('reference_builder', Path(__file__).with_name('build-preview-reference.py'))
            builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
            reference = builder.build(work / 'reference-build')
        report['binaries'][str(reference)] = sha(reference)

    try:
        report['initial_snapshot'] = start()
        report['feature_policy'] = query.call('display.preview.features')['result']
        selected = next(o for o in report['feature_policy']['outputs'] if o['connector'] == args.connector[0])
        support = selected['features'][group]['transition']
        if support['status'] not in ('available', 'acceptance_only'):
            report['cases']['baseline-keep'] = dict(status='unsupported', reason=support['reason'])
            print('Selected group is unavailable; see report.json for the capability reason.')
            return
        if group != 'sdr':
            record('transition-on', lambda: exercise(group_fields(group)))
        record('baseline-keep', lambda: keep_fields(dict(primary=True, **group_fields(group))))
        start_workload()
        save()
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
            record('revert-' + name, lambda fields=fields: exercise(fields))
        for name, fields in transition_cases(group).items():
            record(name, lambda fields=fields: exercise(fields))
        record('raw-equivalence', lambda: exercise(dict(group_fields(group), scale=1.25), form='raw'))
        record('profile-equivalence', lambda: exercise(dict(group_fields(group), scale=1.25), form='profile'))
        if len(args.connector) > 1:
            record('negative-rotated-secondary', lambda: exercise({'position':[3880,-920], 'transform':'90'}, connector=args.connector[1]))
            record('mixed-heads', lambda: exercise(changes['placement'], connector=args.connector[1]))
        if group == 'hdr_vrr' and len(args.connector) > 1:
            second = next(o for o in report['feature_policy']['outputs'] if o['connector'] == args.connector[1])
            if second['vrr_capable']:
                # HDR on the first head and VRR on the second require the union group.
                keep_fields({'adaptive_sync':False})
                record('combined-across-heads', lambda: exercise({'adaptive_sync':True}, connector=args.connector[1]))
                keep_fields(group_fields(group))
            else:
                report['cases']['combined-across-heads'] = dict(status='unsupported', reason='second_head_vrr_unsupported')
        if not args.simulate:
            def unavailable_mode():
                before = actual()
                result = begin({'mode':'1x1@1'}, rejected=True)
                assert result['error']['code'] == 'mode_not_advertised', result
                assert actual() == before
                return result
            record('unsupported-mode', unavailable_mode)
        if args.fault_injection:
            def fault(action, **fields):
                with socket.socket(socket.AF_UNIX) as channel:
                    channel.settimeout(5); channel.connect(str(work / 'run/aqueous/outputd.sock'))
                    channel.sendall(json.dumps(dict(op='test_output_retry', name=args.connector[0], action=action, **fields)).encode()+b'\n')
                    result=json.loads(channel.makefile().readline())
                    assert result['ok'],result
            def failed_test():
                before=actual(); fault('preview_test_failure')
                response=begin(recovery_fields(),rejected=True)
                assert actual()==before
                return response
            def both_directions(action):
                if group == 'sdr': return [action()]
                results = []
                for enabled in (False, True):
                    keep_fields(group_fields(group, enabled))
                    results.append(dict(baseline_enabled=enabled, result=action()))
                return results
            record('failed-test', lambda: both_directions(failed_test))
            # begin() normally waits for previewing. Failure injection uses the
            # same validated structured request, but reaches invalidated instead.
            for case, action in [('failed-commit','preview_commit_failure'),('partial-multi-output-commit','preview_partial_commit')]:
                if case=='partial-multi-output-commit' and len(args.connector)<2:
                    continue
                def failed_commit(action=action):
                    before=actual(); fault(action)
                    _,token,_=begin(recovery_fields(), terminal='invalidated')
                    result=status(token)
                    assert actual()==before and all(o['restored'] and o['hardware_matches'] for o in result['affected_outputs']),result
                    return result
                record(case, lambda: both_directions(failed_commit))
            def delayed():
                before = actual(); fault('preview_hold_completion', hold=True)
                _, token, _ = begin(recovery_fields(), terminal='applying')
                time.sleep(.2)
                assert status(token)['state'] == 'applying' and not status(token)['supported_actions']['commit']
                fault('preview_hold_completion', hold=False)
                wait(lambda: status(token)['state'] == 'previewing')
                target = evidence(token)
                query.call('display.preview.revert', dict(token=token))
                return dict(target=target, restored=reverted(token, before))
            record('delayed-presentation', delayed)
            def rejected_present():
                before = actual(); fault('preview_reject_present')
                _, token, _ = begin(recovery_fields(), terminal='invalidated')
                assert actual() == before and status(token)['reason'] == 'presentation_failed'
                return dict(lease=status(token), restored=evidence(token))
            record('rejected-presentation', rejected_present)
            def session_loss():
                before = actual(); _, token, _ = begin(recovery_fields())
                fault('preview_session_inactive', inactive=True)
                wait(lambda: status(token)['state'] == 'waiting_session')
                assert not status(token)['supported_actions']['commit']
                fault('preview_session_inactive', inactive=False)
                wait(lambda: status(token)['state'] == 'invalidated')
                assert actual() == before
                return dict(lease=status(token), restored=evidence(token))
            record('session-loss', session_loss)
        for name in ('timeout', 'owner-disconnect'):
            def lifecycle(name=name):
                before = actual(); owner, token, _ = begin(recovery_fields())
                if name == 'owner-disconnect':
                    owner.close(); clients.remove(owner)
                return reverted(token, before)
            record(name, lifecycle)
        record('keep', lambda: keep_fields(recovery_fields()))
        stages = [('restart-preview', None, True)]
        if args.driver:
            report['binaries'][str(args.driver.resolve())] = sha(args.driver)
            stages += [('helper-prepared', 'journal_prepared', False), ('helper-committed', 'journal_committed', False),
                       ('restart-prepared', 'journal_prepared', True), ('restart-committed', 'journal_committed', True)]
        for name, stage, reboot in stages:
            def crash_recovery(stage=stage, reboot=reboot):
                before = {p.name: p.read_text() for p in cfg.glob('*.toml')}
                before_actual = actual()
                _, token, request = begin(recovery_fields())
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
            record(name, crash_recovery)
        # Destructive recovery faults run last and restore the canonical baseline
        # through restart; the report never calls fallback exact restoration.
        if args.fault_injection:
            for name, fail_all in [('rollback-fallback', False), ('rollback-failure', True)]:
                def recovery_fault(fail_all=fail_all):
                    _, token, _ = begin(recovery_fields())
                    fault('preview_fail_all_tests', fail=True) if fail_all else fault('preview_test_failure')
                    query.call('display.preview.revert', dict(token=token))
                    result = wait(lambda: (v if (v := status(token))['state'] in ('invalidated','failed') else None))
                    observed = evidence(token)
                    if fail_all:
                        assert result['state'] == 'failed', result
                        fault('preview_fail_all_tests', fail=False)
                    else:
                        assert result['fallback_used'] and result['rollback_partial'], result
                        assert all(not o['actual']['hdr'] and not o['actual']['auto_hdr'] and not o['actual']['adaptive_sync']
                                   for o in model()['outputs'] if o['actual']['enabled'])
                    restart()
                    return dict(lease=result, observed=observed, recovery=model())
                record(name, recovery_fault)
        if workload:
            assert workload.poll() is None, 'Reference workload exited; inspect reference log'
            report['cases']['reference-workload'] = dict(status='passed', evidence='reference-*.jsonl; submitted cadence only')
        if args.visual_seconds:
            keep_fields(group_fields(group))
            start_workload()
            print(f'Baseline/reference visible for {args.visual_seconds}s. Record visual/panel observations separately.', flush=True)
            end = time.monotonic() + args.visual_seconds
            while time.monotonic() < end:
                time.sleep(max(0, min(1, end - time.monotonic())))
                assert proc.poll() is None
        print('Automated cases finished. Review report.json: unrun/manual cases still block hardware acceptance.')
    except BaseException as exc:
        report['run_error'] = str(exc)
        raise
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
