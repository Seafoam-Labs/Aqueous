import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Item {
    id: root
    readonly property bool choosing: picker.visible
    function choose(index) {
        if (!picker.visible || index < 0 || index >= sourceModel.choices.length)
            return;
        transport.finish(index);
        picker.visible = false;
    }
    function cancel() {
        transport.finish(null);
        picker.visible = false;
    }
    PortalModel { id: sourceModel }
    PortalTransport {
        id: transport
        onRequestReceived: request => {
            if (!sourceModel.load(request)) {
                console.warn("aqueousPortal: rejected invalid choice list");
                transport.finish(null);
                return;
            }
            const screen = Quickshell.screens[0];
            if (!screen) {
                transport.finish(null);
                return;
            }
            picker.screen = screen;
            picker.implicitWidth = Math.min(640, screen.width - 32);
            picker.implicitHeight = Math.min(520, screen.height - 48);
            picker.visible = true;
            Qt.callLater(content.focusSearch);
        }
        onEnded: {
            picker.visible = false;
            sourceModel.clear();
        }
    }
    IpcHandler {
        target: "aqueousPortal"
        function open(token: string): string { return transport.open(token); }
    }
    FloatingWindow {
        id: picker
        visible: false
        title: "Share a monitor or window"
        color: Theme.surface
        onVisibleChanged: {
            if (!visible && transport.busy && !transport.replied)
                transport.finish(null);
        }
        PortalPicker {
            id: content
            anchors.fill: parent
            selection: sourceModel
            onSelected: index => {
                root.choose(index);
            }
            onCancelled: {
                root.cancel();
            }
        }
    }
}
