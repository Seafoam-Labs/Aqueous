"""Exercise shortcut recording against the isolated compositor."""
import subprocess, time, tomllib


def run(app, env, base, config, ui, control, click, inject, capture):
    original = (config / 'wm.toml').read_bytes()
    def values():
        return [c['text'] for c in ui()['controls'] if c['action']=='shortcut_record' and c['key']=='existing']
    def saved():
        deadline=time.monotonic()+8
        while ui()['pending'] and time.monotonic()<deadline: time.sleep(.1)
        assert ui()['pending']==0, ui()
    with (base/'shortcut-test.log').open('w+') as log:
        child=subprocess.Popen([str(app),'--shell','none','--page','keybinds'],env=env,stderr=log)
        try:
            time.sleep(2)
            assert control('field','spawn_terminal')['widget']=='button'
            before=control('field','spawn_terminal')['text']
            click('field','spawn_terminal')
            control('shortcut_stop')  # The compositor activated shortcut inhibition.
            assert values()==['Super+Return','Super+T'], values()
            inject(42)  # A modifier alone must not become a shortcut.
            control('shortcut_stop')
            inject('MS103')
            assert values()==['Super+Shift+Up','Super+T'], values()
            assert ui()['pending']==0
            capture('shortcut-recorded')
            click('shortcut_cancel')
            assert ui()['pending']==0 and control('field','spawn_terminal')['text']==before
            click('field','spawn_terminal'); inject('C33')
            assert values()[0]=='Ctrl+F' and ui()['page']=='keybinds', ui()
            click('shortcut_record','add'); inject(88)  # F12
            assert values()==['Ctrl+F','Super+T','F12'], values()
            click('shortcut_accept')
            assert ui()['pending']==1
            click('page',index=1); click('page',index=6)
            assert control('field','spawn_terminal')['text']=='Ctrl+F · Super+T · F12'
            click('apply'); saved()
            wm=tomllib.loads((config/'wm.toml').read_text())
            assert wm['keybinds']['spawn_terminal']==['Ctrl+F','Super+T','F12'], wm['keybinds']['spawn_terminal']
            # Remove one alternative, then all alternatives to unbind the action.
            click('field','spawn_terminal'); click('shortcut_stop')
            click('shortcut_remove',index=1)
            assert values()==['Ctrl+F','F12']
            click('shortcut_remove',index=0); click('shortcut_remove',index=0)
            click('shortcut_accept'); click('apply'); saved()
            assert tomllib.loads((config/'wm.toml').read_text())['keybinds']['spawn_terminal']==[]
            # Custom command survives replacing its chord, including media keys.
            click('keybind','chord'); inject(113)  # XF86AudioMute
            assert values()==['XF86AudioMute'], values()
            click('shortcut_record','existing',0); inject('CA45')
            assert values()==['Ctrl+Alt+X'], values()
            click('shortcut_accept'); click('apply'); saved()
            custom=tomllib.loads((config/'wm.toml').read_text())['keybinds']['custom']
            assert custom['Ctrl+Alt+X']=='spawn:nemo' and 'Super+E' not in custom, custom
            # Escape cancels capture, and normal application shortcuts resume.
            click('keybind','chord'); inject(1)
            assert not any(c['action']=='shortcut_cancel' for c in ui()['controls'])
            inject('C33')
            assert ui()['focus']==control('search')['id'], 'Ctrl+F did not resume after recording'
            assert ui()['pending']==0
            print('Shortcut recording passed: inhibition, modifier-only input, arrows, function/media keys, alternatives, cancel, unbind, custom commands and Apply')
        finally:
            capture('shortcut-last-state')
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
            log.seek(0); errors=log.read()
            assert child.returncode in (0,-15), errors
            assert 'panic' not in errors and 'dispatch failed' not in errors, errors
            (config/'wm.toml').write_bytes(original)
