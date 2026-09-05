#!/usr/bin/env python3
"""Shared display-mode protocol: discovery, staging, inheritance and preservation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

helper = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='aqueous-mode-test-') as directory:
    root = Path(directory)
    config = root/'config/aqueous'
    config.mkdir(parents=True)
    wm = '# legacy stays intact\n[[output]]\nname = "DP-1"\nmode = "2560x1440@144"\nscale = 1.5\n'
    (config/'wm.toml').write_text(wm)
    outputs = '# preserve this comment\n[[output]]\nname = "DP-1"\nposition = [0, 0]\nadaptive_sync = true\nunknown_policy = "keep"\n'
    (config/'outputs.toml').write_text(outputs)
    for name in ['layout','input','rules']:
        (config/(name+'.toml')).write_text('')
    binaries=root/'bin'
    binaries.mkdir()
    advertised=[dict(name='DP-1',scale=1.5,modes=[dict(width=2560,height=1440,refresh=59.94,current=False,preferred=False),dict(width=2560,height=1440,refresh=143.999,current=True,preferred=True),dict(width=1920,height=1080,refresh=60.0,current=False,preferred=False)])]
    executable=binaries/'aqueousctl'
    executable.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then\ncat <<\'JSON\'\n'+json.dumps(advertised)+'\nJSON\nelse exit 1; fi\n')
    executable.chmod(0o755)
    env=dict(os.environ,HOME=str(root/'home'),XDG_CONFIG_HOME=str(root/'config'),XDG_STATE_HOME=str(root/'state'),XDG_CACHE_HOME=str(root/'cache'),GSETTINGS_BACKEND='memory',PATH=str(binaries)+':'+os.environ['PATH'])
    for name in ['wm','layout','input','outputs','rules']:
        env['AQUEOUS_'+('CONFIG' if name=='wm' else name.upper())]=str(config/(name+'.toml'))
    def run(mode,request=None,success=True):
        args=[helper,mode,'--shell','dms']
        if request is not None: args+=['--request','-']
        result=subprocess.run(args,input=json.dumps(request) if request is not None else None,env=env,text=True,capture_output=True,timeout=10)
        response=json.loads(result.stdout)
        assert response['ok']==success,(result.stdout,result.stderr)
        return response
    snapshot=run('snapshot')
    assert snapshot['live_outputs']==advertised
    monitor=snapshot['monitors'][0]
    assert monitor['mode']=='2560x1440@144' and monitor['mode_inherited']
    def request(mode):
        return dict(protocol=1,expected_generation=snapshot['generation'],monitor_changes=[dict(id=monitor['id'],name='DP-1',x=-100,y=20,transform='90',mode=mode)])
    for invalid in ['',None,'1920x0','100001x1080','1920x1080@NaN','1920x1080@-60','1920x1080@1001','1920x1080@60"\nname="evil']:
        response=run('apply',request(invalid),success=False)
        assert response['code']=='invalid_value',response
        assert (config/'outputs.toml').read_text()==outputs
    draft=request('2560x1440@59.94')
    run('validate',draft)
    assert (config/'outputs.toml').read_text()==outputs
    snapshot=run('apply',draft)
    assert (config/'wm.toml').read_text()==wm
    text=(config/'outputs.toml').read_text()
    assert '# preserve this comment' in text and 'unknown_policy = "keep"' in text and 'adaptive_sync = true' in text
    monitor=snapshot['monitors'][0]
    assert monitor['mode']=='2560x1440@59.94' and not monitor['mode_inherited']
    assert (monitor['x'],monitor['y'],monitor['transform'])==(-100,20,'90')
    assert run('apply',draft,success=False)['code']=='external_change'
    # Moving without a mode member must preserve the existing mode.
    move=request('unused')
    del move['monitor_changes'][0]['mode']
    move['monitor_changes'][0]['x']=50
    snapshot=run('apply',move)
    assert snapshot['monitors'][0]['mode']=='2560x1440@59.94'
    # Automatic refresh is represented by omitting @Hz, not by a made-up token.
    snapshot=run('apply',request('1920x1080'))
    assert snapshot['monitors'][0]['mode']=='1920x1080'
    # Offline/new outputs accept custom modes without inventing advertised modes.
    new=dict(protocol=1,expected_generation=snapshot['generation'],monitor_changes=[dict(id='live:DP-9',name='DP-9',x=0,y=0,transform='normal',mode='3840x2160@143.999')])
    snapshot=run('apply',new)
    assert any(m['name']=='DP-9' and m['mode']=='3840x2160@143.999' for m in snapshot['monitors'])
    executable.write_text('#!/bin/sh\nexit 1\n')
    assert run('snapshot')['live_outputs']==[]
print('Display mode protocol checks passed.')
