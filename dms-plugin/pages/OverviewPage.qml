import QtQuick
import "../controls" as Aq
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common

ColumnLayout {
    id: root
    property var controller
    property string liveStatus: ''
    property var layouts: ['tile', 'monocle', 'grid', 'rows', 'dwindle', 'reverse-dwindle', 'scrolling', 'stacking', 'game-mode', 'composable']
    spacing: 12
    Label {
        text: I18n.trFor('aqueousSettings', 'Aqueous Settings')
        font.bold: true
        font.pixelSize: Theme.fontSizeLarge
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Edits stay in memory until Apply. Aqueous hot-reloads saved settings.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Repeater {
        model: Object.keys(root.controller?.model.snapshot.files || {})
        Label {
            required property string modelData
            Layout.fillWidth: true
            wrapMode: Text.WrapAnywhere
            text: modelData + ': ' + root.controller.model.snapshot.files[modelData].path
        }
    }
    Repeater {
        model: root.controller?.model.snapshot.warnings || []
        Label {
            required property string modelData
            text: modelData
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Theme.error
        }
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Current workspace layout · applies immediately')
        font.bold: true
    }
    RowLayout {
        Aq.ComboBox {
            id: outputs
            model: Quickshell.screens.map(s => s.name)
            currentIndex: model.indexOf(root.controller?.outputName || '')
            onActivated: {
                root.controller.outputName = currentText;
                root.query();
            }
        }
        Aq.ComboBox {
            id: layout
            model: root.layouts
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Switch now')
            enabled: !!root.controller?.outputName && !live.running
            onClicked: {
                live.command = ['aqueousctl', 'layout', '--output', root.controller.outputName, '--set', layout.currentText, '--json'];
                live.running = true;
            }
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Refresh')
            enabled: !!root.controller?.outputName && !live.running
            onClicked: root.query()
        }
    }
    Label {
        text: root.liveStatus
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    function query() {
        if (controller?.outputName && !live.running) {
            live.command = ['aqueousctl', 'layout', '--output', controller.outputName, '--json'];
            live.running = true;
        }
    }
    onControllerChanged: if (controller)
        Qt.callLater(query)
    Process {
        id: live
        stdout: StdioCollector {
            id: result
        }
        stderr: StdioCollector {
            id: error
        }
        onExited: code => {
            try {
                const r = JSON.parse(result.text);
                if (code !== 0)
                    throw new Error(r.message || error.text);
                layout.currentIndex = root.layouts.indexOf(['float', 'floating', 'stack'].includes(r.layout) ? 'stacking' : r.layout);
                root.liveStatus = 'Workspace ' + r.workspace + ': ' + r.layout;
            } catch (e) {
                root.liveStatus = 'Live layout unavailable: ' + e;
            }
        }
    }
}
