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
    old_results, old_files = sequence(legacy)
    new_results, new_files = sequence(driver)
    # Protocol 1 permits negotiated additive members. Compare every original
    # member, capability and saved byte; omit only explicitly new contracts.
    additions = {'display_configuration', 'display_declarations', 'candidate_review', 'collection_identity', 'display_model', 'display_observation', 'candidate_impact', 'collection_schema', 'collection_preconditions', 'collection_preconditions_v2', 'collection_transaction', 'display_declaration_mutations', 'display_source_ids'}
    extra_capabilities = {'display_configuration_v1', 'candidate_review_v1', 'helper_writer_lock_v1', 'apply_result_v1', 'collection_identity_v1', 'display_model_v2', 'recoverable_commit_v1', 'operation_receipts_v1', 'candidate_impact_v1', 'display_observation_v1', 'display_preview_commit_v1', 'collection_schema_v1', 'collection_preconditions_v1', 'collection_preconditions_v2', 'protected_collection_apply_v1', 'display_declaration_mutations_v1'}
    for (old_code, old), (new_code, new) in zip(old_results, new_results, strict=True):
        assert old_code == new_code
        for key in additions:
            new.pop(key, None)
        if 'helper_version' in new:
            new['helper_version'] = old['helper_version']
        if 'capabilities' in new:
            new['capabilities'] = [c for c in new['capabilities'] if c not in extra_capabilities]
        for rule in new.get('window_rules', []):
            rule.pop('diagnostics', None)
        assert old == new, 'backend diverged from the protocol-1 oracle'
    assert old_files == new_files, 'canonical TOML differs from the protocol-1 oracle'
    print('Legacy and embedded backend agree: snapshots, Validate, Apply, errors and saved TOML.')
