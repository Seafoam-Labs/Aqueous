import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var controller
    spacing: 8
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Legacy A–D snap zones')
        font.bold: true
    }
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Edit legacy zones here, or migrate them into a named layout above.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Repeater {
        model: ['a', 'b', 'c', 'd']
        ColumnLayout {
            id: row
            required property string modelData
            readonly property var original: (root.controller?.model.snapshot.snap_zones || []).find(z => z.id === modelData) || {
                id: modelData,
                x: 0,
                y: 0,
                width: 0.5,
                height: 0.5
            }
            readonly property var zone: root.controller?.model.draft.snap_zone_changes[modelData] || original
            Layout.fillWidth: true
            function set(key, value) {
                root.controller.model.mutate(d => d.snap_zone_changes[modelData] = Object.assign({}, zone, {
                        op: 'update',
                        [key]: value
                    }));
            }
            RowLayout {
                Label {
                    color: Theme.surfaceText
                    text: row.modelData.toUpperCase() + (row.zone.op === 'delete' ? ' · removed' : '')
                    Layout.fillWidth: true
                }
                Aq.Button {
                    text: I18n.trFor('aqueousSettings', 'Bind')
                    onClicked: root.controller.model.addBinding('builtin:snap_zone:' + row.modelData)
                }
                Aq.Button {
                    text: I18n.trFor('aqueousSettings', 'Remove')
                    onClicked: root.controller.model.mutate(d => d.snap_zone_changes[row.modelData] = {
                            id: row.modelData,
                            op: 'delete'
                        })
                }
                Aq.Button {
                    text: I18n.trFor('aqueousSettings', 'Undo')
                    onClicked: root.controller.model.mutate(d => delete d.snap_zone_changes[row.modelData])
                }
            }
            RowLayout {
                enabled: row.zone.op !== 'delete'
                Repeater {
                    model: ['x', 'y', 'width', 'height']
                    Aq.TextField {
                        required property string modelData
                        Layout.fillWidth: true
                        text: String(row.zone[modelData] ?? '')
                        placeholderText: modelData + ' (0–1)'
                        onTextEdited: row.set(modelData, text.trim() && Number.isFinite(Number(text)) ? Number(text) : text)
                    }
                }
            }
        }
    }
}
