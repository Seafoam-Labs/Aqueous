import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    property var controller: null
    required property string category
    property var excluded: []
    spacing: 16
    Repeater {
        model: (root.controller?.model.snapshot.fields || []).filter(f => f.category === root.category && !root.excluded.includes(f.id) && (!root.controller?.search || (f.label + ' ' + f.description + ' ' + f.id).toLowerCase().includes(root.controller.search.toLowerCase())))
        ConfigField {
            required property var modelData
            field: modelData
            draftModel: root.controller.model
            Layout.fillWidth: true
        }
    }
}
