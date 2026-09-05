#!/usr/bin/env python3
"""Exercise DMS shell selection and stdin transport against real helper writes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = str(Path(sys.argv[1]).resolve())
fixtures = Path(__file__).resolve().parents[2] / 'plugin/tests/fixtures'
with tempfile.TemporaryDirectory(prefix='aqueous-dms-helper-') as temporary:
    root = Path(temporary)
    config = root / 'config/aqueous'
    config.mkdir(parents=True)
    for fixture in fixtures.glob('*.toml'):
        (config / fixture.name).write_bytes(fixture.read_bytes())
    binaries = root / 'bin'
    binaries.mkdir()
    noctalia = binaries / 'noctalia'
    noctalia.write_text('#!/bin/sh\ntouch "' + str(root / 'noctalia-called') + '"\n')
    noctalia.chmod(0o755)
    env = dict(os.environ, HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_STATE_HOME=str(root / 'state'), NOCTALIA_STATE_HOME=str(root / 'state'),
               XDG_CACHE_HOME=str(root / 'cache'), GSETTINGS_BACKEND='memory',
               PATH=str(binaries) + ':' + os.environ['PATH'])
    for name in ['wm','layout','input','outputs','rules']:
        env['AQUEOUS_' + ('CONFIG' if name == 'wm' else name.upper())] = str(config / (name + '.toml'))
    def call(mode, request=None, shell='dms', success=True):
        args = [helper,mode,'--shell',shell]
        if request is not None: args += ['--request','-']
        p = subprocess.run(args,input=json.dumps(request) if request is not None else None,
                           text=True,capture_output=True,env=env,timeout=15)
        result = json.loads(p.stdout)
        assert result['ok'] == success, result
        assert (p.returncode == 0) == success, result
        return result
    snap = call('snapshot')
    assert snap['helper_version'] == '0.7.0'
    assert next(t for t in snap['desktop_typography']['targets'] if t['id']=='noctalia')['active'] is False
    before = (config/'layout.toml').read_bytes()
    req = dict(protocol=1,expected_generation=snap['generation'],backup_dir=str(root/'backups'),
               changes=[dict(id='desktop.font.family',value='sans-serif'),dict(id='desktop.font.size_pt',value=14)],
               sync_typography=True)
    call('validate',req)
    assert not (config/'appearance.toml').exists()
    assert not (root/'state/noctalia').exists()
    applied = call('apply',req)
    assert applied['desktop_typography']['applied']
    assert (config/'appearance.toml').exists()
    assert not (root/'state/noctalia').exists()
    assert not (root/'noctalia-called').exists()
    assert (config/'layout.toml').read_bytes() == before
    # A retry with no canonical changes still runs toolkit adapters.
    retry = dict(protocol=1,expected_generation=applied['generation'],sync_typography=True)
    assert call('apply',retry)['desktop_typography']['applied']
    assert call('apply',req,success=False)['code'] == 'external_change'
    assert not call('snapshot',shell='unknown',success=False)['ok']
    # Live monitor IDs are accepted by the existing backend.
    live = dict(protocol=1,expected_generation=applied['generation'],monitor_changes=[dict(id='live:HDMI-A-2',name='HDMI-A-2',x=-1920,y=0,transform='90')])
    applied = call('apply',live)
    assert any(m['name']=='HDMI-A-2' and m['x']==-1920 for m in applied['monitors'])
    # Default Noctalia behavior remains available to its existing caller.
    req['expected_generation'] = applied['generation']
    call('apply',req,shell='noctalia')
    assert (root/'state/noctalia/settings.toml').exists()
    assert (root/'noctalia-called').exists()
print('DMS helper integration checks passed.')
