import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

ColumnLayout {
    id: root
    property var controller
    readonly property var bindings: controller?.model.keybinds() || []
    spacing: 12
    Label {
        text: I18n.trFor('aqueousSettings', 'Custom shortcuts')
        font.bold: true
    }
    Aq.Button {
        text: I18n.trFor('aqueousSettings', 'Add shortcut')
        onClicked: root.controller.model.addBinding('spawn:')
    }
    Repeater {
        model: root.bindings.length
        RowLayout {
            id: row
            required property int index
            readonly property var binding: root.bindings[index]
            Layout.fillWidth: true
            Aq.TextField {
                id: chord
                Layout.preferredWidth: 170
                text: row.binding?.chord || ''
                placeholderText: I18n.trFor('aqueousSettings', 'Super+Alt+A')
                onTextEdited: root.controller.model.keybind(row.binding.id, text, command.text)
            }
            Aq.TextField {
                id: command
                Layout.fillWidth: true
                text: row.binding?.command || ''
                placeholderText: I18n.trFor('aqueousSettings', 'spawn:terminal')
                onTextEdited: root.controller.model.keybind(row.binding.id, chord.text, text)
            }
            ToolButton {
                text: I18n.trFor('aqueousSettings', '×')
                Accessible.name: I18n.trFor('aqueousSettings', 'Remove shortcut')
                onClicked: root.controller.model.keybind(row.binding.id, '', '', true)
            }
        }
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Built-in shortcuts and action commands')
        font.bold: true
    }
    SchemaFields {
        Layout.fillWidth: true
        controller: root.controller
        category: 'keybinds'
    }
}
