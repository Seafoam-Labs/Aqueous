#!/usr/bin/env python3
"""Exercise the bridge in real Quickshell with an isolated SettingsData service."""
import json,os,pathlib,shutil,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='aqueous-settings-dms-') as tmp:
    root=pathlib.Path(tmp);common=root/'Common';common.mkdir();runtime=root/'runtime';runtime.mkdir(mode=0o700)
    (common/'qmldir').write_text('module qs.Common\nsingleton SettingsData 1.0 SettingsData.qml\n')
    (common/'SettingsData.qml').write_text('''pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
Singleton {
    id: root
    property bool _hasLoaded: true
    property bool _parseError: false
    property bool _isReadOnly: false
    property string fontFamily: "Before"
    property int fontWeight: 400
    property real fontScale: 1
    property alias settingsFile: file
    FileView { id: file; path: Qt.resolvedUrl("../settings.json").toString().replace("file://", ""); blockWrites: true; atomicWrites: true }
    function set(key,value) { root[key]=value;file.setText(JSON.stringify({fontFamily:root.fontFamily,fontWeight:root.fontWeight,fontScale:root.fontScale})); }
}
''')
    (root/'settings.json').write_text('{"fontFamily":"Before","fontWeight":400,"fontScale":1}')
    shutil.copy(ROOT/'packaging/dms-appearance/Daemon.qml',root/'Daemon.qml')
    (root/'shell.qml').write_text('import Quickshell\nShellRoot { Daemon {} }\n')
    env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',DBUS_SESSION_BUS_ADDRESS='unix:path='+str(root/'no-bus'),XDG_RUNTIME_DIR=str(runtime),XDG_CONFIG_HOME=str(root/'config'),XDG_CACHE_HOME=str(root/'cache'))
    env.pop('LD_PRELOAD',None)
    env.pop('DISPLAY',None)
    env.pop('WAYLAND_DISPLAY',None)
    with (root/'log').open('w+') as log:
        child=subprocess.Popen(['quickshell','-p',str(root)],env=env,stdout=log,stderr=log)
        try:
            def ipc(method,*args):
                p=subprocess.run(['quickshell','ipc','-p',str(root),'call','aqueousSettingsAppearance',method,*args],env=env,capture_output=True,text=True,timeout=3)
                if p.returncode: return None
                return json.loads(p.stdout)
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                if child.poll() is not None:log.seek(0);raise AssertionError(log.read())
                if ipc('status'):break
                time.sleep(.05)
            else:log.seek(0);raise AssertionError(log.read())
            assert not ipc('apply','{"family":"Bad","weight":400,"size_pt":99}')['ok']
            assert ipc('apply','{"family":"Test Sans","weight":600,"size_pt":12}')['ok']
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                result=ipc('status')
                if result['state']=='saved':break
                assert result['state']!='failed',result
                time.sleep(.05)
            else:raise AssertionError(result)
            saved=json.loads((root/'settings.json').read_text())
            assert saved['fontFamily']=='Test Sans' and saved['fontWeight']==600
            assert abs(saved['fontScale']-12*96/72/14)<.001
            print('DMS bridge: validation and durable typography save passed.')
        finally:
            child.terminate()
            try:child.wait(timeout=5)
            except subprocess.TimeoutExpired:child.kill();child.wait()
