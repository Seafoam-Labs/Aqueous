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
    test_scale=os.environ.get('AQUEOUS_SETTINGS_TEST_SCALE')
    test_output=os.environ.get('AQUEOUS_SETTINGS_TEST_OUTPUT')
    if test_scale or test_output:
        scale=float(test_scale or 1)
        resolution=test_output or f'{round(1280*scale)}x{round(720*scale)}'
        with (config/'wm.toml').open('a') as wm:
            wm.write(f'\n[[output]]\nname = "HEADLESS-1"\nmode = "{resolution}"\nscale = {scale}\n')
    test_size=os.environ.get('AQUEOUS_SETTINGS_TEST_SIZE')
    if test_size:
        width,height=map(int,test_size.split('x'))
        with (config/'rules.toml').open('a') as rules:
            rules.write(f'\n[[window]]\napp_id = "org.aqueous.Settings"\nlayout = "float"\nwidth = {width}\nheight = {height}\nplacement_policy = "center"\n')
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
        set_font(float(os.environ.get("AQUEOUS_SETTINGS_TEST_FONT",16)))
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
            if test_scale:
                outputs=json.loads(subprocess.check_output([os.environ.get('AQUEOUSCTL_BIN',str(ROOT/'compositor/zig-out/bin/aqueousctl')),'outputs','--json'],env=env,text=True,timeout=5))
                assert next(o['scale'] for o in outputs if o['name']=='HEADLESS-1')==scale, outputs
            env['AQUEOUS_SETTINGS_TEST_INSPECT']=str(base/'ui.json')
            driver=ROOT/'settingsApplication/zig-out/bin/aqueous-backend-test'
            snapshot=json.loads(subprocess.check_output([str(driver),'snapshot','--shell','none'],env=env,text=True,timeout=20))
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
                    inspection=json.loads((base/'ui.json').read_text())
                    assert inspection['page']==page, inspection
                    assert len({c['id'] for c in inspection['controls']})==len(inspection['controls']), ('duplicate control identity',page)
                    if test_size: assert (inspection['width'],inspection['height'])==(width,height), ('incorrect test dimensions',inspection['width'],inspection['height'])
                    expected={f['id'] for f in snapshot['fields'] if f['category']==page}
                    represented={c['key'] for c in inspection['controls'] if c['action']=='field'}
                    if page=='appearance':
                        assert any(c['action']=='font_family' for c in inspection['controls'])
                        assert any(c['action']=='font_face' for c in inspection['controls'])
                        cursor=next(c for c in inspection['controls'] if c['action']=='field' and c['key']=='desktop.cursor.theme')
                        assert cursor['selected']==snapshot['desktop_cursor']['theme'], ('cursor theme must be a populated dropdown',cursor)
                        represented.update(('desktop.font.family','desktop.font.style'))
                    assert expected==represented, ('field inventory mismatch',page,expected-represented,represented-expected)
                    assert all(c['x']+c['width'] <= inspection['width']+1 for c in inspection['controls']), ('horizontal overflow',page,[c for c in inspection['controls'] if c['x']+c['width']>inspection['width']+1])
                    if os.environ.get('AQUEOUS_SETTINGS_ARTIFACTS'):
                        dest=pathlib.Path(os.environ['AQUEOUS_SETTINGS_ARTIFACTS']);dest.mkdir(parents=True,exist_ok=True)
                        (dest/(page+'-controls.json')).write_text(json.dumps(inspection,indent=2))
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
            if os.environ.get('AQUEOUS_SETTINGS_TEST_INPUT') or os.environ.get('AQUEOUS_SETTINGS_TEST_SHORTCUTS'):
                if test_theme: export_theme('dark')
                for name,source in [('keyboard','virtual-keyboard-unstable-v1.xml'),('pointer','wlr-virtual-pointer-unstable-v1.xml')]:
                    protocol=ROOT/'compositor/protocol/upstream'/source
                    for mode,suffix in [('client-header','client.h'),('private-code','protocol.c')]:
                        subprocess.run(['wayland-scanner',mode,str(protocol),str(base/f'virtual-{name}-{suffix}')],check=True)
                flags=subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client','xkbcommon'],text=True).split()
                injector=base/'send-input'
                subprocess.run(['cc','-Wall','-Wextra','-Werror',str(ROOT/'settingsApplication/tests/send-input.c'),str(base/'virtual-keyboard-protocol.c'),str(base/'virtual-pointer-protocol.c'),'-I'+str(base),'-o',str(injector),*flags],check=True)
                def capture(name):
                    if os.environ.get('AQUEOUS_SETTINGS_ARTIFACTS'):
                        target=pathlib.Path(os.environ['AQUEOUS_SETTINGS_ARTIFACTS']);target.mkdir(parents=True,exist_ok=True)
                        subprocess.run(['grim',str(target/(name+'.png'))],env=env,check=True,timeout=10)
                def ui():
                    return json.loads((base/'ui.json').read_text())
                def window_geometry():
                    windows=json.loads(subprocess.check_output([env['PATH'].split(':')[1]+'/aqueousctl','windows','--json'],env=env,text=True,timeout=5))
                    return next(w['geometry'] for w in windows if w.get('app_id')=='org.aqueous.Settings')
                def inject(*keys):
                    subprocess.run([str(injector),*map(str,keys)],env=env,check=True,timeout=20)
                    time.sleep(.35)
                def control(action,key=None,index=None):
                    for c in ui()['controls']:
                        if c['action']==action and (key is None or c['key']==key) and (index is None or c['index']==index): return c
                    raise AssertionError(('control missing',action,key,index,ui()))
                def click_control(action,key=None,index=None):
                    for _ in range(60):
                        c=control(action,key,index); state=ui();v=state['viewport'];g=window_geometry()
                        if c['x']>=v['x'] and not action.startswith('shortcut_') and action not in ('apply','validate','reload','close','shell','color_accept','color_cancel','color_channel'):
                            lo=max(c['y'],v['y']); hi=min(c['y']+c['height'],v['y']+v['height'])
                            if hi-lo<min(c['height'],24):
                                inject('wheel',round(g['x']+v['x']+v['width']/2),round(g['y']+v['y']+v['height']/2),100 if c['y']>=v['y'] else -100)
                                continue
                            y=(lo+hi)/2
                        else: y=c['y']+c['height']/2
                        inject('click',round(g['x']+c['x']+c['width']/2),round(g['y']+y))
                        return
                    raise AssertionError(('could not reveal control',c,ui()))
                def focus_control(action,key=None,index=None):
                    target=control(action,key,index)['id']
                    for _ in range(300):
                        if ui()['focus']==target: return
                        inject(15)
                    raise AssertionError(('could not focus',action,key))
                from shortcut_interaction import run as test_shortcuts
                test_shortcuts(APP, env, base, config, ui, control, click_control, inject, capture)
                if os.environ.get('AQUEOUS_SETTINGS_TEST_SHORTCUTS'):
                    assert not (base/'helper-called').exists(), 'application invoked the retired helper'
                    raise SystemExit(0)
                from rule_interaction import run as test_rule_editor
                test_rule_editor(APP, env, base, config, ui, control, click_control, focus_control, inject, capture)
                # Runtime layouts must come from the compositor, not the saved tile default.
                ctl=pathlib.Path(os.environ.get('AQUEOUSCTL_BIN',str(ROOT/'compositor/zig-out/bin/aqueousctl'))).resolve()
                output=next(o['name'] for o in json.loads(subprocess.check_output([str(ctl),'outputs','--json'],env=env,text=True)) if o.get('enabled'))
                calls=base/'layout-switches.jsonl'
                wrapper=trap_bin/'aqueousctl'
                wrapper.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                    'if sys.argv[1:2]==["layout"] and "--set" in sys.argv:\n'
                    f'    with open({str(calls)!r},"a") as log: log.write(json.dumps(sys.argv[1:])+"\\n")\n'
                    f'os.execv({str(ctl)!r},[{str(ctl)!r},*sys.argv[1:]])\n')
                wrapper.chmod(0o755)
                canonical={p:p.read_bytes() for p in config.glob('*.toml')}
                subprocess.run([str(ctl),'layout','--output',output,'--set','scrolling','--json'],env=env,check=True,stdout=subprocess.DEVNULL)
                with (base/'layout-test.log').open('w+') as layout_log:
                    layout_child=subprocess.Popen([str(APP),'--shell','none','--page','overview'],env=env,stderr=layout_log)
                    try:
                        for iteration,expected in enumerate(('scrolling','grid')):
                            if iteration: subprocess.run([str(ctl),'layout','--output',output,'--set',expected,'--json'],env=env,check=True,stdout=subprocess.DEVNULL)
                            time.sleep(2.5)
                            assert layout_child.poll() is None, 'layout UI exited'
                            assert control('runtime_layout')['selected']==expected, control('runtime_layout')
                            click_control('runtime_apply')
                            deadline=time.monotonic()+5
                            while (not calls.exists() or len(calls.read_text().splitlines())<=iteration) and time.monotonic()<deadline: time.sleep(.1)
                            observed=[json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
                            assert len(observed)==iteration+1, ('Switch layout now was not invoked',observed)
                            assert observed[-1][4]==expected, ('dropdown did not follow current workspace',expected,observed[-1])
                        assert all(p.read_bytes()==data for p,data in canonical.items()), 'live layout changed saved TOML'
                        print('Runtime layout passed: non-tile initialization and external layout refresh without configuration writes')
                    finally:
                        layout_child.terminate()
                        try: layout_child.wait(timeout=5)
                        except subprocess.TimeoutExpired: layout_child.kill();layout_child.wait()
                        layout_log.seek(0);errors=layout_log.read()
                        assert 'panic' not in errors and 'dispatch failed' not in errors,errors
                with (base/'redesign.log').open('w+') as redesign_log:
                    redesigned=subprocess.Popen([str(APP),'--shell','none','--page','advanced'],env=env,stderr=redesign_log)
                    try:
                        time.sleep(2)
                        # A raw draft survives search and returning to its page.
                        click_control('raw','wm');inject('C107',28,'S4',20)
                        inject('C33',20,19,30,49,31,25,30,19,18,49,46,21) # transparency
                        deadline=time.monotonic()+10
                        while control('search')['text']!='transparency' and time.monotonic()<deadline: time.sleep(.1)
                        assert control('search')['text']=='transparency', (control('search'),(base/'redesign.log').read_text())
                        capture('search-results')
                        click_control('search_open','opacity.value')
                        capture('opacity-card')
                        assert ui()['page']=='appearance'
                        assert control('field','opacity.value')['text']=='90', control('field','opacity.value')
                        assert ui()['pending']>=1
                        click_control('field','opacity.value');inject('C30',45) # invalid x
                        click_control('page',index=0)
                        inject('C33',24,25,30,46,23,20,21) # opacity
                        click_control('search_open','opacity.value')
                        assert control('field','opacity.value')['text']=='x', control('field','opacity.value')
                        click_control('number_step','opacity.value',1)
                        assert abs(float(control('field','opacity.value')['text'])-91)<.00001
                        click_control('number_slide','opacity.value')
                        assert 40<float(control('field','opacity.value')['text'])<60, control('field','opacity.value')
                        click_control('field','opacity.value')
                        focus_control('number_slide','opacity.value')
                        previous_value=float(control('field','opacity.value')['text'])
                        inject(106)
                        assert float(control('field','opacity.value')['text'])>previous_value, 'keyboard slider did not change'
                        previous=control('field','opacity.enabled')['checked']
                        click_control('field','opacity.enabled')
                        assert control('field','opacity.enabled')['checked']!=previous
                        # Search also puts keyboard focus on a non-text control.
                        inject('C33',20,19,30,49,31,25,30,19,18,49,46,21)
                        click_control('search_open','opacity.enabled')
                        previous=control('field','opacity.enabled')['checked']
                        inject(57)
                        assert control('field','opacity.enabled')['checked']!=previous, 'Space did not toggle the focused switch'
                        click_control('section_toggle','opacity')
                        assert not any(c['action']=='field' and c['key']=='opacity.value' for c in ui()['controls'])
                        click_control('section_toggle','opacity')
                        click_control('page',index=7)
                        assert '#t' in control('raw','wm')['text'], 'search lost raw draft'
                        # Exact ARGB editing is local until the picker is accepted.
                        click_control('page',index=2)
                        color=next(c['key'] for c in ui()['controls'] if c['action']=='color_open')
                        pending=ui()['pending']
                        click_control('color_open',color)
                        assert ui()['viewport']['height']>100, 'dialog consumed the page viewport'
                        assert control('color_channel','',0)['width']>100, 'color slider lost its width'
                        click_control('color_channel','hex');inject('C30',11,45,9,11,5,5,9,9,46,46) # 0x804488cc
                        capture('color-picker')
                        click_control('color_cancel')
                        assert ui()['pending']==pending, 'color cancel staged a change'
                        click_control('color_open',color)
                        click_control('color_channel','hex');inject('C30',11,45,9,11,5,5,9,9,46,46)
                        assert control('color_channel','hex')['text'].lower()=='0x804488cc', control('color_channel','hex')
                        click_control('color_accept')
                        assert not any(c['action']=='color_accept' for c in ui()['controls']), ('color dialog did not accept',ui())
                        click_control('field',color)
                        assert control('field',color)['text'].lower()=='0x804488cc', control('field',color)
                        click_control('reset',color)
                        assert all(p.read_bytes()==data for p,data in canonical.items()), 'new controls bypassed Apply'
                        print('Redesign interactions passed: global search, invalid draft retention, percentages, slider, toggle, section expansion, ARGB cancel/accept/reset')
                    finally:
                        redesigned.terminate()
                        try: redesigned.wait(timeout=5)
                        except subprocess.TimeoutExpired: redesigned.kill();redesigned.wait()
                        redesign_log.seek(0);errors=redesign_log.read()
                        assert 'panic' not in errors and 'dispatch failed' not in errors,errors
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
                        click_control('raw','wm');send('C107',28,'S4',20,18,31,20,28)
                        marker=b'#test'
                        if test_theme:
                            verify_color('dark')
                            # Select 'test' forwards with Shift+End; preserve selection and focus across updates.
                            send(105,105,105,105,105,'S107')
                            export_theme('light');set_font(32)
                            verify_color('light')
                            time.sleep(.7)
                            send(38,23,47,18) # live replaces test; the existing newline stays.
                            marker=b'#live'
                            assert (config/'wm.toml').read_bytes()==before, 'theme wrote canonical configuration'
                            theme_path.write_text('{') # partial export retains the valid palette.
                            time.sleep(.7);verify_color('light')
                            export_theme('dark');set_font(16)
                            verify_color('dark');time.sleep(.7)
                        click_control('validate') # Validate retains the draft.
                        assert (config/'wm.toml').read_bytes()==before, 'Validate wrote configuration'
                        # Navigate away and reopen through the single-instance endpoint.
                        click_control('page',index=0)
                        send('C33',20,19,30,49,31,25,30,19,18,49,46,21)
                        subprocess.run([str(APP),'--shell','none','--page','advanced'],env=env,check=True,timeout=5)
                        time.sleep(.5)
                        assert ui()['page']=='advanced' and control('raw','wm'), 'single-instance navigation left search open'
                        windows=json.loads(subprocess.check_output([str(ROOT/'compositor/zig-out/bin/aqueousctl'),'windows','--json'],env=env,text=True,timeout=5))
                        assert sum(w.get('app_id')=='org.aqueous.Settings' for w in windows)==1, 'duplicate instance'
                        click_control('apply') # Apply surviving raw draft.
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
                        focus_control('select_file');send(108)
                        assert control('select_file')['selected']=='layout', control('select_file')
                        click_control('raw','layout');send('C107',28,'S4',20,18,31,20,28)
                        click_control('apply')
                        deadline=time.monotonic()+5
                        while b'#test' not in (config/'layout.toml').read_bytes() and time.monotonic()<deadline: time.sleep(.1)
                        assert b'#test' in (config/'layout.toml').read_bytes(), 'dropdown did not select layout file'
                        assert layout_before.rstrip() in (config/'layout.toml').read_bytes()
                        # Unsaved close is intercepted and leaves saved configuration intact.
                        click_control('raw','layout');send('C107',28,'S4',20)
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
