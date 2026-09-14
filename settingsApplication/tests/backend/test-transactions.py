#!/usr/bin/env python3
"""Crash/replay tests. All configuration, state, and command effects are isolated."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

helper, driver = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])

class Fixture:
    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aqueous-journal-')
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('AQUEOUS_', 'NOCTALIA_'))}
        for key, name in [('HOME','home'), ('XDG_CONFIG_HOME','config'), ('XDG_STATE_HOME','state'), ('XDG_RUNTIME_DIR','runtime')]:
            p = self.root / name; p.mkdir(mode=0o700); self.env[key] = str(p)
        self.env.update(DISPLAY='', WAYLAND_DISPLAY='isolated-absent', GSETTINGS_BACKEND='memory')
        self.cfg = self.root / 'config/aqueous'; self.cfg.mkdir()
        self.files = {}
        for name in ('wm','layout','input','outputs','rules','appearance'):
            path = self.cfg / (name + '.toml'); path.write_text('')
            self.files[name] = path
            self.env['AQUEOUS_CONFIG' if name == 'wm' else 'AQUEOUS_' + name.upper()] = str(path)
        bindir = self.root / 'bin'; bindir.mkdir()
        ctl = bindir / 'aqueousctl'
        ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; elif [ "$1" = session ]; then echo reload >> "' + str(self.root / 'reloads') + '"; echo \'{"ok":true,"status":"applied","sequence":"1"}\'; fi\n')
        ctl.chmod(0o755); self.env['PATH'] = str(bindir) + ':' + os.environ['PATH']
        return self
    def __exit__(self, *args): self.tmp.cleanup()
    def call(self, op, req=None, flags=(), crash=None, executable=None):
        env = dict(self.env)
        if crash: env['AQUEOUS_TEST_CRASH_AT'] = crash
        cmd = [executable or (driver if crash else helper), op, '--shell', 'none', *flags]
        if req is not None: cmd += ['--request', '-']
        p = subprocess.run(cmd, input=None if req is None else json.dumps(req), text=True, capture_output=True, env=env, timeout=35)
        if crash:
            assert p.returncode == 97, (crash, p.returncode, p.stdout, p.stderr)
            return
        assert p.stdout, (p.returncode,p.stderr)
        return json.loads(p.stdout)
    def request(self):
        s = self.call('snapshot'); assert s['ok'], s
        return dict(protocol=1, expected_generation=s['generation'], backup_dir=str(self.root/'backups'), raw_files={'wm':'# new wm\n', 'outputs':'# new outputs\n'})
    def opid(self): return f'{int(time.time())}-{uuid.uuid4().hex}'
    def status(self,id): return self.call('operation-status', flags=('--operation-id',id))

for stage in ['journal_prepared',*[f'written_file_{i}' for i in range(6)],'journal_committed','journal_cleaned']:
    with Fixture() as f:
        req=f.request(); req['raw_files']={name:f'# changed {name}\n' for name in f.files}; id=f.opid()
        f.call('apply',req,('--result','v1','--operation-id',id),crash=stage)
        status=f.status(id)
        committed=stage in ['journal_committed','journal_cleaned']
        assert status['save']==('saved' if committed else 'failed'), (stage,status)
        for name in f.files:
            assert f.files[name].read_text()==(req['raw_files'][name] if committed else ''), stage
        assert not (f.root/'state/aqueous/config-writer/active.json').exists()
        f.call('apply',req,('--result','v1','--operation-id',id))
        assert not (f.root/'reloads').exists(), 'replay executed an external effect'
        assert status['reload']=='unknown'

# Recovery can itself die, and recovery conflicts preserve newer external bytes.
with Fixture() as f:
    req=f.request(); f.call('apply',req,crash='written_file_1')
    f.call('snapshot',crash='recovered_file_0')
    assert f.call('snapshot')['ok']
    assert all(f.files[n].read_text()=='' for n in ['wm','outputs'])
with Fixture() as f:
    req=f.request(); f.call('apply',req,crash='written_file_0')
    f.files['wm'].write_text('# external edit\n')
    result=f.call('snapshot'); assert not result['ok'], result
    assert f.files['wm'].read_text()=='# external edit\n'
    assert f.files['outputs'].read_text()==''
    assert (f.root/'state/aqueous/config-writer/active.json').exists()
# Newly created canonical files are deleted on rollback rather than made empty.
with Fixture() as f:
    f.files['outputs'].unlink(); req=f.request()
    f.call('apply',req,crash='written_file_1')
    assert f.call('snapshot')['ok']
    assert not f.files['outputs'].exists()
# Lost stdout and exact retries recover the same terminal result, only one reload.
with Fixture() as f:
    req=f.request(); id=f.opid()
    f.call('apply',req,('--result','v1','--operation-id',id),crash='operation_result')
    first=f.status(id); second=f.call('apply',req,('--result','v1','--operation-id',id))
    assert first==second and first['save']=='saved' and first['reload']=='applied'
    assert (f.root/'reloads').read_text().splitlines()==['reload']
    changed=dict(req, raw_files={'wm':'# other\n'})
    assert not f.call('apply',changed,('--result','v1','--operation-id',id))['ok']
    assert f.status(f.opid())['receipt']=='unknown'
    expired='1000000000-'+uuid.uuid4().hex
    assert not f.call('apply',req,('--result','v1','--operation-id',expired))['ok']
# Death before save produces uncertainty, never an automatic retry.
with Fixture() as f:
    req=f.request(); id=f.opid()
    f.call('apply',req,('--result','v1','--operation-id',id),crash='operation_intent')
    assert f.status(id)['receipt']=='unknown'
    assert f.call('apply',req,('--result','v1','--operation-id',id))['receipt']=='unknown'
    assert f.files['wm'].read_text()==''
print('PASS: journal crash points, repeated recovery, conflicts, created files, durable receipts, idempotent replay')

# Collection rebase is permitted only across unchanged source identity/content.
with Fixture() as f:
    f.files['rules'].write_text('[[window]]\napp_id = "one"\nfloating = false\n')
    snap=f.call('snapshot'); rule=snap['window_rules'][0]['id']
    request=dict(protocol=1,expected_generation=snap['generation'],collection_preconditions=snap['collection_preconditions'],window_rule_changes=[dict(id=rule,values=dict(floating=True))])
    f.files['outputs'].write_text('# unrelated generation change\n')
    assert f.call('validate',request)['ok']
    f.files['rules'].write_text('[[window]]\napp_id = "shifted"\n'+f.files['rules'].read_text())
    assert not f.call('validate',request)['ok']
# Removing an unknown table must not be proved harmless by display-parser equality.
with Fixture() as f:
    f.files['outputs'].write_text('[future]\nunsafe = true\n')
    req=f.request();req['raw_files']={'outputs':''}
    result=f.call('validate',req)
    assert result['candidate_impact']['complete'] is False,result
print('PASS: collection rebase preconditions and unknown-table classification')
