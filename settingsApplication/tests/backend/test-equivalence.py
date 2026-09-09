#!/usr/bin/env python3
"""Optional migration oracle: compare a preserved old helper with the backend driver."""
import json, os, pathlib, shutil, subprocess, sys, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
legacy=str(pathlib.Path(sys.argv[1]).resolve())
driver=str(pathlib.Path(sys.argv[2] if len(sys.argv)>2 else ROOT/'zig-out/bin/aqueous-backend-test').resolve())
with tempfile.TemporaryDirectory(prefix='aqueous-backend-equivalence-') as tmp:
    root=pathlib.Path(tmp); config=root/'config/aqueous'; config.mkdir(parents=True)
    env={k:v for k,v in os.environ.items() if not k.startswith('AQUEOUS_') and k not in ('LD_PRELOAD','WAYLAND_DISPLAY','DISPLAY','DBUS_SESSION_BUS_ADDRESS')}
    env.update(HOME=str(root/'home'),XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_RUNTIME_DIR=str(root/'runtime'),GSETTINGS_BACKEND='memory')
    def call(binary,op,request=None):
        p=subprocess.run([binary,op,'--shell','none']+(['--request','-'] if request is not None else []),input=json.dumps(request) if request is not None else None,env=env,capture_output=True,text=True,timeout=40)
        return p.returncode,json.loads(p.stdout)
    def sequence(binary):
        for p in config.glob('*'):p.unlink()
        for p in (ROOT/'tests/fixtures').glob('*.toml'):shutil.copy(p,config/p.name)
        snap=call(binary,'snapshot');generation=snap[1]['generation']
        request=dict(protocol=1,expected_generation=generation,backup_dir=str(root/'backups'),create_user_override=True,changes=[dict(id='layout.gaps_inner',value=17)],monitor_changes=[dict(id='live:TEST',name='TEST',x=-100,y=12,transform='90',scale=1.5,mode='1920x1080@59.94')])
        validated=call(binary,'validate',request)
        applied=call(binary,'apply',request)
        stale=call(binary,'apply',request)
        invalid=call(binary,'validate',dict(protocol=1,expected_generation=applied[1]['generation'],changes=[dict(id='layout.gaps_inner',value=-1)]))
        return [snap,validated,applied,stale,invalid],{p.name:p.read_bytes() for p in config.glob('*.toml')}
    assert sequence(legacy)==sequence(driver), 'backend diverged from the migration oracle'
    print('Legacy and embedded backend agree: snapshots, Validate, Apply, errors and saved TOML.')
