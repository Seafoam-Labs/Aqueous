#!/usr/bin/env python3
"""Native preview against a private headless compositor and private bus."""
import socket
import signal
import json
import uuid
import os
from pathlib import Path
import subprocess
import tempfile
import time
import jsonschema
from ipc_test_client import Client

ROOT=Path(__file__).resolve().parents[1]
BIN=Path(os.environ.get('AQUEOUS_COMPOSITOR_BIN', ROOT/'zig-out/bin/aqueous'))
SCHEMA=json.loads((ROOT/'protocol/aqueous-display-v1.schema.json').read_text())
VALIDATOR=jsonschema.Draft202012Validator(SCHEMA)
HELPER_SCHEMA=json.loads((ROOT.parent/'settingsApplication/docs/aqueous-config-additions-v1.schema.json').read_text())
HELPER_VALIDATOR=jsonschema.Draft202012Validator(HELPER_SCHEMA)

def wait(fn, seconds=8):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        value=fn()
        if value: return value
        time.sleep(.03)
    raise AssertionError('condition timed out')

with tempfile.TemporaryDirectory(prefix='aq-preview-') as tmp:
    base=Path(tmp)
    env={k:v for k,v in os.environ.items() if not k.startswith('AQUEOUS_') and k not in ['DBUS_SESSION_BUS_ADDRESS','DISPLAY','WAYLAND_DISPLAY','LD_PRELOAD']}
    for key,name in [('HOME','home'),('XDG_CONFIG_HOME','config'),('XDG_STATE_HOME','state'),('XDG_RUNTIME_DIR','run')]:
        path=base/name; path.mkdir(mode=0o700); env[key]=str(path)
    cfg=base/'config/aqueous'; cfg.mkdir()
    (cfg/'wm.toml').write_text('[workspace_transition]\nenabled = false\n')
    (cfg/'rules.toml').write_text('')
    bindir=base/'bin';bindir.mkdir();notify=bindir/'notify-send';notify.write_text('#!/bin/sh\nexit 0\n');notify.chmod(0o755)
    env['PATH']=str(bindir)+':'+os.environ['PATH']
    env.update(WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='2', WLR_RENDERER='pixman', LD_LIBRARY_PATH=os.environ.get('AQUEOUS_WLROOTS_LIB', str(ROOT/'.deps/wlroots-render-hook/lib')))
    log=(base/'compositor.log').open('w+')
    proc=subprocess.Popen(['dbus-run-session','--',str(BIN),'-no-xwayland','-c','printenv AQUEOUS_SOCKET WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/socket"'],env=env,stdout=log,stderr=log,start_new_session=True)
    clients=[]
    try:
        def socket_path():
            if proc.poll() is not None:
                log.seek(0); raise AssertionError(log.read())
            p=base/'run/socket'
            return p.read_text().splitlines()[0] if p.exists() and len(p.read_text().splitlines())==2 else None
        path=wait(socket_path)
        env.update(AQUEOUS_SOCKET=path, WAYLAND_DISPLAY=(base/'run/socket').read_text().splitlines()[1], PATH=str(bindir)+':'+str(BIN.parent)+':'+os.environ['PATH'])
        helper=Path(os.environ.get('AQUEOUS_CONFIG_HELPER', ROOT.parent/'settingsApplication/zig-out/bin/aqueous-config'))
        def helper_call(op, request=None, flags=(), read_deadline=None):
            if read_deadline is None: read_deadline=time.monotonic()+8
            args=[str(helper),op,'--shell','none',*flags]
            if request is not None: args += ['--request','-']
            p=subprocess.run(args,input=None if request is None else json.dumps(request),text=True,capture_output=True,env=env,timeout=35)
            result=json.loads(p.stdout)
            if not result.get('ok') and result.get('code')=='config_writer_busy':
                # A cooperating reader may be publishing another complete
                # generation. Retry this read-only query, never replay apply.
                assert op in ('snapshot','validate','operation-status'),result
                assert time.monotonic()<read_deadline,'reader lock remained busy'
                time.sleep(.1)
                return helper_call(op,request,flags,read_deadline)
            assert result['ok'],(result,p.stderr)
            HELPER_VALIDATOR.validate(result)
            return result
        query=Client(path); clients.append(query)
        source_revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        helper_version=json.loads(subprocess.check_output([str(helper),'version','--json'],env=env,text=True))
        print(json.dumps(dict(source_revision=source_revision,source_tree='working tree',helper=helper_version,native_capabilities=query.capabilities['capabilities'],backend='headless/pixman',hardware_tested=False)),flush=True)
        def model():
            value=query.call('display.snapshot')['result'];VALIDATOR.validate(value);return value
        baseline=wait(lambda: (m if (m:=model())['observation']=='current' and len(m['outputs'])==2 else None))
        assert query.capabilities['capabilities']['display_preview_feature_policy_v1']
        features=query.call('display.preview.features')['result'];VALIDATOR.validate(features)
        assert features['production_hardware_enabled'] == (not query.capabilities['capabilities']['display_preview_acceptance_build'])
        assert features['production_hardware_enabled'] == query.capabilities['capabilities']['display_preview_hardware']
        assert all(o['features']['hdr']['transition']['reason']=='hdr_unsupported' and
                   o['features']['vrr']['preserve']['reason']=='vrr_unsupported' and
                   o['features']['sdr']['transition']['status']=='available' for o in features['outputs'])
        assert helper_call('preview-features')['preview_features']==features
        # Collection-only protected apply has no display lease, but its native
        # reload acknowledgement must still bind the freshly reviewed candidate.
        snap=helper_call('snapshot')
        collection_request=dict(protocol=1,collection_apply_version=1,protected_apply=True,
            expected_generation=snap['generation'],
            collection_preconditions_v2=dict(version=2,sources={'rules':snap['collection_preconditions_v2']['sources']['rules']}),
            window_rule_changes=[dict(op='add',values=dict(app_id='protected-collection-test-*',floating=False))])
        reviewed=helper_call('validate',collection_request)
        assert reviewed['candidate_impact']['complete'] and reviewed['candidate_impact']['display'] is None
        report=reviewed['collection_transaction']
        collection_request.update(expected_generation=report['effective_generation'],candidate_digest=report['candidate_digest'])
        collection_id=str(int(time.time()))+'-'+uuid.uuid4().hex
        result=helper_call('apply',collection_request,('--result','v1','--operation-id',collection_id))
        assert result['save']=='saved' and result['reload']=='applied' and result['display']=='not_requested',result
        ack=result['reload_acknowledgement']
        assert ack['session']==query.session and ack['generation']==result['after_generation'] and ack['candidate_digest']==report['candidate_digest'],ack
        assert helper_call('operation-status',flags=('--operation-id',collection_id))==result
        baseline=wait(lambda: (m if (m:=model())['observation']=='current' and len(m['outputs'])==2 else None))
        def candidate(m, fields):
            o=m['outputs'][0]
            text='[[output]]\nname = '+json.dumps(o['connector'])+'\n'
            if 'x' in fields or 'y' in fields: text+='position = '+json.dumps([fields.get('x',o['actual']['x']),fields.get('y',o['actual']['y'])])+'\n'
            if 'scale' in fields: text+='scale = '+str(fields['scale'])+'\n'
            if 'mirror_of' in fields: text+='mirror_of = '+json.dumps(fields['mirror_of'])+'\n'
            if 'mode' in fields: text+='mode = '+json.dumps(fields['mode'])+'\n'
            if 'transform' in fields: text+='transform = '+json.dumps(fields['transform'])+'\n'
            if 'enabled' in fields: text+='enabled = '+str(fields['enabled']).lower()+'\n'
            snap=helper_call('snapshot')
            request=dict(protocol=1,expected_generation=snap['generation'],raw_files={'outputs':text})
            validation=helper_call('validate',request)
            return request,dict(display_revision=m['display_revision'],candidate_digest=validation['candidate_review']['candidate_digest'],expected_generation=snap['generation'],wm_source=snap['raw_files']['wm'],outputs_source=text)
        def begin(owner, snapshot=None, **fields):
            m=snapshot or wait(lambda: (v if (v:=model())['observation']=='current' else None))
            _,params=candidate(m,fields)
            return owner.call('display.preview.begin',params)['result']
        def status(token):
            value=query.call('display.preview.status',dict(token=token))['result'];VALIDATOR.validate(value);return value
        def owner():
            c=Client(path);clients.append(c);return c
        def outputd(request):
            with socket.socket(socket.AF_UNIX) as channel:
                channel.settimeout(5);channel.connect(str(base/'run/aqueous/outputd.sock'))
                channel.sendall(json.dumps(request).encode()+b'\n')
                return json.loads(channel.makefile().readline())
        # Backend-test rejection must never schedule the candidate or write files.
        c=owner();_,params=candidate(model(),{'x':90})
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_test_failure'))['ok']
        assert not c.call('display.preview.begin',params,ok=False)['ok']
        assert model()['outputs'][0]['actual']==baseline['outputs'][0]['actual']
        # The confirmation clock starts only after presentation is observed.
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_hold_completion',hold=True))['ok']
        delayed=begin(c,x=75); delayed_token=delayed['token']
        time.sleep(.3)
        pending=status(delayed_token)
        assert pending['state']=='applying' and not pending['supported_actions']['commit'],pending
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_hold_completion',hold=False))['ok']
        wait(lambda: status(delayed_token)['state']=='previewing')
        assert status(delayed_token)['remaining_ms']>14000
        query.call('display.preview.revert',dict(token=delayed_token))
        wait(lambda: status(delayed_token)['state']=='reverted')
        # Commit failure occurs after the successful preflight and must restore
        # both scheduled state and observed hardware, without touching files.
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_commit_failure'))['ok']
        failed=begin(c,scale=1.25); failed_token=failed['token']
        wait(lambda: status(failed_token)['state']=='invalidated')
        assert status(failed_token)['reason']=='apply_failed'
        assert all(o['restored'] and o['hardware_matches'] for o in status(failed_token)['affected_outputs'])
        assert model()['outputs'][0]['actual']==baseline['outputs'][0]['actual']
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_partial_commit'))['ok']
        failed=begin(c,scale=1.25); failed_token=failed['token']
        wait(lambda: status(failed_token)['state']=='invalidated')
        assert all(o['restored'] and o['hardware_matches'] for o in status(failed_token)['affected_outputs'])
        suspended=begin(c,x=85); suspended_token=suspended['token']
        wait(lambda: status(suspended_token)['state']=='previewing')
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_session_inactive',inactive=True))['ok']
        wait(lambda: status(suspended_token)['state']=='waiting_session')
        assert not status(suspended_token)['supported_actions']['commit']
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_session_inactive',inactive=False))['ok']
        wait(lambda: status(suspended_token)['state']=='invalidated')
        assert all(o['restored'] for o in status(suspended_token)['affected_outputs'])
        fallback=begin(c,x=95);fallback_token=fallback['token']
        wait(lambda: status(fallback_token)['state']=='previewing')
        assert outputd(dict(op='test_output_retry',name=model()['outputs'][0]['connector'],action='preview_test_failure'))['ok']
        query.call('display.preview.revert',dict(token=fallback_token))
        wait(lambda: status(fallback_token)['state']=='invalidated')
        assert status(fallback_token)['fallback_used'] and status(fallback_token)['rollback_partial']
        assert any(o['enabled'] and not o['actual']['mirror_of'] for o in model()['outputs'])
        lease=begin(c,x=125)
        token=lease['token']; wait(lambda: status(token)['state']=='previewing')
        assert model()['outputs'][0]['actual']['x']==125
        evidence=query.call('display.preview.evidence',dict(token=token))['result'];VALIDATOR.validate(evidence)
        assert all(o['observed']['target_matches'] and o['observed']['color_matches'] and o['observed']['presented'] for o in evidence['outputs'])
        assert helper_call('preview-features',flags=('--token',token))['preview_evidence']==evidence
        assert not query.call('display.preview.evidence',dict(token='0'*64),ok=False)['ok']

        # Competing native, compatibility and wlr output clients are serialized.
        assert not outputd(dict(op='reload'))['ok']
        assert not outputd(dict(op='save_profile',name='competing',outputs=[]))['ok']
        assert not outputd(dict(op='set',changes=[dict(name=model()['outputs'][0]['connector'],scale=1.5)]))['ok']
        competitor=subprocess.run(['wlr-randr','--output',model()['outputs'][0]['connector'],'--scale','1.5'],env=env,text=True,capture_output=True,timeout=5)
        assert competitor.returncode!=0,competitor.stdout
        assert model()['outputs'][0]['actual']['x']==125

        assert not query.call('display.preview.begin',dict(display_revision=model()['display_revision'],candidate_digest='a'*64,expected_generation='b'*16,outputs=[]),ok=False)['ok']
        query.call('display.preview.revert',dict(token=token))
        wait(lambda: status(token)['state']=='reverted')
        assert model()['outputs'][0]['actual']==baseline['outputs'][0]['actual']
        query.call('display.preview.revert',dict(token=token))
        _,stale=candidate(model(),{'x':1});stale['display_revision']=baseline['display_revision']
        assert not c.call('display.preview.begin',stale,ok=False)['ok']
        lease=begin(c,x=250); token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        c.close(); clients.remove(c)
        wait(lambda: status(token)['state']=='reverted')
        assert model()['outputs'][0]['actual']==baseline['outputs'][0]['actual']
        c=owner(); lease=begin(c,scale=1.25);token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        before=status(token)['remaining_ms'];time.sleep(.2);assert status(token)['remaining_ms']<before
        wait(lambda: status(token)['state']=='reverted',seconds=17)
        assert model()['outputs'][0]['actual']==baseline['outputs'][0]['actual']
        assert (cfg/'wm.toml').read_text()=='[workspace_transition]\nenabled = false\n'
        assert not (cfg/'outputs.toml').exists()
        for fields in [dict(enabled=False),dict(transform='90'),dict(mode='800x600@60')]:
            current=model();before_actual=[o['actual'] for o in current['outputs']]
            snap=helper_call('snapshot')
            structured=dict(protocol=1,expected_generation=snap['generation'],protected_apply=True,
                display_declaration_changes=dict(version=1,sources={'outputs':snap['display_source_ids']['outputs']},operations=[
                    dict(op='add',source='outputs',kind='output',parent=None,set=dict(name=current['outputs'][0]['connector'],**fields))]))
            reviewed=helper_call('validate',structured)
            params=dict(display_revision=current['display_revision'],expected_generation=snap['generation'],
                candidate_digest=reviewed['candidate_review']['candidate_digest'],wm_source=reviewed['raw_files']['wm'],outputs_source=reviewed['raw_files']['outputs'])
            lease=c.call('display.preview.begin',params)['result'];token=lease['token']
            wait(lambda: status(token)['state']=='previewing')
            query.call('display.preview.revert',dict(token=token))
            wait(lambda: status(token)['state']=='reverted')
            assert [o['actual'] for o in model()['outputs']]==before_actual
        # Structured HDR and adaptive sync cannot bypass backend feature gates.
        for feature in ['hdr','adaptive_sync']:
            snap=helper_call('snapshot');current=model()
            structured=dict(protocol=1,expected_generation=snap['generation'],protected_apply=True,
                display_declaration_changes=dict(version=1,sources={'outputs':snap['display_source_ids']['outputs']},operations=[
                    dict(op='add',source='outputs',kind='output',parent=None,set={'name':current['outputs'][0]['connector'],feature:True})]))
            reviewed=helper_call('validate',structured)
            params=dict(display_revision=current['display_revision'],expected_generation=snap['generation'],
                candidate_digest=reviewed['candidate_review']['candidate_digest'],wm_source=reviewed['raw_files']['wm'],outputs_source=reviewed['raw_files']['outputs'])
            assert not c.call('display.preview.begin',params,ok=False)['ok']
            assert not (cfg/'outputs.toml').exists()
        # Raw, deferred, inactive-profile, and offline intent use the same gate.
        for key, value, reason in [('hdr', 'true', 'hdr_unsupported'),
                                   ('adaptive_sync', 'true', 'vrr_unsupported'),
                                   ('auto_hdr', 'true', 'hdr_unsupported'),
                                   ('sdr_white_level', '400', 'hdr_unsupported')]:
            for prefix, selector in [('[display]\napply_on_reload = false\n[[output]]\n', model()['outputs'][0]['connector']),
                                     ('[[display.profile]]\nname = "inactive"\n[[display.profile.output]]\n', model()['outputs'][0]['connector']),
                                     ('[[display.profile]]\nname = "offline"\n[[display.profile.output]]\n', 'DISCONNECTED')]:
                request,params=candidate(model(),{})
                params['outputs_source']=prefix+'name = '+json.dumps(selector)+'\n'+key+' = '+value+'\n'
                request['raw_files']['outputs']=params['outputs_source']
                params['candidate_digest']=helper_call('validate',request)['candidate_review']['candidate_digest']
                response=c.call('display.preview.begin',params,ok=False)
                assert response['error']['code']==reason,response
                assert not (cfg/'outputs.toml').exists()
        # Reject an entire unusable plan without starting a lease.
        _,params=candidate(model(),{'enabled':False})
        params['outputs_source']=''.join('[[output]]\nname = '+json.dumps(o['connector'])+'\nenabled = false\n' for o in model()['outputs'])
        assert not c.call('display.preview.begin',params,ok=False)['ok']
        # Profile declarations, primary routing and reload policy use the
        # candidate configuration during preview and restore on Revert.
        for addition in ['[display]\napply_on_reload = false\n', '[[display.profile]]\nname = "offline"\n[[display.profile.output]]\nname = "DISCONNECTED"\nenabled = false\n', '[[output]]\nname = '+json.dumps(model()['outputs'][1]['connector'])+'\nprimary = true\n']:
            before_primary=[o['primary'] for o in model()['outputs']]
            request,params=candidate(model(),{'x':300})
            params['outputs_source']+=addition
            request['raw_files']['outputs']=params['outputs_source']
            params['candidate_digest']=helper_call('validate',request)['candidate_review']['candidate_digest']
            lease=c.call('display.preview.begin',params)['result'];token=lease['token']
            wait(lambda: status(token)['state']=='previewing')
            if 'primary = true' in addition: assert model()['outputs'][1]['primary'] is True
            query.call('display.preview.revert',dict(token=token))
            wait(lambda: status(token)['state']=='reverted')
            assert [o['primary'] for o in model()['outputs']]==before_primary
        # The canonical resolver activates a fallback when every base selector
        # is offline. Preview must use and restore that same profile.
        before_profile=model()['active_profile'];before_actual=[o['actual'] for o in model()['outputs']]
        request,params=candidate(model(),{'x':300})
        params['outputs_source']='[display]\nfallback_profile = "rescue"\n[[output]]\nname = "DISCONNECTED"\nscale = 1.25\n[[display.profile]]\nname = "rescue"\n[[display.profile.output]]\nname = '+json.dumps(model()['outputs'][0]['connector'])+'\nposition = [333, 0]\n'
        request['raw_files']['outputs']=params['outputs_source']
        raw_validation=helper_call('validate',request)
        # The structured profile/membership path must produce the same native
        # candidate as protected raw editing, including fallback activation.
        request.pop('raw_files')
        request.update(protected_apply=True,display_declaration_changes=dict(version=1,sources={'outputs':helper_call('snapshot')['display_source_ids']['outputs']},operations=[
            dict(op='add',source='outputs',kind='policy',set=dict(fallback_profile='rescue')),
            dict(op='add',source='outputs',kind='output',parent=None,set=dict(name='DISCONNECTED',scale=1.25)),
            dict(op='add',source='outputs',kind='profile',ref='rescue',set=dict(name='rescue')),
            dict(op='add',source='outputs',kind='output',parent='new:rescue',set=dict(name=model()['outputs'][0]['connector'],position=[333,0]))]))
        validation=helper_call('validate',request)
        assert validation['candidate_impact']['display']==raw_validation['candidate_impact']['display']
        params['outputs_source']=validation['raw_files']['outputs']
        assert validation['candidate_impact']['display']['activated_profile']=='rescue',validation['candidate_impact']
        params['candidate_digest']=validation['candidate_review']['candidate_digest']
        lease=c.call('display.preview.begin',params)['result'];token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        assert model()['active_profile']=='rescue' and model()['outputs'][0]['actual']['x']==333
        query.call('display.preview.revert',dict(token=token))
        wait(lambda: status(token)['state']=='reverted')
        assert model()['active_profile']==before_profile and [o['actual'] for o in model()['outputs']]==before_actual
        request,params=candidate(model(),{'x':400})
        # A collection mutation remains on the native display path when mixed
        # with an output change, and the lease binds the entire candidate.
        request['window_rule_changes']=[dict(op='add',values=dict(app_id='pearl-test-*',floating=False,opacity=0.8))]
        request['backup_dir']=str(base/'backups')
        request.pop('raw_files')
        request.update(protected_apply=True,display_declaration_changes=dict(version=1,sources={'outputs':helper_call('snapshot')['display_source_ids']['outputs']},operations=[
            dict(op='add',source='outputs',kind='output',parent=None,set=dict(name=model()['outputs'][0]['connector'],position=[400,0]))]))
        validation=helper_call('validate',request)
        impact=validation['candidate_impact']
        assert impact['complete'] and impact['display'] is not None,impact
        assert 'runtime_non_display' in impact['effects'] and 'display_live' in impact['effects'],impact
        params['candidate_digest']=impact['candidate_digest']
        params['outputs_source']=validation['raw_files']['outputs']
        request['protected_apply']=True
        for extra,code in [({},'candidate_mismatch'),({'candidate_digest':'0'*64},'candidate_mismatch'),
                ({'candidate_digest':params['candidate_digest']},'missing_display_revision'),
                ({'candidate_digest':params['candidate_digest'],'expected_display_revision':model()['display_revision'],'expected_session':query.session},'display_preview_required')]:
            rejected=subprocess.run([str(helper),'apply','--shell','none','--request','-'],input=json.dumps(request|extra),text=True,capture_output=True,env=env,timeout=35)
            assert json.loads(rejected.stdout).get('code')==code,(rejected.stdout,rejected.stderr)
            assert not (cfg/'outputs.toml').exists() and not (base/'backups').exists()
        lease=c.call('display.preview.begin',params)['result'];token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        id=str(int(time.time()))+'-'+uuid.uuid4().hex
        request.update(preview_token=token,candidate_digest=params['candidate_digest'])
        result=helper_call('apply',request,('--result','v1','--operation-id',id))
        assert result['save']=='saved' and result['display']=='kept' and result['reload']=='applied',result
        ack=result['reload_acknowledgement'];assert ack['session']==query.session and ack['generation']==result['after_generation'] and ack['candidate_digest']==result['candidate_digest']
        assert status(token)['state']=='kept'
        assert (cfg/'outputs.toml').read_text()==params['outputs_source']
        assert 'pearl-test-*' in (cfg/'rules.toml').read_text()
        assert helper_call('operation-status',flags=('--operation-id',id))==result
        assert helper_call('apply',request,('--result','v1','--operation-id',id))==result
        # An unchanged reviewed candidate can still end its lease through a
        # durable decision; it must not require a fabricated file replacement.
        request,params=candidate(model(),{'x':400})
        request['raw_files']['outputs']=params['outputs_source']=(cfg/'outputs.toml').read_text()
        params['candidate_digest']=helper_call('validate',request)['candidate_review']['candidate_digest']
        lease=c.call('display.preview.begin',params)['result'];token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        id=str(int(time.time()))+'-'+uuid.uuid4().hex
        request.update(preview_token=token,candidate_digest=params['candidate_digest'],raw_files={})
        result=helper_call('apply',request,('--result','v1','--operation-id',id))
        assert result['save']=='unchanged' and result['display']=='kept' and result['before_generation']==result['after_generation'],{k:result.get(k) for k in ['save','display','before_generation','after_generation','failure']}
        request,params=candidate(model(),{'x':model()['outputs'][0]['actual']['x']+10})
        lease=c.call('display.preview.begin',params)['result'];token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        operation=str(int(time.time()))+'-'+uuid.uuid4().hex
        request.update(preview_token=token,candidate_digest=params['candidate_digest'])
        paused=subprocess.Popen([str(helper.parent/'aqueous-backend-test'),'apply','--shell','none','--result','v1','--operation-id',operation,'--request','-'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env|{'AQUEOUS_TEST_STOP_AT':'journal_committed'})
        try:
            paused.stdin.write(json.dumps(request)); paused.stdin.close(); paused.stdin=None
            wait(lambda: 'State:\tT' in Path(f'/proc/{paused.pid}/status').read_text())
            wait(lambda: status(token)['reason']=='waiting_for_commit_writer',seconds=12)
            assert status(token)['state']=='commit_authorized'
            paused.send_signal(signal.SIGCONT)
            stdout,stderr=paused.communicate(timeout=15)
            assert paused.returncode==0,(stdout,stderr)
            wait(lambda: status(token)['state']=='kept')
        finally:
            if paused.poll() is None: paused.kill();paused.wait(timeout=5)
        for stage in ['commit_authorized','journal_prepared','journal_committed']:
            # The preceding receipt remains queryable while a later operation
            # is interrupted at each durable boundary.
            request,params=candidate(model(),{'x':model()['outputs'][0]['actual']['x']+50})
            lease=c.call('display.preview.begin',params)['result'];token=lease['token']
            wait(lambda: status(token)['state']=='previewing')
            id=str(int(time.time()))+'-'+uuid.uuid4().hex
            request.update(preview_token=token,candidate_digest=params['candidate_digest'])
            before=(cfg/'outputs.toml').read_text()
            driver=helper.parent/'aqueous-backend-test'
            crash_env=env|{'AQUEOUS_TEST_CRASH_AT':stage}
            p=subprocess.run([str(driver),'apply','--shell','none','--result','v1','--operation-id',id,'--request','-'],input=json.dumps(request),text=True,capture_output=True,env=crash_env,timeout=35)
            assert p.returncode==97,(stage,p.stdout,p.stderr)
            receipt=helper_call('operation-status',flags=('--operation-id',id))
            expected='kept' if stage=='journal_committed' else 'invalidated'
            wait(lambda: status(token)['state']==expected,seconds=12)
            assert (cfg/'outputs.toml').read_text()==(params['outputs_source'] if stage=='journal_committed' else before)
            assert receipt['save']==('saved' if stage=='journal_committed' else 'failed' if stage=='journal_prepared' else 'uncertain'),receipt
            # Bring the canonical generation into the loader before the next
            # candidate validation; this is an explicit test-side reload.
            query.command('session.reload')
        # Mirroring uses the same lease and complete dependency set.
        current=model();before_actual=[o['actual'] for o in current['outputs']]
        source_name=current['outputs'][1]['connector']
        lease=begin(c,mirror_of=source_name);token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        assert model()['outputs'][0]['actual']['mirror_of']==source_name
        query.call('display.preview.revert',dict(token=token))
        wait(lambda: status(token)['state']=='reverted')
        assert [o['actual'] for o in model()['outputs']]==before_actual
        lease=begin(c,mirror_of=source_name);token=lease['token']
        wait(lambda: status(token)['state']=='previewing')
        with socket.socket(socket.AF_UNIX) as test_socket:
            test_socket.settimeout(5);test_socket.connect(str(base/'run/aqueous/outputd.sock'))
            test_socket.sendall(json.dumps(dict(op='test_output_retry',name=source_name,action='destroy')).encode()+b'\n')
            reply=json.loads(test_socket.makefile().readline());assert reply['ok'],reply
        wait(lambda: status(token)['state'] in ('invalidated','failed'))
        remaining=model()['outputs'];assert len(remaining)==1 and remaining[0]['enabled']
        assert status(token)['rollback_partial'] or status(token)['state']=='failed'
        # Compositor death invalidates tokens and startup recovers the complete
        # canonical generation before its output/config loaders run.
        def restart():
            global proc, query, path
            for client in clients: client.close()
            clients.clear()
            os.killpg(proc.pid, signal.SIGKILL);proc.wait(timeout=5)
            (base/'run/socket').unlink(missing_ok=True)
            boot_env={k:v for k,v in env.items() if k not in ('AQUEOUS_SOCKET','WAYLAND_DISPLAY')}
            proc=subprocess.Popen(['dbus-run-session','--',str(BIN),'-no-xwayland','-c','printenv AQUEOUS_SOCKET WAYLAND_DISPLAY > "$XDG_RUNTIME_DIR/socket"'],env=boot_env,stdout=log,stderr=log,start_new_session=True)
            path=wait(socket_path)
            env.update(AQUEOUS_SOCKET=path,WAYLAND_DISPLAY=(base/'run/socket').read_text().splitlines()[1])
            query=Client(path);clients.append(query)
            wait(lambda: model()['observation']=='current' and len(model()['outputs'])==2)
        restart()
        for stage in ['previewing','journal_prepared','journal_committed']:
            c=owner();request,params=candidate(model(),{'x':model()['outputs'][0]['actual']['x']+35})
            lease=c.call('display.preview.begin',params)['result'];token=lease['token']
            wait(lambda: status(token)['state']=='previewing')
            previous_session=query.session;before=(cfg/'outputs.toml').read_text()
            if stage!='previewing':
                id=str(int(time.time()))+'-'+uuid.uuid4().hex
                request.update(preview_token=token,candidate_digest=params['candidate_digest'])
                p=subprocess.run([str(helper.parent/'aqueous-backend-test'),'apply','--shell','none','--result','v1','--operation-id',id,'--request','-'],input=json.dumps(request),text=True,capture_output=True,env=env|{'AQUEOUS_TEST_CRASH_AT':stage},timeout=35)
                assert p.returncode==97,(stage,p.stdout,p.stderr)
            restart()
            assert query.session!=previous_session
            assert not query.call('display.preview.status',dict(token=token),ok=False)['ok']
            assert (cfg/'outputs.toml').read_text()==(params['outputs_source'] if stage=='journal_committed' else before)
            assert model()['config_generation']==helper_call('snapshot')['generation']
        print('PASS: negotiated feature/evidence schemas, helper queries, deferred/profile/offline feature admission')
        print('PASS: native headless placement/mode/enable/primary/profile/mirror preview, Keep and rollback')
        print('PASS: structured profile/raw projection equivalence and mixed declaration/collection protected commit')
        print('PASS: protected collection apply and native generation/digest-bound reload acknowledgement')
        print('PASS: owner disconnect, timeout, stale revision, mirror-source removal, helper death and compositor restart/recovery')
        print('PASS: presentation-gated confirmation, failed/partial commits, session resume, tested fallback and commit writer deadline')

    except Exception:
        log.seek(0);print('\n'.join(log.read().splitlines()[-35:]));raise
    finally:
        for c in clients:c.close()
        os.killpg(proc.pid, signal.SIGTERM)
        try:proc.wait(timeout=5)
        except subprocess.TimeoutExpired:os.killpg(proc.pid, signal.SIGKILL);proc.wait()
        log.close()
