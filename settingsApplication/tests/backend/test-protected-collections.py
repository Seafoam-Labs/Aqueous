#!/usr/bin/env python3
"""Protected collection contracts with isolated sources, receipts and race hooks."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HELPER, DRIVER = (str(Path(p).resolve()) for p in sys.argv[1:3])
NAMES = ('wm', 'layout', 'input', 'outputs', 'rules', 'appearance')
RULE = '[[window]]\napp_id = "pearl-test-*"\nfloating = false\n'
SCHEMA = None
if '--schema' in sys.argv:
    import jsonschema
    SCHEMA = json.loads((Path(__file__).resolve().parents[2] / 'docs/aqueous-config-additions-v1.schema.json').read_text())
    jsonschema.Draft202012Validator.check_schema(SCHEMA)


class Fixture:
    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aqueous-protected-collections-')
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('AQUEOUS_', 'NOCTALIA_')) and k not in
                    ('DBUS_SESSION_BUS_ADDRESS', 'DISPLAY', 'WAYLAND_DISPLAY', 'LD_PRELOAD')}
        for key, name in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                          ('XDG_STATE_HOME', 'state'), ('XDG_RUNTIME_DIR', 'runtime')]:
            p = self.root / name
            p.mkdir(mode=0o700)
            self.env[key] = str(p)
        self.env.update(DISPLAY='', WAYLAND_DISPLAY='absent-protected-collections', GSETTINGS_BACKEND='memory')
        cfg = self.root / 'config/aqueous'
        cfg.mkdir()
        self.files = {name: cfg / (name + '.toml') for name in NAMES}
        for name, path in self.files.items():
            path.write_text(RULE if name == 'rules' else '')
            self.env['AQUEOUS_CONFIG' if name == 'wm' else 'AQUEOUS_' + name.upper()] = str(path)
        bindir = self.root / 'bin'
        bindir.mkdir()
        ctl = bindir / 'aqueousctl'
        ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; elif [ "$1" = cursor ]; then echo "{}"; elif [ "$1" = session ] && [ "$2" = reload ]; then\n'
                       'echo reload >> "$XDG_STATE_HOME/reloads"\n'
                       'echo \'{"ok":true,"status":"applied","sequence":"1"}\'\nfi\n')
        ctl.chmod(0o755)
        self.env['PATH'] = str(bindir) + ':' + os.environ['PATH']
        return self

    def __exit__(self, *args):
        self.tmp.cleanup()

    def run(self, op, req=None, flags=(), executable=HELPER, env=None):
        cmd = [executable, op, '--shell', 'none', *flags]
        if req is not None:
            cmd += ['--request', '-']
        return subprocess.run(cmd, input=None if req is None else json.dumps(req), text=True,
                              capture_output=True, env=env or self.env, timeout=35)

    def call(self, op, req=None, flags=(), code=None):
        p = self.run(op, req, flags)
        assert p.stdout, (p.returncode, p.stderr)
        result = json.loads(p.stdout)
        if code is None:
            assert result['ok'], (op, result, p.stderr)
        else:
            assert not result['ok'], result
            actual = result['failure']['code'] if 'result_version' in result else result['code']
            assert actual == code, (code, result)
        if SCHEMA and result['ok'] and op != 'version':
            jsonschema.Draft202012Validator(SCHEMA).validate(result)
        return result

    def request(self, snap=None, **mutations):
        snap = snap or self.call('snapshot')
        if not mutations:
            mutations = {'window_rule_changes': [dict(id=snap['window_rules'][0]['id'], values={'floating': True})]}
        names = set()
        for key in mutations:
            names.add('rules' if key == 'window_rule_changes' else 'wm' if key == 'custom_keybind_changes' else 'layout')
        return dict(protocol=1, collection_apply_version=1, protected_apply=True,
                    expected_generation=snap['generation'],
                    collection_preconditions_v2=dict(version=2, sources={name: snap['collection_preconditions_v2']['sources'][name] for name in names}),
                    **mutations)

    def review(self, req):
        if SCHEMA:
            schema = dict(SCHEMA, **{'oneOf': [{'$ref': '#/$defs/protected_collection_request'}]})
            jsonschema.Draft202012Validator(schema).validate(req)
        result = self.call('validate', req)
        report = result['collection_transaction']
        assert report['requested_generation'] == req['expected_generation']
        assert report['candidate_digest'] == result['candidate_impact']['candidate_digest'] == result['candidate_review']['candidate_digest']
        assert report['effective_generation'] == result['candidate_impact']['original_generation']
        assert report['rebased'] == (report['requested_generation'] != report['effective_generation'])
        assert report['base_preconditions'] == req['collection_preconditions_v2']
        return result

    def approved(self, req):
        result = self.review(req)
        report = result['collection_transaction']
        return dict(req, expected_generation=report['effective_generation'],
                    collection_preconditions_v2=report['base_preconditions'], candidate_digest=report['candidate_digest'])

    def state(self):
        return ({name: path.read_bytes() if path.exists() else None for name, path in self.files.items()},
                self.reloads(), tuple(sorted((self.root / 'backups').glob('**/*'))))

    def reloads(self):
        p = self.root / 'state/reloads'
        return p.read_text() if p.exists() else ''

    def reject(self, req, code, op='apply'):
        before = self.state()
        self.call(op, req, code=code)
        assert self.state() == before, 'rejection changed a config, backup or reload'

    def opid(self):
        return f'{int(time.time())}-{uuid.uuid4().hex}'

    def paused(self, req, op='apply'):
        env = self.env | {'AQUEOUS_TEST_STOP_AT': 'collection_candidate_validated'}
        proc = subprocess.Popen([DRIVER, op, '--shell', 'none', '--request', '-'],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=env)
        proc.stdin.write(json.dumps(req))
        proc.stdin.close()
        proc.stdin = None
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            pid, status = os.waitpid(proc.pid, os.WNOHANG | os.WUNTRACED)
            if pid:
                assert os.WIFSTOPPED(status), (status, proc.stdout.read(), proc.stderr.read())
                return proc
            time.sleep(.01)
        proc.kill()
        proc.wait()
        raise AssertionError('driver did not reach candidate validation checkpoint')


with Fixture() as f:
    version = f.call('version')
    assert version['version'] == '0.8.3'
    assert {'protected_collection_apply_v1', 'collection_preconditions_v2'} <= set(version['capabilities'])
    req = f.request()
    reviewed = f.review(req)
    assert reviewed['candidate_impact']['complete']
    assert not reviewed['collection_transaction']['rebased']
    assert reviewed['generation'] != reviewed['collection_transaction']['effective_generation']
    f.reject(req, 'candidate_mismatch')
    req = dict(req, candidate_digest=reviewed['collection_transaction']['candidate_digest'])
    if SCHEMA:
        jsonschema.Draft202012Validator(dict(SCHEMA, **{'oneOf': [{'$ref': '#/$defs/protected_collection_apply_request'}]})).validate(req)
    saved = f.call('apply', req)
    assert saved['raw_files'] == reviewed['raw_files']
    assert f.reloads() == 'reload\n', repr(f.reloads())

# Custom scrolling fractions participate in the same digest-bound transaction.
with Fixture() as f:
    snap = f.call('snapshot')
    req = f.request(snap, window_rule_changes=[dict(id=snap['window_rules'][0]['id'], values={'scrolling_width': 0.65})])
    approved = f.approved(req)
    changed = dict(approved, window_rule_changes=[dict(id=snap['window_rules'][0]['id'], values={'scrolling_width': 0.25})])
    f.reject(changed, 'candidate_mismatch')
    saved = f.call('apply', approved)
    assert saved['window_rules'][0]['values']['scrolling_width'] == 0.65
    req = f.request(saved, window_rule_changes=[dict(id=saved['window_rules'][0]['id'], values={'scrolling_width': None})])
    saved = f.call('apply', f.approved(req))
    assert 'scrolling_width' not in saved['window_rules'][0]['values']

# IDs survive unrelated source changes; approval never follows automatically.
with Fixture() as f:
    req = f.request()
    old = f.review(req)
    f.files['outputs'].write_text('# unrelated edit before validation\n')
    new = f.review(req)
    assert new['collection_transaction']['rebased']
    assert new['collection_transaction']['candidate_digest'] != old['collection_transaction']['candidate_digest']
    f.reject(dict(req, candidate_digest=old['collection_transaction']['candidate_digest']), 'candidate_mismatch')
    # A stale requested generation is allowed when the freshly reviewed full
    # candidate matches and all source descriptors still prove ID identity.
    saved = f.call('apply', dict(req, candidate_digest=new['collection_transaction']['candidate_digest']))
    assert saved['collection_transaction']['rebased']
    assert saved['raw_files'] == new['raw_files']
with Fixture() as f:
    req = f.approved(f.request())
    f.files['appearance'].write_text('# unrelated edit after review\n')
    f.reject(req, 'candidate_mismatch')
    f.call('apply', f.approved(req))

for change in (lambda s: s.replace('false', 'true'), lambda s: '[[window]]\napp_id = "other"\n' + s):
    with Fixture() as f:
        req = f.approved(f.request())
        f.files['rules'].write_text(change(RULE))
        f.reject(req, 'external_change', 'validate')
        # Matching the new global generation cannot waive the source proof.
        req['expected_generation'] = f.call('snapshot')['generation']
        f.reject(req, 'external_change')

for initially_exists in (False, True):
    with Fixture() as f:
        path = f.files['rules']
        path.write_text('')
        if not initially_exists:
            path.unlink()
        req = f.approved(f.request(window_rule_changes=[dict(op='add', values={'app_id': '*'})]))
        old_generation = req['expected_generation']
        if initially_exists:
            path.unlink()
        else:
            path.write_text('')
        assert f.call('snapshot')['generation'] == old_generation
        f.reject(req, 'external_change')
        f.reject(req, 'external_change', 'validate')

# Source selection changes are conflicts even if the new source bytes match.
with Fixture() as f:
    del f.env['AQUEOUS_RULES']
    req = f.approved(f.request())
    other = f.root / 'alternate-rules.toml'
    other.write_text(RULE)
    f.files['wm'].write_text('[rules]\npath = ' + json.dumps(str(other)) + '\n')
    f.reject(req, 'external_change')
    assert other.read_text() == RULE

with Fixture() as f:
    req = f.approved(f.request())
    for value in (None, '', 'a' * 63, 'A' * 64, 'g' * 64, 7, '0' * 64):
        f.reject(dict(req, candidate_digest=value), 'candidate_mismatch')
    for value in ('', 'a' * 15, 'x' * 16):
        f.reject(dict(req, expected_generation=value), 'invalid_generation')
    for key, value in [('path', '/tmp/not-the-selected-file'), ('exists', False), ('digest', '0' * 64)]:
        bad = copy.deepcopy(req)
        bad['collection_preconditions_v2']['sources']['rules'][key] = value
        f.reject(bad, 'external_change')
    for key in ('path', 'exists', 'digest'):
        bad = copy.deepcopy(req)
        del bad['collection_preconditions_v2']['sources']['rules'][key]
        f.reject(bad, 'invalid_collection_preconditions')
    for value in ({}, dict(version=1, sources={}), dict(version=2, sources={}),
                  dict(version=2, sources={'rules': req['collection_preconditions_v2']['sources']['rules'], 'wm': f.call('snapshot')['collection_preconditions_v2']['sources']['wm']})):
        f.reject(dict(req, collection_preconditions_v2=value), 'invalid_collection_preconditions')
    bad = dict(req)
    del bad['collection_preconditions_v2']
    f.reject(bad, 'invalid_collection_preconditions')
    for addition in ({'collection_apply_version': 2}, {'protected_apply': False}, {'protected_apply': 'true'},
                     {'raw_files': {'rules': RULE}}, {'raw_files': {'input': ''}}, {'monitor_changes': []},
                     {'changes': []}, {'sync_cursor': False}, {'sync_typography': False}, {'preview_token': 'a' * 64},
                     {'candidate_impact': {'complete': True}}, {'collection_preconditions': {}},
                     {'default_snap_layout': 'work'}):
        f.reject(dict(req, **addition), 'invalid_collection_contract')
    bad = dict(req)
    del bad['collection_apply_version']
    f.reject(bad, 'invalid_collection_contract')
    noop = f.request(window_rule_changes=[])
    f.reject(noop, 'candidate_mismatch')
    f.call('apply', f.approved(noop))

with Fixture() as f:
    layouts = [dict(id='work', zones=[dict(id='full', x=0, y=0, width=1, height=1)])]
    req = f.request(snap_layouts=layouts, default_snap_layout='work',
                    window_rule_changes=[dict(id='rule:1', values={'floating': True})])
    req['backup_dir'] = str(f.root / 'backups')
    missing = copy.deepcopy(req)
    del missing['collection_preconditions_v2']['sources']['layout']
    f.reject(missing, 'invalid_collection_preconditions', 'validate')
    good = f.approved(req)
    f.files['layout'].write_text('# layout source changed\n')
    f.reject(good, 'external_change')
    fresh = f.request(snap_layouts=layouts, default_snap_layout='work',
                      window_rule_changes=[dict(id='rule:1', values={'floating': True})])
    fresh['backup_dir'] = str(f.root / 'backups')
    f.call('apply', f.approved(fresh))
    assert (f.root / 'backups').exists()
with Fixture() as f:
    req = f.request(custom_keybind_changes=[dict(op='add', chord='Super+F12', command='spawn:echo protected')])
    f.call('apply', f.approved(req))
with Fixture() as f:
    req = f.request(snap_zone_changes=[dict(id='a', x=0, y=0, width=1, height=1)])
    f.call('apply', f.approved(req))
with Fixture() as f:
    req = f.request(window_rule_changes=[dict(op='add', values={'app_id': '*', 'opacity': 2})])
    f.reject(req, 'invalid_value', 'validate')
with Fixture() as f:
    f.files['rules'].write_text(RULE + 'future = false\n')
    req = f.approved(f.request())
    f.reject(req, 'unclassified_candidate')

# Deterministic non-cooperating writer races after candidate validation, while
# a cooperating helper is still excluded by the same writer lock.
for op, change in [('apply', 'rules'), ('apply', 'outputs'), ('validate', 'rules'),
                   ('apply', 'existence'), ('validate', 'existence')]:
    with Fixture() as f:
        req = f.approved(f.request())
        if change == 'existence':
            f.files['input'].unlink()
        proc = f.paused(req, op)
        try:
            f.call('snapshot', code='config_writer_busy')
            if change == 'existence':
                f.files['input'].write_text('')
            else:
                f.files[change].write_text(f.files[change].read_text() + '# external race\n')
            before = f.state()
            os.kill(proc.pid, signal.SIGCONT)
            stdout, stderr = proc.communicate(timeout=20)
            result = json.loads(stdout)
            assert not result['ok'] and result['code'] == 'external_change', (result, stderr)
            assert f.state() == before
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

# Crashes and lost replies retain the fresh candidate binding and save decision.
for stage in ('collection_candidate_validated', 'journal_prepared', 'written_file_0',
              'journal_committed', 'operation_result'):
    with Fixture() as f:
        req = f.request()
        f.files['outputs'].write_text('# force a rebase\n')
        review = f.review(req)
        req['candidate_digest'] = review['collection_transaction']['candidate_digest']
        oid = f.opid()
        flags = ('--result', 'v1', '--operation-id', oid)
        p = f.run('apply', req, flags, DRIVER, f.env | {'AQUEOUS_TEST_CRASH_AT': stage})
        assert p.returncode == 97, (stage, p.stdout, p.stderr)
        status = f.call('operation-status', flags=('--operation-id', oid))
        committed = stage in ('journal_committed', 'operation_result')
        assert f.files['rules'].read_text() == (RULE.replace('false', 'true') if committed else RULE)
        assert status['candidate_digest'] == req['candidate_digest']
        if stage != 'collection_candidate_validated':
            assert status['save'] == ('saved' if committed else 'failed'), status
            assert status['before_generation'] == review['collection_transaction']['effective_generation']
        before = f.state()
        replay = f.call('apply', req, flags)
        assert replay == status
        assert f.state() == before
        f.call('apply', dict(req, candidate_digest='0' * 64), flags, code='operation_id_reused')

# Production must not honor the test-only stop/crash hooks.
if HELPER != DRIVER:
    with Fixture() as f:
        req = f.approved(f.request())
        p = f.run('apply', req, env=f.env | {'AQUEOUS_TEST_STOP_AT': 'collection_candidate_validated',
                                          'AQUEOUS_TEST_CRASH_AT': 'collection_candidate_validated'})
        assert p.returncode == 0 and json.loads(p.stdout)['ok'], (p.stdout, p.stderr)

print('PASS: protected collection rebasing, source identity/existence, full digest, races and receipt recovery')
if SCHEMA:
    print('PASS: protected collection request/response JSON schemas')
