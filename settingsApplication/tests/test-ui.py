#!/usr/bin/env python3
"""Run all pages in an isolated headless Aqueous session."""
import json, os, pathlib, selectors, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = ROOT / 'settingsApplication/zig-out/bin/aqueous-settings'
with tempfile.TemporaryDirectory(prefix='aqueous-settings-ui-') as tmp:
    base = pathlib.Path(tmp)
    runtime = base / 'runtime'; runtime.mkdir(mode=0o700)
    config = base / 'config/aqueous'; config.mkdir(parents=True)
    for file in (ROOT/'settingsApplication/tests/fixtures').glob('*.toml'):
        (config/file.name).write_bytes(file.read_bytes())
    env = {k:v for k,v in os.environ.items() if not k.startswith('AQUEOUS_') and k not in ('DISPLAY','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS','LD_PRELOAD')}
    env.update(HOME=str(base), XDG_CONFIG_HOME=str(base/'config'), XDG_STATE_HOME=str(base/'state'), XDG_CACHE_HOME=str(base/'cache'), XDG_RUNTIME_DIR=str(runtime),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_RENDERER='pixman',
               AQUEOUS_CONFIG=str(config/'wm.toml'),
               PATH=str(pathlib.Path(os.environ.get('AQUEOUSCTL_BIN',str(ROOT/'compositor/zig-out/bin/aqueousctl'))).parent)+':'+env['PATH'])
    # A trap proves UI operations never fall back to an installed legacy helper.
    trap_bin=base/'bin';trap_bin.mkdir()
    retired=trap_bin/'aqueous-config'
    retired.write_text('#!/bin/sh\nprintf called > "'+str(base/'helper-called')+'"\nexit 99\n');retired.chmod(0o755)
    env['PATH']=str(trap_bin)+':'+env['PATH']
    test_theme = os.environ.get('AQUEOUS_SETTINGS_TEST_THEME')
    if test_theme:
        from PIL import Image
        theme_path=base/'cache/aqueous/settings-application/themes'/f'{test_theme}.json'
        theme_path.parent.mkdir(parents=True)
        palette=json.loads((ROOT/f'settingsApplication/tests/fixtures/themes/{test_theme}.json').read_text())
        palette['mode']=os.environ.get('AQUEOUS_SETTINGS_TEST_THEME_MODE','dark')
        theme_path.write_text(json.dumps(palette))
        (config/'settings-application.json').write_text(json.dumps(dict(theme_source=test_theme)))
        shell_settings=base/('config/DankMaterialShell/settings.json' if test_theme=='dms' else 'state/noctalia/settings.toml')
        shell_settings.parent.mkdir(parents=True,exist_ok=True)
        def set_font(pixels):
            shell_settings.write_text(json.dumps(dict(fontFamily='sans-serif',fontScale=pixels/14)) if test_theme=='dms' else f'[shell]\nfont_family = "sans-serif"\n[accessibility]\nui_scale = {pixels/16}\n')
        set_font(16)
        def export_theme(mode):
            palette['mode']=mode
            temporary=theme_path.with_suffix('.tmp');temporary.write_text(json.dumps(palette));temporary.replace(theme_path)
        def verify_color(mode):
            rgb=tuple(bytes.fromhex(palette[mode]['background'][1:]))
            deadline=time.monotonic()+6
            while time.monotonic()<deadline:
                screenshot=base/'theme.png'
                subprocess.run(['grim',str(screenshot)],env=env,check=True,timeout=5,stdout=subprocess.DEVNULL)
                with Image.open(screenshot) as frame:
                    colors=frame.convert('RGB').getcolors(frame.width*frame.height)
                    if sum(count for count,pixel in colors if max(abs(p-c) for p,c in zip(pixel,rgb))<=1)>1000: return
                time.sleep(.2)
            screenshot.replace(pathlib.Path('/tmp/aqueous-theme-failure.png'))
            raise AssertionError(('theme did not render',test_theme,mode,rgb,sorted(colors,reverse=True)[:12]))
    with (base/'compositor.log').open('w+') as log:
        compositor = subprocess.Popen([os.environ.get('AQUEOUS_COMPOSITOR_BIN',str(ROOT/'compositor/zig-out/bin/aqueous')),'-no-xwayland','-policy','internal'],env=env,stdout=log,stderr=log)
        try:
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                sockets=[p for p in runtime.glob('wayland-*') if p.is_socket()]
                if sockets: break
                if compositor.poll() is not None: log.seek(0); raise AssertionError(log.read())
                time.sleep(.05)
            assert sockets, 'headless compositor did not start'
            env['WAYLAND_DISPLAY']=sockets[0].name
            env['AQUEOUS_CONFIG']=str(config/'wm.toml')
            for page in os.environ.get('AQUEOUS_SETTINGS_TEST_PAGES','overview appearance layouts input displays rules keybinds advanced').split():
                child=subprocess.Popen([str(APP),'--shell','none','--page',page,'--smoke-test'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                try:
                    # Child announces completion of backend loading and layout.
                    selector=selectors.DefaultSelector();selector.register(child.stderr,selectors.EVENT_READ)
                    assert selector.select(20), (page,'timed out loading UI')
                    selector.close()
                    line=child.stderr.readline()
                    assert line.strip()=='AQUEOUS_SETTINGS_READY', (page,line,child.stderr.read())
                    if test_theme: verify_color(palette['mode'])
                    if os.environ.get('AQUEOUS_SETTINGS_ARTIFACTS'):
                        artifacts=pathlib.Path(os.environ['AQUEOUS_SETTINGS_ARTIFACTS']);artifacts.mkdir(parents=True,exist_ok=True)
                        windows=json.loads(subprocess.check_output([str(ROOT/'compositor/zig-out/bin/aqueousctl'),'windows','--json'],env=env,text=True,timeout=5))
                        window=next(w for w in windows if w.get('app_id')=='org.aqueous.Settings')
                        (artifacts/(page+'.json')).write_text(json.dumps(window,indent=2))
                        subprocess.run(['grim','-o',window['output'],str(artifacts/(page+'.png'))],env=env,check=True,timeout=10)
                    out,err=child.communicate(timeout=30)
                    assert child.returncode==0, (page,out,err)
                    assert 'dispatch failed' not in err and 'panic' not in err, (page,err)
                finally:
                    if child.poll() is None: child.kill();child.wait()
                print('Quark page passed:',page)
            if os.environ.get('AQUEOUS_SETTINGS_TEST_INPUT'):
                if test_theme: export_theme('dark')
                for name,source in [('keyboard','virtual-keyboard-unstable-v1.xml'),('pointer','wlr-virtual-pointer-unstable-v1.xml')]:
                    protocol=ROOT/'compositor/protocol/upstream'/source
                    for mode,suffix in [('client-header','client.h'),('private-code','protocol.c')]:
                        subprocess.run(['wayland-scanner',mode,str(protocol),str(base/f'virtual-{name}-{suffix}')],check=True)
                flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
                injector=base/'send-input'
                subprocess.run(['cc','-Wall','-Wextra','-Werror',str(ROOT/'settingsApplication/tests/send-input.c'),str(base/'virtual-keyboard-protocol.c'),str(base/'virtual-pointer-protocol.c'),'-I'+str(base),'-o',str(injector),*flags],check=True)
                before=(config/'wm.toml').read_bytes()
                with (base/'interaction.log').open('w+') as error_log:
                    child=subprocess.Popen([str(APP),'--shell','none','--page','advanced'],env=env,stderr=error_log)
                    try:
                        time.sleep(2)
                        def send(*keys):
                            subprocess.run([str(injector),*map(str,keys)],env=env,check=True,timeout=15)
                            time.sleep(.4)
                            assert child.poll() is None, 'application exited during input'
                        # Append a valid TOML comment using actual pointer and keyboard events.
                        send('click',400,250,'C107',28,'S4',20,18,31,20,28)
                        marker=b'#test'
                        if test_theme:
                            verify_color('dark')
                            # Select 'test' forwards with Shift+End; preserve selection and focus across updates.
                            send(105,105,105,105,105,'S107')
                            export_theme('light');set_font(18)
                            verify_color('light')
                            time.sleep(.7)
                            send(38,23,47,18) # live replaces test; the existing newline stays.
                            marker=b'#live'
                            assert (config/'wm.toml').read_bytes()==before, 'theme wrote canonical configuration'
                            theme_path.write_text('{') # partial export retains the valid palette.
                            time.sleep(.7);verify_color('light')
                            export_theme('dark');set_font(16)
                            verify_color('dark');time.sleep(.7)
                        send('click',1120,640) # Validate must retain draft and leave disk unchanged.
                        assert (config/'wm.toml').read_bytes()==before, 'Validate wrote configuration'
                        # Navigate away and reopen through the single-instance endpoint.
                        send('click',100,90)
                        subprocess.run([str(APP),'--shell','none','--page','advanced'],env=env,check=True,timeout=5)
                        time.sleep(.5)
                        windows=json.loads(subprocess.check_output([str(ROOT/'compositor/zig-out/bin/aqueousctl'),'windows','--json'],env=env,text=True,timeout=5))
                        assert sum(w.get('app_id')=='org.aqueous.Settings' for w in windows)==1, 'duplicate instance'
                        send('click',1220,640) # Apply surviving raw draft.
                        deadline=time.monotonic()+5
                        while marker not in (config/'wm.toml').read_bytes() and time.monotonic()<deadline: time.sleep(.1)
                        saved=(config/'wm.toml').read_bytes()
                        if marker not in saved: subprocess.run(['grim','/tmp/aqueous-theme-apply-failure.png'],env=env,check=True)
                        assert marker in saved and saved.rstrip().endswith(marker), ('UI Apply did not persist typed draft',saved[-100:])
                        assert before.rstrip() in saved, 'unrelated TOML changed'
                        deadline=time.monotonic()+6
                        while 'configuration reloaded layout=' not in (base/'compositor.log').read_text() and time.monotonic()<deadline: time.sleep(.1)
                        assert 'configuration reloaded layout=' in (base/'compositor.log').read_text(), 'Apply saved without explicitly reloading the compositor'
                        # Choose a different raw file through the real dropdown.
                        layout_before=(config/'layout.toml').read_bytes()
                        send('click',400,123,'click',400,195)
                        send('click',400,250,'C107',28,'S4',20,18,31,20,28)
                        send('click',1220,640)
                        deadline=time.monotonic()+5
                        while b'#test' not in (config/'layout.toml').read_bytes() and time.monotonic()<deadline: time.sleep(.1)
                        assert b'#test' in (config/'layout.toml').read_bytes(), 'dropdown did not select layout file'
                        assert layout_before.rstrip() in (config/'layout.toml').read_bytes()
                        # Unsaved close is intercepted and leaves saved configuration intact.
                        send('click',400,250,'C107',28,'S4',20)
                        subprocess.run([str(ROOT/'compositor/zig-out/bin/aqueousctl'),'window','close','--id',next(w['id'] for w in windows if w.get('app_id')=='org.aqueous.Settings'),'--json'],env=env,check=True,timeout=5,stdout=subprocess.DEVNULL)
                        time.sleep(.5)
                        assert child.poll() is None, 'dirty close discarded the draft'
                        assert (config/'wm.toml').read_bytes()==saved, 'close wrote configuration'
                        print('Quark interaction passed: raw editing, Validate, navigation, single instance, dropdown selection, Apply, dirty close')
                    finally:
                        child.terminate()
                        try: child.wait(timeout=5)
                        except subprocess.TimeoutExpired: child.kill();child.wait()
                        error_log.seek(0);errors=error_log.read()
                        assert 'panic' not in errors and 'dispatch failed' not in errors,errors
            assert not (base/'helper-called').exists(), 'application invoked the retired helper'
        finally:
            compositor.terminate()
            try: compositor.wait(timeout=5)
            except subprocess.TimeoutExpired: compositor.kill();compositor.wait()
