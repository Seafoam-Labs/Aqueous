#!/usr/bin/env bash
# Optional real DMS QML + headless Aqueous integration test.
set -euo pipefail
unset LD_PRELOAD
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_root=${DMS_SOURCE:?Set DMS_SOURCE to a DMS 1.6.0 checkout with dank-qml-common initialized}
compositor=${AQUEOUS_COMPOSITOR_BIN:-"$root/../compositor/zig-out/bin/aqueous"}
work=$(mktemp -d /tmp/aqueous-dms-host.XXXXXX)
compositor_pid=''
shell_pid=''
cleanup() {
    [[ -z "$shell_pid" ]] || kill "$shell_pid" 2>/dev/null || true
    [[ -z "$compositor_pid" ]] || kill "$compositor_pid" 2>/dev/null || true
    [[ -z "$shell_pid" ]] || wait "$shell_pid" 2>/dev/null || true
    [[ -z "$compositor_pid" ]] || wait "$compositor_pid" 2>/dev/null || true
    if [[ ${KEEP_DMS_TEST:-0} == 1 ]]; then printf 'Host test artifacts: %s\n' "$work"; else rm -rf "$work"; fi
}
trap cleanup EXIT
mkdir -p "$work/runtime" "$work/config/aqueous" "$work/home" "$work/cache" "$work/state"
chmod 700 "$work/runtime"
cp -a "$source_root/quickshell" "$work/quickshell"
cp -a "$source_root/dank-qml-common" "$work/dank-qml-common"
cp "$root/../plugin/tests/fixtures/"*.toml "$work/config/aqueous/"
cat > "$work/compositor.toml" <<'TOML'
[layout]
default = "tile"
gaps_outer = 0
gaps_inner = 0
[workspace_transition]
enabled = false
TOML
export XDG_RUNTIME_DIR="$work/runtime" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" XDG_CACHE_HOME="$work/cache"
export HOME="$work/home" DBUS_SESSION_BUS_ADDRESS="unix:path=$work/no-session-bus" DMS_DISABLE_MATUGEN=1
export PATH="$root/../plugin/helper/zig-out/bin:$PATH"
unset DISPLAY WAYLAND_DISPLAY QT_QPA_PLATFORM
WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=2 WLR_RENDERER=pixman AQUEOUS_CONFIG="$work/compositor.toml" \
    AQUEOUS_LAYOUT="$work/missing-layout.toml" AQUEOUS_INPUT="$work/missing-input.toml" AQUEOUS_OUTPUTS="$work/missing-outputs.toml" AQUEOUS_RULES="$work/missing-rules.toml" \
    "$compositor" -no-xwayland -policy internal -log-level error -c true > "$work/compositor.log" 2>&1 &
compositor_pid=$!
for ((i=0;i<100;i++)); do
    socket=$(find "$work/runtime" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -1)
    [[ -z "$socket" ]] || break
    if ! kill -0 "$compositor_pid" 2>/dev/null; then cat "$work/compositor.log" >&2; exit 1; fi
    sleep 0.05
