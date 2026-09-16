#!/usr/bin/env python3
"""Structured declaration batches against isolated configuration and race fixtures."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import tomllib

HELPER, DRIVER = map(lambda p: str(Path(p).resolve()), sys.argv[1:3])
SCHEMA = None
if '--schema' in sys.argv:
    import jsonschema
    SCHEMA = json.loads((Path(__file__).resolve().parents[2] / 'docs/aqueous-config-additions-v1.schema.json').read_text())
    jsonschema.Draft202012Validator.check_schema(SCHEMA)

OUTPUTS = '''# retained preamble
[display]
fallback_profile = "desk"
[[output]] # first duplicate
name = "OFFLINE-DP-1"
enabled = false
scale = 1.25
primary = false
[[output]] # second duplicate
name = "OFFLINE-DP-1"
hdr = false
[[display.profile]] # desk comment
name = "desk"
[[display.profile.output]] # member comment
name = "DP-*"
position = [0, 0]
[[display.profile]]
name = "travel"
[[display.profile.output]]
edid = "offline-edid"
enabled = false
'''

class Fixture:
    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='aqueous-display-mutations-')
        self.root = Path(self.tmp.name)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('AQUEOUS_','NOCTALIA_')) and k not in ('DBUS_SESSION_BUS_ADDRESS','DISPLAY','WAYLAND_DISPLAY','LD_PRELOAD')}
        for k,n in [('HOME','home'),('XDG_CONFIG_HOME','config'),('XDG_STATE_HOME','state'),('XDG_RUNTIME_DIR','run')]:
            p=self.root/n;p.mkdir(mode=0o700);self.env[k]=str(p)
        self.env.update(WAYLAND_DISPLAY='absent',GSETTINGS_BACKEND='memory')
        folder=self.root/'config/aqueous';folder.mkdir()
        self.files={n:folder/(n+'.toml') for n in ['wm','layout','input','outputs','rules','appearance']}
        for n,p in self.files.items():
            p.write_text(OUTPUTS if n=='outputs' else '[[output]]\nname = "OFFLINE-DP-1"\nscale = 2.0\nhdr = true\n' if n=='wm' else '')
            self.env['AQUEOUS_CONFIG' if n=='wm' else 'AQUEOUS_'+n.upper()]=str(p)
        bindir=self.root/'bin';bindir.mkdir();ctl=bindir/'aqueousctl'
        ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; elif [ "$1" = cursor ]; then echo "{}"; elif [ "$1" = session ]; then touch "$XDG_STATE_HOME/reloaded"; fi\n');ctl.chmod(0o755)
        self.env['PATH']=str(bindir)+':'+os.environ['PATH']
        return self
    def __exit__(self,*args):self.tmp.cleanup()
    def call(self,op,req=None,code=None,executable=HELPER):
        before={n:p.read_bytes() if p.exists() else None for n,p in self.files.items()}
        reloaded=(self.root/'state/reloaded').exists()
        p=subprocess.run([executable,op,'--shell','none']+(['--request','-'] if req is not None else []),input=json.dumps(req) if req is not None else None,text=True,capture_output=True,env=self.env,timeout=35)
        assert p.stdout,(p.returncode,p.stderr)
        r=json.loads(p.stdout)
        if code:assert r.get('code')==code and not r['ok'],(code,r,p.stderr)
        else:assert r['ok'],(r,p.stderr)
        if code or op=='validate':
            assert before=={n:p.read_bytes() if p.exists() else None for n,p in self.files.items()}
            assert (self.root/'state/reloaded').exists()==reloaded
            assert not (self.root/'backups').exists()
        if SCHEMA and r['ok'] and op!='version':jsonschema.Draft202012Validator(SCHEMA).validate(r)
        return r
    def request(self,ops,snap=None,**extra):
        snap=snap or self.call('snapshot')
        return dict(protocol=1,expected_generation=snap['generation'],protected_apply=True,display_declaration_changes=dict(version=1,sources={op['source']:snap['display_source_ids'][op['source']] for op in ops},operations=ops),**extra)
    def validate(self,ops,snap=None,**extra):
        req=self.request(ops,snap,**extra)
        if SCHEMA:
            jsonschema.Draft202012Validator(dict(SCHEMA,oneOf=[{'$ref':'#/$defs/display_mutation_request'}])).validate(req)
        r=self.call('validate',req)
        assert r['candidate_review']['candidate_digest']==r['candidate_impact']['candidate_digest']
        return r

def declarations(s,source='outputs',kind=None):
    return [d for d in s['display_declarations'] if d['source']==source and (kind is None or d['kind']==kind)]
def edit(node,op='update',**kwargs):return dict(op=op,source=node['source'],id=node['id'])|kwargs
def parsed(r,source='outputs'):return tomllib.loads(r['raw_files'][source])

with Fixture() as f:
    v=f.call('version');assert v['version']=='0.8.3' and 'display_declaration_mutations_v1' in v['capabilities']
    s=f.call('snapshot');ds=declarations(s);policy,first,second,desk,member,travel,other=ds
    assert len({d['id'] for d in s['display_declarations']})==len(s['display_declarations'])
    assert member['parent_id']==desk['id'] and other['parent_id']==travel['id']
    assert first['parent_id'] is None
    r=f.validate([edit(first,set=dict(enabled=True,primary=True,edid='edid-123',mode='1920x1080@59.94',position=[-2147483648,0],scale=1.5,transform='flipped-90',adaptive_sync=False,hdr=False,hdr_level='400',sdr_white_level=180,auto_hdr=False,auto_hdr_boost=0,mirror_of=''))],s)
    o=parsed(r)['output'];assert o[0]['enabled'] and o[0]['primary'] and o[0]['auto_hdr_boost']==0 and o[0]['mirror_of']=='' and o[1]==dict(name='OFFLINE-DP-1',hdr=False)
    assert '# first duplicate' in r['raw_files']['outputs'] and '# second duplicate' in r['raw_files']['outputs']
    assert not r['candidate_impact']['complete'], 'headless helper alone cannot authorize physical changes'
    r=f.validate([edit(first,unset=['scale','enabled','primary']),edit(second,unset=['hdr'])],s)
    assert parsed(r)['output']==[dict(name='OFFLINE-DP-1'),dict(name='OFFLINE-DP-1')]
    native=r['display_configuration'];assert native['parsed_sources']['outputs']['outputs'][0]['scale'] is None
    assert native['parsed_sources']['wm']['outputs'][0]['scale']==2
    assert declarations(r)[0]['id']!=policy['id'], 'candidate IDs must be generation-scoped'
    # Original IDs resolve once, despite an earlier deletion shifting tables.
    r=f.validate([edit(first,op='delete'),edit(second,set=dict(primary=True))],s)
    assert parsed(r)['output']==[dict(name='OFFLINE-DP-1',hdr=False,primary=True)]
    # New profile and members, with references restricted to preceding additions.
    r=f.validate([dict(op='add',source='outputs',kind='profile',ref='new-desk',set=dict(name='gaming'),before=desk['id']),dict(op='add',source='outputs',kind='output',parent='new:new-desk',ref='screen',set=dict(edid='NEW-EDID',enabled=False)),edit(member,op='move',parent='new:new-desk'),edit(policy,set=dict(fallback_profile='gaming',apply_on_start=False,apply_on_reload=False,identify_by='name',rollback_seconds=0))],s)
    ps=parsed(r)['display']['profile'];assert [p['name'] for p in ps]==['gaming','desk','travel'] and [o.get('edid',o.get('name')) for o in ps[0]['output']]==['NEW-EDID','DP-*']
    assert 'output' not in ps[1]
    assert parsed(r)['display']['rollback_seconds']==0
    # Profile order moves include all member blocks and comments.
    r=f.validate([edit(travel,op='move',before=desk['id']),edit(member,set=dict(enabled=False))],s)
    ps=parsed(r)['display']['profile'];assert [p['name'] for p in ps]==['travel','desk'] and ps[1]['output'][0]['enabled'] is False
    assert '# desk comment' in r['raw_files']['outputs'] and '# member comment' in r['raw_files']['outputs']
    # Explicit profile rename + policy update, and deletion choices.
    r=f.validate([edit(desk,set=dict(name='renamed')),edit(policy,set=dict(fallback_profile='renamed'))],s)
    assert parsed(r)['display']['profile'][0]['name']=='renamed'
    for choice,parent in [('delete',None),('move',travel['id']),('move',None)]:
        op=edit(desk,op='delete',members=choice)
        if choice=='move':op['parent']=parent
        r=f.validate([op,edit(policy,set=dict(fallback_profile='travel'))],s)
        p=parsed(r);assert len(p['display']['profile'])==1
        if choice=='move' and parent:assert len(p['display']['profile'][0]['output'])==2
        if choice=='move' and not parent:assert p['output'][-1]['name']=='DP-*'
    r=f.validate([edit(second,op='move',parent=None,before=first['id'])],s)
    assert parsed(r)['output'][0].get('hdr') is False
    # Source selection edits wm directly without implicitly migrating to outputs.
    wm=declarations(s,'wm')[0]
    r=f.validate([edit(wm,set=dict(primary=True))],s)
    assert parsed(r,'wm')['output'][0]['primary'] and r['raw_files']['outputs']==OUTPUTS
    # Mixed sources and unrelated raw/structured collections remain reviewable.
    r=f.validate([edit(first,set=dict(primary=True)),edit(wm,set=dict(scale=1.25))],s,backup_dir=str(f.root/'backups'),window_rule_changes=[dict(op='add',values=dict(app_id='test-*',floating=False))])
    assert parsed(r,'rules')['window'][0]['floating'] is False
    r=f.validate([edit(first,set=dict(primary=True))],s,raw_files={'wm':'[[output]]\nedid="other"\nprimary=true\n'})
    assert parsed(r,'wm')['output'][0]['primary']
    # Unknown legacy monitor fields are never silently ignored.
    for key,value in [('enabled',False),('primary',True),('edid','x'),('future',0)]:
        f.call('validate',dict(protocol=1,expected_generation=s['generation'],monitor_changes=[dict(id='live:X',name='X',x=0,y=0,transform='normal',**{key:value})]),code='invalid_value')
    bad_ops=[([edit(first,set={'future':True})],'invalid_display_field'),([edit(first,set={'enabled':None})],'invalid_display_value'),([edit(first,set={'primary':0})],'invalid_display_value'),([edit(first,set={'scale':.4})],'invalid_display_value'),([edit(first,set={'hdr_level':'l400'})],'invalid_display_value'),([edit(first,set={'position':[0,.5]})],'invalid_display_value'),([edit(first,set={'mode':'bad'})],'invalid_display_value'),([edit(first,set={'name':'x'*257})],'invalid_display_value'),([edit(first,set={'mirror_of':'*'})],'invalid_display_value'),([edit(first,set={'enabled':False},unset=['enabled'])],'conflicting_edits'),([edit(first,unset=['scale','scale'])],'conflicting_edits'),([edit(first,op='delete'),edit(first,set={'enabled':True})],'conflicting_edits'),([edit(first,set={'enabled':False}),edit(first,set={'primary':True})],'conflicting_edits'),([edit(desk,op='delete')],'invalid_display_mutation'),([edit(desk,op='delete',members='delete')],'invalid_display_reference'),([edit(member,set={'enabled':False}),edit(desk,op='delete',members='delete'),edit(policy,unset=['fallback_profile'])],'conflicting_edits'),([edit(desk,op='delete',members='delete'),edit(member,set={'enabled':False})],'conflicting_edits'),([edit(desk,op='move',before=first['id'])],'invalid_display_mutation'),([edit(first,op='move',parent=first['id'])],'invalid_display_id'),([edit(first,op='move',parent=desk['id'],before=other['id'])],'invalid_display_mutation'),([edit(first,id=wm['id'],set={'enabled':True})],'invalid_display_id'),([edit(first,id='display-v1:'+'0'*64,set={'enabled':True})],'invalid_display_id'),([edit(first,id='output:1',set={'enabled':True})],'invalid_display_id'),([edit(first,op='move',parent='new:later'),dict(op='add',source='outputs',kind='profile',ref='later',set={'name':'later'})],'invalid_display_id'),([edit(first,unset=['name'])],'invalid_display_source'),([dict(op='add',source='outputs',kind='policy',set={})],'invalid_display_source')]
    for ops,code in bad_ops:f.call('validate',f.request(ops,s),code=code)
    req=f.request([edit(first,set={'enabled':False})],s)
    for extra,code in [({'raw_files':{'outputs':OUTPUTS}},'conflicting_edits'),({'monitor_changes':[]},'conflicting_edits'),({'collection_preconditions':{}},'conflicting_edits'),({'protected_apply':False},'invalid_display_mutation'),({'store':True},'invalid_display_mutation')]:f.call('validate',req|extra,code=code)
    f.call('validate',f.request([edit(wm,set={'primary':True})],s,custom_keybind_changes=[]),code='conflicting_edits')
    f.call('validate',f.request([edit(wm,set={'primary':True})],s,changes=[dict(id='struts.top',value=1)]),code='conflicting_edits')
    # No-op still needs digest binding; formatting-only change is complete.
    noop=f.request([edit(first,unset=['edid'])],s)
    review=f.call('validate',noop);assert review['candidate_impact']['complete']
    for digest in [None,'bad','0'*64]:
        f.call('apply',noop|({} if digest is None else {'candidate_digest':digest}),code='candidate_mismatch')
    f.call('apply',noop|{'candidate_digest':review['candidate_review']['candidate_digest']})
    # External reorder, other-source generation changes, and source retargeting.
    f.files['outputs'].write_text(OUTPUTS.replace('# first duplicate','# externally reordered baseline'))
    fresh=f.call('snapshot');f.call('validate',req,code='external_change')
    f.call('validate',req|{'expected_generation':fresh['generation']},code='external_change')
    f.files['outputs'].write_text(OUTPUTS)
    f.files['input'].write_text('# unrelated change\n');f.call('validate',req,code='external_change');f.files['input'].write_text('')
    target=f.root/'identical.toml';target.write_text(OUTPUTS);f.env['AQUEOUS_OUTPUTS']=str(target)
    fresh=f.call('snapshot');f.call('validate',req|{'expected_generation':fresh['generation']},code='external_change')

# Duplicate profiles retain occurrence identity; empty identity can inherit an EDID.
with Fixture() as f:
    f.files['outputs'].write_text(OUTPUTS.replace('name = "travel"','name = "desk"'))
    s=f.call('snapshot');profiles=declarations(s,kind='profile')
    r=f.validate([edit(profiles[1],set={'name':'second-only'})],s)
    assert [p['name'] for p in parsed(r)['display']['profile']]==['desk','second-only']
    member=declarations(s,kind='member')[1]
    r=f.validate([edit(member,set={'name':''})],s)
    assert parsed(r)['display']['profile'][1]['output'][0]['edid']=='offline-edid'

# Actual external reorder remains stale even when a caller substitutes fresh
# generation/source tokens but retains an old declaration ID.
with Fixture() as f:
    s=f.call('snapshot');first=declarations(s,kind='output')[0]
    old=f.request([edit(first,set={'enabled':True})],s)
    first_text='[[output]] # first duplicate\nname = "OFFLINE-DP-1"\nenabled = false\nscale = 1.25\nprimary = false\n'
    second_text='[[output]] # second duplicate\nname = "OFFLINE-DP-1"\nhdr = false\n'
    f.files['outputs'].write_text(OUTPUTS.replace(first_text+second_text,second_text+first_text))
    fresh=f.call('snapshot');f.call('validate',old,code='external_change')
    f.call('validate',f.request([edit(first,set={'enabled':True})],fresh),code='invalid_display_id')

# Creation also binds existence, because protocol-1 generation treats absent
# and empty files identically. Validate both directions and descriptor shape.
for absent in [True,False]:
    with Fixture() as f:
        f.files['outputs'].write_text('')
        if absent:f.files['outputs'].unlink()
        s=f.call('snapshot')
        req=f.request([dict(op='add',source='outputs',kind='output',parent=None,set={'edid':'OFFLINE','enabled':False})],s)
        f.call('validate',req)
        for sources in [{},{'outputs':s['display_source_ids']['outputs'],'wm':s['display_source_ids']['wm']}]:
            bad=copy.deepcopy(req);bad['display_declaration_changes']['sources']=sources
            f.call('validate',bad,code='invalid_display_mutation')
        if absent:f.files['outputs'].write_text('')
        else:f.files['outputs'].unlink()
        assert f.call('snapshot')['generation']==s['generation']
        f.call('validate',req,code='external_change')

# Malformed originals cannot be repaired through structured surgery.
for content in [OUTPUTS+'future = true\n',OUTPUTS.replace('enabled = false','enabled = "false"',1),OUTPUTS.replace('[[output]]','[[ output ]]',1),OUTPUTS.replace('scale = 1.25','scale = 1.25\nscale = 2',1),OUTPUTS+'[[display.future]]\nname="x"\n',OUTPUTS+'\ntext = """\n[[output]]\n"""\n']:
    with Fixture() as f:
        f.files['outputs'].write_text(content);s=f.call('snapshot')
        f.call('validate',f.request([edit(declarations(s,kind='output')[0],set={'scale':1.5})],s),code='invalid_display_source')

# Deterministic late source races on both validation and no-op protected apply.
for op,changed in [('validate','outputs'),('validate','wm'),('apply','input')]:
    with Fixture() as f:
        s=f.call('snapshot');req=f.request([edit(declarations(s,kind='output')[0],unset=['edid'])],s)
        reviewed=f.call('validate',req);req['candidate_digest']=reviewed['candidate_review']['candidate_digest']
        p=subprocess.Popen([DRIVER,op,'--shell','none','--request','-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=f.env|{'AQUEOUS_TEST_STOP_AT':'display_candidate_validated'})
        try:
            p.stdin.write(json.dumps(req));p.stdin.close();p.stdin=None
            end=time.monotonic()+10
            while time.monotonic()<end:
                pid,status=os.waitpid(p.pid,os.WNOHANG|os.WUNTRACED)
                if pid:assert os.WIFSTOPPED(status),status;break
                time.sleep(.01)
            else:raise AssertionError('no candidate checkpoint')
            f.files[changed].write_text(f.files[changed].read_text()+'# raced\n')
            os.kill(p.pid,signal.SIGCONT);out,err=p.communicate(timeout=20)
            assert json.loads(out)['code']=='external_change',(out,err)
            assert not (f.root/'state/reloaded').exists()
        finally:
            if p.poll() is None:p.kill();p.wait()
print('PASS: structured declarations, profiles, IDs, explicit unset, conflicts and source races')
if SCHEMA:print('PASS: display declaration request/response schemas')
