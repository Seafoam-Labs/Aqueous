"""Exercise the window rule editor with actual pointer and keyboard input."""
import subprocess, time, tomllib


def run(app, env, base, config, ui, control, click, focus, inject, capture):
    def wait_saved():
        deadline = time.monotonic() + 8
        while ui()['pending'] and time.monotonic() < deadline:
            time.sleep(.1)
        assert ui()['pending'] == 0, ('rule changes did not save', ui())

    def select_step(action, key, direction):
        focus(action, key)
        inject(direction)

    def rules():
        return tomllib.loads((config / 'rules.toml').read_text())['window']

    original = (config / 'rules.toml').read_bytes()
    with (base / 'rule-editor.log').open('w+') as log:
        child = subprocess.Popen([str(app), '--shell', 'none', '--page', 'rules'], env=env, stderr=log)
        try:
            time.sleep(2)
            assert child.poll() is None
            assert control('select_rule')['selected'] == '1 · App: steam_app_*'
            assert {c['key'] for c in ui()['controls'] if c['action'] == 'rule_field'} == {
                'app_id', 'class', 'title', 'tag', 'content_type', 'layout', 'blur', 'opacity'}
            assert control('rule_field', 'blur')['selected'] == 'Off'
            select_step('rule_field', 'blur', 103)
            assert control('rule_field', 'blur')['selected'] == 'On', (control('rule_field', 'blur'), ui()['focus'], ui()['pending'])
            click('rule_field', 'opacity'); inject('C30', 11, 52, 8, 6, 28)  # 0.75
            assert float(control('rule_field', 'opacity')['text']) == .75
            select_step('select_rule', None, 108)
            assert 'Dialog #1' in control('select_rule')['selected']
            assert control('rule_field', 'layout')['selected'] == 'stacking'
            select_step('select_rule', None, 103)
            click('rule_field', 'opacity')  # Instantiate the scrolled-out text input before inspecting it.
            assert float(control('rule_field', 'opacity')['text']) == .75
            assert control('rule_field', 'blur')['selected'] == 'On', (control('rule_field', 'blur'), ui()['focus'], ui()['pending'])
            capture('rule-changes')
            click('apply'); wait_saved()
            assert rules()[0]['opacity'] == .75 and rules()[0]['blur'] is True
            assert rules()[1]['title'] == 'Dialog #1 = ready'

            # Reordering keeps the chosen rule selected, including after Discard.
            click('move_down')
            assert control('select_rule')['selected'] == '2 · App: steam_app_*'
            assert not any(c['action'] == 'rule_field' for c in ui()['controls'])
            click('reload'); click('discard'); wait_saved()
            assert control('select_rule')['selected'] == '1 · App: steam_app_*'
            click('move_down'); click('apply'); wait_saved()
            assert rules()[1]['app_id'] == 'steam_app_*'
            assert control('select_rule')['selected'] == '2 · App: steam_app_*'

            click('rule_options')
            assert len([c for c in ui()['controls'] if c['action'] == 'rule_field']) == 29
            assert control('rule_field', 'fullscreen')['selected'] == 'No override'
            assert control('rule_field', 'content_type')['selected'] == 'Any content type'
            select_step('rule_field', 'blur', 103)
            assert control('rule_field', 'blur')['selected'] == 'No override'
            click('rule_field', 'opacity'); inject('C30', 45, 28)  # invalid x
            before = (config / 'rules.toml').read_bytes()
            click('apply')
            assert (config / 'rules.toml').read_bytes() == before, 'invalid value was saved'
            click('rule_field', 'opacity'); inject('C30', 11, 52, 9, 6, 28)  # 0.85
            click('apply'); wait_saved()
            assert rules()[1]['opacity'] == .85 and 'blur' not in rules()[1]

            # Clearing an override must keep it visible until Apply.
            click('rule_options')
            click('rule_field', 'opacity'); inject('C30', 14, 28)
            assert control('rule_field', 'opacity')['text'] == ''
            click('apply'); wait_saved()
            assert 'opacity' not in rules()[1]
            # Removing a rule also removes its invalid draft fields.
            click('rule_options')
            click('rule_field', 'opacity'); inject(45, 28)
            click('remove_rule'); click('apply'); wait_saved()
            assert len(rules()) == 1 and rules()[0]['title'] == 'Dialog #1 = ready'
            capture('rule-editor')
            print('Window rule editing passed: selection, nullable choices, decimal edits, invalid drafts, order, removal, Apply and Discard')
        finally:
            capture('rule-last-state')
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait()
            log.seek(0)
            errors = log.read()
            assert child.returncode in (0, -15), errors
            assert 'panic' not in errors and 'dispatch failed' not in errors, errors
            # Other interaction scenarios start with the same fixture.
            (config / 'rules.toml').write_bytes(original)
