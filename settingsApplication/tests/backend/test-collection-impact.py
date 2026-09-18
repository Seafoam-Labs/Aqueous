#!/usr/bin/env python3
"""Collection impact and protected saves against isolated files and reload stub.

The stub only acknowledges reload; native display projection is tested separately
by compositor/scripts/test-display-preview.py. No user configuration is accessed.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

HELPER = str(Path(sys.argv[1]).resolve())
NAMES = ('wm', 'layout', 'input', 'outputs', 'rules', 'appearance')
RULE = '[[window]]\napp_id = "pearl-test-*"\nfloating = false\nopacity = 0.8\n'
ZONE = dict(id='editor', name='Editor', x=0, y=0, width=0.75, height=1)
LAYOUTS = [dict(id='work', name='Work', padding=8, zones=[ZONE, dict(ZONE, id='terminal', name='Terminal', x=0.75, width=0.25)]),
           dict(id='play', name='Play', zones=[dict(ZONE, id='full', width=1)])]

with tempfile.TemporaryDirectory(prefix='aqueous-collection-impact-') as scratch:
    root = Path(scratch)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('AQUEOUS_', 'NOCTALIA_')) and k not in
           ('DBUS_SESSION_BUS_ADDRESS', 'LD_PRELOAD', 'WAYLAND_DISPLAY', 'DISPLAY')}
    for key, name in [('HOME', 'home'), ('XDG_CONFIG_HOME', 'config'),
                      ('XDG_STATE_HOME', 'state'), ('XDG_RUNTIME_DIR', 'runtime')]:
        path = root / name
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(WAYLAND_DISPLAY='absent-collection-test', DISPLAY='', GSETTINGS_BACKEND='memory')
    cfg = root / 'config/aqueous'
    cfg.mkdir()
    files = {name: cfg / (name + '.toml') for name in NAMES}
    for name, path in files.items():
        env['AQUEOUS_CONFIG' if name == 'wm' else 'AQUEOUS_' + name.upper()] = str(path)
    bindir = root / 'bin'
    bindir.mkdir()
    ctl = bindir / 'aqueousctl'
    ctl.write_text('#!/bin/sh\nif [ "$1" = outputs ]; then echo "[]"; else echo \'{"ok":true,"status":"applied","sequence":"1"}\'; fi\n')
    ctl.chmod(0o755)
    env['PATH'] = str(bindir) + ':' + os.environ['PATH']

    def call(op, req=None, ok=True):
        args = [HELPER, op, '--shell', 'none']
        if req is not None:
            args += ['--request', '-']
        proc = subprocess.run(args, input=None if req is None else json.dumps(req),
                              env=env, text=True, capture_output=True, timeout=35)
        result = json.loads(proc.stdout)
        assert bool(result['ok']) == ok, (op, req, result, proc.stderr)
        assert (proc.returncode == 0) == ok, (result, proc.stderr)
        return result

    def seed(**sources):
        for name, path in files.items():
            path.write_text(sources.get(name, ''))
        return call('snapshot')

    def check(snapshot, mutations, complete=True, effects=None, apply=False):
        req = dict(protocol=1, expected_generation=snapshot['generation'], **mutations)
        before = {name: p.read_bytes() for name, p in files.items()}
        result = call('validate', req)
        impact = result['candidate_impact']
        assert impact['complete'] == complete, (mutations, impact)
        if effects is None:
            effects = ['runtime_non_display'] if complete else ['unknown']
        assert set(impact['effects']) == set(effects), (mutations, impact)
        assert impact['candidate_digest'] == result['candidate_review']['candidate_digest']
        assert {name: p.read_bytes() for name, p in files.items()} == before
        if apply or not complete:
            applied = call('apply', dict(req, protected_apply=True), ok=complete)
            if complete:
                assert applied['raw_files'] == result['raw_files']
            else:
                assert applied['code'] == 'unclassified_candidate', applied
                assert {name: p.read_bytes() for name, p in files.items()} == before
        return result

    s = seed()
    s = check(s, {'window_rule_changes': [dict(op='add', values=dict(app_id='pearl-test-*', floating=False, opacity=0.8))]}, apply=True)
    rule_id = s['window_rules'][0]['id']
    s = check(s, {'window_rule_changes': [dict(id=rule_id, values=dict(floating=None, opacity=0, x=0))]}, apply=True)
    assert 'floating' not in s['window_rules'][0]['values']
    assert s['window_rules'][0]['values']['opacity'] == 0
    check(s, {'window_rule_changes': [dict(op='delete', id=rule_id)]}, apply=True)

    s = seed(rules=RULE)
    s = check(s, {'window_rule_changes': [dict(id=s['window_rules'][0]['id'], values=dict(scrolling_width=0.65))]}, apply=True)
    assert s['window_rules'][0]['values']['scrolling_width'] == 0.65
    check(s, {'raw_files': {'rules': RULE + 'scrolling_width = 0.650\n'}}, effects=['none'])
    check(s, {'raw_files': {'rules': RULE + 'scrolling_width = 0.25\n'}}, apply=True)
    s = call('snapshot')
    check(s, {'window_rule_changes': [dict(id=s['window_rules'][0]['id'], values=dict(scrolling_width=None))]}, apply=True)
    for invalid in ['0', '-0.1', '1.01', 'nan', 'inf', '-inf', '"invalid"']:
        s = seed(rules=RULE)
        before = files['rules'].read_bytes()
        call('validate', dict(protocol=1, expected_generation=s['generation'],
                             raw_files={'rules': RULE + 'scrolling_width = ' + invalid + '\n'}), ok=False)
        assert files['rules'].read_bytes() == before
        s = seed(rules=RULE + 'scrolling_width = ' + invalid + '\n')
        check(s, {'raw_files': {'rules': RULE}}, complete=False)

    s = seed(rules=RULE + RULE.replace('false', 'true'))
    check(s, {'window_rule_changes': [dict(op='move', id=s['window_rules'][1]['id'], direction=-1)]}, apply=True)
    s = seed(rules=RULE + RULE)
    check(s, {'window_rule_changes': [dict(op='delete', id=s['window_rules'][1]['id'])]}, apply=True)
    s = seed(rules=RULE + RULE)
    check(s, {'window_rule_changes': [dict(op='move', id=s['window_rules'][1]['id'], direction=-1)]}, effects=['none'])
    s = seed(rules=RULE)
    check(s, {'raw_files': {'rules': RULE.replace('opacity = 0.8', 'opacity = 0.800')}}, effects=['none'])
    check(s, {'raw_files': {'rules': '[[window]]\nopacity = 0.8\nfloating = false\napp_id = "pearl-test-*"\n'}})
    check(s, {'raw_files': {'rules': '# rule comment\n' + RULE}}, effects=['none'])
    s = seed(rules='[[window]]\napp_id = "*"\nlayout = "stacking"\nfloating = false\n')
    check(s, {'raw_files': {'rules': '[[window]]\napp_id = "*"\nfloating = false\nlayout = "stacking"\n'}})
    s = seed(rules=RULE + 'tag = "\\\\*"\n')
    check(s, {'window_rule_changes': [dict(id=s['window_rules'][0]['id'], values={'tag': ''})]}, apply=True)

    # Unknown extensions on either side, including deletion/repair, stay unknown.
    for extension in ['future_rule = false\n', 'future_rule = [1, 2]\n']:
        s = seed(rules=RULE + extension)
        check(s, {'window_rule_changes': [dict(id=s['window_rules'][0]['id'], values={'floating': True})]}, complete=False)
        check(s, {'window_rule_changes': [dict(op='delete', id=s['window_rules'][0]['id'])]}, complete=False)
        check(s, {'raw_files': {'rules': RULE}}, complete=False)
    for original in [RULE.replace('0.8', '2.0'), RULE.replace('false', '"false"'),
                     RULE.replace('"pearl-test-*"', '17'), RULE + 'floating = true\n',
                     '[window]\napp_id = "test"\n', '[[window]]\n', RULE + 'ignored garbage\n',
                     RULE.replace('[[window]]', '[[ window ]]'), RULE.replace('floating', '"floating"'),
                     RULE + 'size = "2147483648x100"\n']:
        s = seed(rules=original)
        check(s, {'raw_files': {'rules': RULE}}, complete=False)
    s = seed(rules=RULE)
    check(s, {'raw_files': {'rules': RULE + 'future_rule = "extension"\n'}}, complete=False)
    for values in [dict(app_id='*', opacity=2), dict(app_id='*', size='2147483648x100')]:
        s = seed()
        before = {name: path.read_bytes() for name, path in files.items()}
        call('validate', dict(protocol=1, expected_generation=s['generation'],
                              window_rule_changes=[dict(op='add', values=values)]), ok=False)
        assert {name: path.read_bytes() for name, path in files.items()} == before

    s = seed()
    command = 'spawn:printf "%s,%s" "a:b" "[display]" # command comment'
    s = check(s, {'custom_keybind_changes': [dict(op='add', chord='Super+F12', command=command)]}, apply=True)
    binding_id = s['custom_keybinds'][0]['id']
    s = check(s, {'custom_keybind_changes': [dict(id=binding_id, chord='Super+F11', command='builtin:snap_zone:work/editor')]}, apply=True)
    binding_id = s['custom_keybinds'][0]['id']
    check(s, {'custom_keybind_changes': [dict(op='delete', id=binding_id)]}, apply=True)
    for command in ['launch:editor', 'set_layout:stacking', 'builtin:close_focused', 'spawn:echo one\necho two']:
        s = seed()
        check(s, {'custom_keybind_changes': [dict(op='add', chord='Ctrl+WheelUp', command=command)]}, apply=True)
    for command in ['future:argument', 'spawn:', 'set_layout:future', 'builtin:future', 'x' * 257]:
        s = seed()
        check(s, {'custom_keybind_changes': [dict(op='add', chord='Super+F12', command=command)]}, complete=False)
    s = seed(wm='[keybinds.custom]\n"Super+F12" = "future:argument"\n')
    check(s, {'custom_keybind_changes': [dict(op='delete', id=s['custom_keybinds'][0]['id'])]}, complete=False)
    s = seed(wm='[keybinds.custom]\n"Super+F12" = "spawn:one"\n"Mod4+F12" = "spawn:two"\n')
    check(s, {'raw_files': {'wm': '[keybinds.custom]\n"Mod4+F12" = "spawn:two"\n"Super+F12" = "spawn:one"\n'}}, apply=True)
    s = seed(wm='[keybinds.custom]\n"NotAKey" = "spawn:one"\n')
    check(s, {'raw_files': {'wm': ''}}, complete=False)

    s = seed()
    s = check(s, {'snap_layouts': LAYOUTS, 'default_snap_layout': 'work'}, apply=True)
    source = s['raw_files']['layout']
    s = check(s, {'snap_layouts': [dict(LAYOUTS[0], zones=list(reversed(LAYOUTS[0]['zones']))), LAYOUTS[1]],
                  'default_snap_layout': 'work'}, apply=True)
    s = check(s, {'snap_layouts': list(reversed(LAYOUTS)), 'default_snap_layout': 'play'}, apply=True)
    s = check(s, {'snap_layouts': [dict(LAYOUTS[0], zones=[dict(ZONE, width=0.5)])], 'default_snap_layout': 'work'}, apply=True)
    check(s, {'snap_layouts': [], 'default_snap_layout': ''}, apply=True)
    s = seed(layout=source)
    check(s, {'raw_files': {'layout': source.replace('0.75', '0.750')}}, effects=['none'])
    for original in [source.replace('padding = 8', 'padding = 999'),
                     source.replace('snap_layout = "work"', 'snap_layout = "absent"'),
                     source + '[layout.snap-layout.work.zone.bad]\nx = 0\ny = 0\nwidth = 2\nheight = 1\n',
                     source.replace('padding = 8', 'padding = 8\nfuture = true'),
                     source + '[layout.snap-layout.work]\nname = "duplicate"\n',
                     source.replace('padding = 8', '"padding" = 8')]:
        s = seed(layout=original)
        check(s, {'raw_files': {'layout': source}}, complete=False)
    s = seed(layout=source)
    check(s, {'raw_files': {'layout': source + '[layout.snap-layout.future]\nextension = true\n'}}, complete=False)
    s = seed(layout=source + '[layout.snap-layout.work.zone.bad.extra]\nextension = true\n')
    check(s, {'raw_files': {'layout': files['layout'].read_text().replace('padding = 8', 'padding = 9')}}, complete=False)
    s = seed()
    s = check(s, {'snap_zone_changes': [dict(id='a', x=0, y=0, width=1, height=1)]}, apply=True)
    check(s, {'snap_zone_changes': [dict(id='a', op='delete')]}, apply=True)

    # No caller-supplied classification, filename blanket or raw overlap bypass.
    s = seed()
    check(s, {'raw_files': {'rules': RULE}, 'candidate_impact': {'complete': True, 'effects': ['none']}}, apply=True)
    s = seed()
    check(s, {'raw_files': {'wm': '[future]\n', 'rules': RULE}}, complete=False,
          effects=['runtime_non_display', 'unknown'])
    s = seed(rules='[future_a]\n')
    check(s, {'raw_files': {'rules': '[future_b]\n'}}, complete=False)
    s = seed()
    check(s, {'raw_files': {'wm': '[blur]\nenabled = false\n', 'layout': '[future]\n'}}, complete=False,
          effects=['runtime_non_display', 'unknown'])
    # Unknown fields in a recognized layout table cannot use the filename as proof.
    s = seed()
    check(s, {'raw_files': {'layout': '[layout]\nfuture = true\n'}}, complete=False,
          effects=['runtime_non_display', 'unknown'])
    s = seed()
    check(s, {'window_rule_changes': [dict(op='add', values={'app_id': '*'})],
              'raw_files': {'outputs': '[[output]]\nname = "HEADLESS-1"\nscale = 1.5\n'}},
          complete=False, effects=['runtime_non_display', 'unknown'])
    s = seed()
    overlap = call('validate', dict(protocol=1, expected_generation=s['generation'],
                                   raw_files={'rules': RULE}, window_rule_changes=[dict(op='add', values={'app_id': '*'})]), ok=False)
    assert overlap['message'] == 'ConflictingEdits', overlap
    multiline = '[[window]]\napp_id = """\n[display]\nhdr = true\n"""\nfloating = false\n'
    s = seed(rules=multiline)
    check(s, {'raw_files': {'rules': RULE}}, complete=False)
    s = seed(rules=RULE)
    # This passes the legacy basic-line validator but is ambiguous to Document.
    check(s, {'raw_files': {'rules': RULE + 'extension = """\n[display]\nhdr = true\nend = """\n'}}, complete=False)

print('PASS: collection operations, original/candidate semantics, protected saves, and raw/display uncertainty')
