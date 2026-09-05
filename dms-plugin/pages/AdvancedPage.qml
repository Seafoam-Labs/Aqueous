import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    property var controller
    property string file: 'wm'
    spacing: 10
    Label {
        text: I18n.trFor('aqueousSettings', 'Raw and typed edits to the same file must be resolved before Apply.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Aq.ComboBox {
        model: ['wm', 'layout', 'input', 'outputs', 'rules', 'appearance']
        onActivated: root.file = currentText
    }
    Label {
        text: root.controller?.model.snapshot.files[root.file]?.path || ''
        wrapMode: Text.WrapAnywhere
        Layout.fillWidth: true
    }
    TextArea {
        Layout.fillWidth: true
        Layout.minimumHeight: 350
        text: root.controller ? root.controller.model.draft.raw_files[root.file] ?? root.controller.model.snapshot.raw_files[root.file] ?? '' : ''
        font.family: 'monospace'
        selectByMouse: true
        wrapMode: TextEdit.Wrap
        onTextChanged: if (activeFocus && root.controller)
            root.controller.model.raw(root.file, text)
    }
    Aq.Button {
        text: I18n.trFor('aqueousSettings', 'Discard raw edits for this file')
        onClicked: root.controller.model.raw(root.file, root.controller.model.snapshot.raw_files[root.file] || '')
    }
}
