#!/usr/bin/env python3
"""Embedded backend extensions against real files in an isolated XDG profile."""
import json, os, pathlib, subprocess, sys, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
HELPER=str(pathlib.Path(sys.argv[1] if len(sys.argv)>1 else ROOT/'settingsApplication/zig-out/bin/aqueous-backend-test').resolve())
with tempfile.TemporaryDirectory(prefix='aqueous-settings-integration-') as tmp:
    base=pathlib.Path(tmp); config=base/'config/aqueous';config.mkdir(parents=True)
    for fixture in (ROOT/'settingsApplication/tests/fixtures').glob('*.toml'): (config/fixture.name).write_bytes(fixture.read_bytes())
    env={k:v for k,v in os.environ.items() if not k.startswith('AQUEOUS_') and k not in ('WAYLAND_DISPLAY','DISPLAY','DBUS_SESSION_BUS_ADDRESS','LD_PRELOAD')}
    env.update(HOME=str(base/'home'),XDG_CONFIG_HOME=str(base/'config'),XDG_STATE_HOME=str(base/'state'),XDG_RUNTIME_DIR=str(base/'runtime'),NOCTALIA_STATE_HOME=str(base/'state'),GSETTINGS_BACKEND='memory')
    for key,name in [('CONFIG','wm'),('LAYOUT','layout'),('INPUT','input'),('OUTPUTS','outputs'),('RULES','rules')]:env['AQUEOUS_'+key]=str(config/(name+'.toml'))
    (base/'config/Noctalia').mkdir();(base/'config/Noctalia/settings.toml').write_text('# leave this alone\n')
    (base/'config/DankMaterialShell').mkdir();(base/'config/DankMaterialShell/settings.json').write_text('{"fontFamily":"Unchanged"}\n')
    def call(mode,req=None,shell='none',ok=True):
        p=subprocess.run([HELPER,mode,'--shell',shell]+(['--request','-'] if req is not None else []),input=json.dumps(req) if req is not None else None,env=env,capture_output=True,text=True,timeout=15)
        response=json.loads(p.stdout);assert (p.returncode==0)==ok,(mode,response.get("code"),response.get("message"),p.stderr);return response
    snap=call('snapshot'); assert {'shell_none','monitor_scale'}<=set(snap['capabilities'])
    before={p.name:p.read_bytes() for p in config.glob('*.toml')}
    request=dict(protocol=1,expected_generation=snap['generation'],backup_dir=str(base/'backups'),create_user_override=True,
        monitor_changes=[dict(id='live:TEST-1',name='TEST-1',x=-1280,y=12,transform='90',mode='1920x1080@59.94',scale=1.5)])
    call('validate',request);assert before=={p.name:p.read_bytes() for p in config.glob('*.toml')}
    applied=call('apply',request)
    monitor=next(m for m in applied['monitors'] if m['name']=='TEST-1')
    assert monitor['scale']==1.5 and monitor['mode']=='1920x1080@59.94' and monitor['transform']=='90'
    assert before['wm.toml']==(config/'wm.toml').read_bytes()
    assert call('apply',request,ok=False)['code']=='external_change'
    for scale in [0,-1,9,'invalid']:
        request['expected_generation']=applied['generation'];request['monitor_changes'][0]['scale']=scale
        assert call('validate',request,ok=False)['code']=='invalid_value'
    # Canonical typography saves and ordinary toolkits work with neither shell.
    applied=call('apply',dict(protocol=1,expected_generation=applied['generation'],sync_typography=True))
    noctalia=next(t for t in applied['desktop_typography']['targets'] if t['id']=='noctalia')
    assert not noctalia['active'] and not noctalia['available']
    assert (base/'config/Noctalia/settings.toml').read_text()=='# leave this alone\n'
    assert (base/'config/DankMaterialShell/settings.json').read_text()=='{"fontFamily":"Unchanged"}\n'
    assert not (base/'state/noctalia/settings.toml').exists()
    print('Embedded backend: validation, monitor scale, fractional modes, conflicts and neutral shell passed.')
