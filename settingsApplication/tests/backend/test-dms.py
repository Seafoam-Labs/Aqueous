#!/usr/bin/env python3
"""Exercise DMS shell selection and stdin transport against embedded backend writes through the test adapter."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = str(Path(sys.argv[1]).resolve())
fixtures = Path(__file__).resolve().parents[1] / 'fixtures'
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
    assert snap['helper_version'] == '0.7.2'
    assert {'generation_check', 'monitor_modes', 'cursor_sync', 'typography_sync', 'shell_dms'} <= set(snap['capabilities'])
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
    # Both rule editors round-trip the optional scrolling preset as a boolean.
    for shell in ['dms', 'noctalia']:
        change = dict(protocol=1, expected_generation=applied['generation'],
                      window_rule_changes=[dict(id='new-rule:width', op='add',
                          values=dict(app_id='aq-width-test', scrolling_full_width=True))])
        call('validate', change, shell=shell)
        applied = call('apply', change, shell=shell)
        rule = next(r for r in applied['window_rules'] if r['values'].get('app_id') == 'aq-width-test')
        assert rule['values']['scrolling_full_width'] is True
        assert 'layout' not in rule['values']
        for value in [False, None, True]:
            change = dict(protocol=1, expected_generation=applied['generation'],
                          window_rule_changes=[dict(id=rule['id'], op='update',
                              values=dict(scrolling_full_width=value))])
            applied = call('apply', change, shell=shell)
            rule = next(r for r in applied['window_rules'] if r['values'].get('app_id') == 'aq-width-test')
            if value is None:
                assert 'scrolling_full_width' not in rule['values']
            else:
                assert rule['values']['scrolling_full_width'] is value
                assert 'scrolling_full_width = ' + str(value).lower() in (config/'rules.toml').read_text()
        before_rules = (config/'rules.toml').read_bytes()
        invalid = dict(protocol=1, expected_generation=applied['generation'],
                       window_rule_changes=[dict(id=rule['id'], op='update',
                           values=dict(scrolling_full_width='invalid'))])
        call('validate', invalid, shell=shell, success=False)
        assert (config/'rules.toml').read_bytes() == before_rules
        applied = call('apply', dict(protocol=1, expected_generation=applied['generation'],
            window_rule_changes=[dict(id=rule['id'], op='delete')]), shell=shell)
    # Scrolling insertion is a shared schema boolean and persists to layout.toml.
    field_id = 'layout.options.scrolling.open_new_windows_to_right'
    field = next(f for f in call('snapshot')['fields'] if f['id'] == field_id)
    assert field['type'] == 'boolean' and field['default'] is False
    for value in [True, False]:
        change = dict(protocol=1,expected_generation=applied['generation'],
                      changes=[dict(id=field_id,value=value)])
        call('validate',change)
        applied = call('apply',change)
        field = next(f for f in call('snapshot')['fields'] if f['id'] == field_id)
        assert field['configured'] and field['value'] is value
        assert 'open_new_windows_to_right = ' + str(value).lower() in (config/'layout.toml').read_text()
    # Both shells consume the shared input schema and persist explicit false.
    field_id = 'input.mouse_follows_focus'
    for shell in ['dms', 'noctalia']:
        field = next(f for f in call('snapshot', shell=shell)['fields'] if f['id'] == field_id)
        assert field['type'] == 'boolean' and field['default'] is False
        for value in [True, False]:
            change = dict(protocol=1, expected_generation=applied['generation'],
                          changes=[dict(id=field_id, value=value)])
            call('validate', change, shell=shell)
            applied = call('apply', change, shell=shell)
            field = next(f for f in call('snapshot', shell=shell)['fields'] if f['id'] == field_id)
            assert field['configured'] and field['value'] is value
            assert 'mouse_follows_focus = ' + str(value).lower() in (config/'input.toml').read_text()
    # Default Noctalia behavior remains available to its existing caller.
    req['expected_generation'] = applied['generation']
    call('apply',req,shell='noctalia')
    assert (root/'state/noctalia/settings.toml').exists()
    assert (root/'noctalia-called').exists()
print('DMS backend integration checks passed.')