done
: "${socket:?Headless compositor did not start}"
export WAYLAND_DISPLAY="$socket" QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software
export AQUEOUS_CONFIG="$work/config/aqueous/wm.toml" AQUEOUS_LAYOUT="$work/config/aqueous/layout.toml" AQUEOUS_INPUT="$work/config/aqueous/input.toml" AQUEOUS_OUTPUTS="$work/config/aqueous/outputs.toml" AQUEOUS_RULES="$work/config/aqueous/rules.toml"
python3 - "$root" "$work/quickshell/AqueousTest.qml" <<'PY'
import pathlib,sys
plugin=pathlib.Path(sys.argv[1]).as_uri()
pathlib.Path(sys.argv[2]).write_text('''import QtQuick
import Quickshell
import Quickshell.Wayland
import "'''+plugin+'''"
import "'''+plugin+'''/pages" as Pages
ShellRoot {
    id: test
    property int step: 0
    property string edge: 'top'
    AqueousDaemon { id: daemon }
    Pages.DisplaysPage { id: displayEditor; controller: daemon; width: 800; height: 600 }
    QtObject {
        id: service
        property var pluginDaemonInstances: ({aqueousSettings:daemon})
        signal pluginDataChanged(string changedPluginId)
        function getPluginVariants(id) { return []; }
    }
    PanelWindow {
        id: bar
        screen: Quickshell.screens[0]
        anchors.top: test.edge !== 'bottom'
        anchors.bottom: test.edge !== 'top'
        anchors.left: test.edge !== 'right'
        anchors.right: test.edge !== 'left'
        implicitHeight: 48
        implicitWidth: 48
        color: '#222222'
        WlrLayershell.layer: WlrLayer.Top
        AqueousWidget {
            id: widget
            pluginId: 'aqueousSettings'
            pluginService: service
            parentScreen: bar.screen
            axis: ({edge:test.edge,isVertical:test.edge === 'left' || test.edge === 'right'})
        }
    }
    Timer {
        interval: 550; running: true; repeat: true
        onTriggered: {
            if (test.step < 8) {
                if (test.step === 0) daemon.show('');
                daemon.page = ['overview','appearance','layouts','input','displays','rules','keybinds','advanced'][test.step];
                console.log('AQUEOUS_PAGE',daemon.page);
            } else if (test.step < 12) {
                widget.closePopout();
                test.edge = ['top','bottom','left','right'][test.step-8];
                Qt.callLater(() => widget.triggerPopout());
            } else if (test.step === 12) {
                displayEditor.stageMode('1920x1080','59.94');
                displayEditor.stage(displayEditor.monitor,-200,40,'90');
                daemon.model.change('layout.gaps_inner',13);
                daemon.model.change('desktop.font.size_pt',13);
                daemon.submit('validate');
            } else if (test.step === 13) {
                if (daemon.client.busy) return;
                if (daemon.model.count !== 3 || daemon.errorCode) console.error('AQUEOUS_HOST_FAIL validate',daemon.status);
                daemon.submit('apply');
            } else if (test.step === 14) {
                if (daemon.client.busy) return;
                if (daemon.model.count !== 0 || daemon.model.value('layout.gaps_inner') !== 13 || daemon.errorCode) console.error('AQUEOUS_HOST_FAIL apply',daemon.status);
                if (!daemon.model.snapshot.monitors.some(m => m.mode === '1920x1080@59.94' && m.x === -200 && m.transform === '90')) console.error('AQUEOUS_HOST_FAIL monitor mode');
                if (!Array.isArray(daemon.model.snapshot.live_outputs)) console.error('AQUEOUS_HOST_FAIL mode discovery');
                if (daemon.appearance.state !== 'partial') console.error('AQUEOUS_HOST_FAIL appearance',daemon.appearance.message);
            } else {
                if (daemon.model.snapshot.fields.length < 200) console.error('AQUEOUS_HOST_FAIL snapshot');
                else console.log('AQUEOUS_HOST_PASS');
                Qt.quit();
            }
            test.step++;
        }
    }
}
''')
PY
quickshell -p "$work/quickshell/AqueousTest.qml" > "$work/shell.log" 2>&1 &
shell_pid=$!
for ((i=0;i<60;i++)); do
    if quickshell ipc -p "$work/quickshell/AqueousTest.qml" call aqueousSettings open > "$work/ipc.log" 2>&1; then break; fi
    kill -0 "$shell_pid" 2>/dev/null || { cat "$work/shell.log" >&2; exit 1; }
    sleep 0.1
done
rg -q opened "$work/ipc.log"
if command -v grim >/dev/null; then sleep 2; grim "$work/screenshot.png" 2>/dev/null || true; fi
wait "$shell_pid"
shell_pid=''
if ! rg -q 'AQUEOUS_HOST_PASS' "$work/shell.log" || rg -q 'AQUEOUS_HOST_FAIL|TypeError|ReferenceError|Failed to load|Required property|is not a type|Cannot assign|Unable to assign' "$work/shell.log"; then
    cat "$work/shell.log" >&2
    exit 1
fi
printf '%s\n' 'DMS host checks passed: eight pages, four bar edges, real helper Validate/Apply, DMS typography, IPC open.'
