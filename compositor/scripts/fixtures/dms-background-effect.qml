import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Widgets

ShellRoot {
    PanelWindow {
        id: panel
        visible: true
        anchors { top: true; left: true }
        implicitWidth: 320
        implicitHeight: 240
        exclusiveZone: -1
        color: "transparent"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "aqueous.blur.qml"
        WindowBlur {
            id: effect
            targetWindow: panel
            blurEnabled: false
            blurX: 20
            blurY: 20
            blurWidth: 240
            blurHeight: 160
            blurRadius: 20
            clipX: 100
            clipY: 20
            clipWidth: 160
            clipHeight: 160
        }
    }
    IpcHandler {
        target: "nativeBlurTest"
        function enabled(value: bool): void { effect.blurEnabled = value; }
        function preference(value: bool): void { SettingsData.set("blurEnabled", value); }
        function clipped(value: bool): void { effect.clipEnabled = value; }
        function shown(value: bool): void { panel.visible = value; }
        function status(): string {
            return JSON.stringify({supported: BlurService.compositorSupported,
                                   enabled: BlurService.enabled,
                                   loaded: SettingsData._hasLoaded});
        }
    }
}
