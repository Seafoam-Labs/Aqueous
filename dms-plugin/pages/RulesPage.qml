import QtQuick
import "../controls" as Aq
import qs.Common
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
import "../services/RuleFields.js" as Rules

ColumnLayout {
    id: root
    property var controller
    property int selected: 0
    readonly property var rules: controller?.model.rules() || []
    readonly property var rule: rules[selected] || null
    spacing: 12
    function stage(op) {
        try {
            controller.model.rule(op);
        } catch (e) {
            controller.status = String(e);
        }
    }
    function set(key, value) {
        if (rule)
            stage({
                id: rule.id,
                op: 'update',
                values: {
                    [key]: value
                }
            });
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Ordered window rules')
        font.bold: true
    }
    Label {
        text: I18n.trFor('aqueousSettings', 'Rule moves are staged individually. Apply or discard a move before further rule edits.')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        model: root.rules.map((r, i) => (i + 1) + ': ' + (r.values.app_id || r.values.class || r.values.title || r.values.content_type || 'New rule'))
        currentIndex: root.selected
        onActivated: root.selected = currentIndex
    }
    RowLayout {
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Add rule')
            onClicked: {
                root.stage({
                    id: 'new-rule:' + Date.now(),
                    op: 'add',
                    values: {
                        app_id: ''
                    }
                });
                root.selected = root.rules.length - 1;
            }
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Remove')
            enabled: !!root.rule
            onClicked: {
                root.stage({
                    id: root.rule.id,
                    op: 'delete'
                });
                root.selected = Math.max(0, root.selected - 1);
            }
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Move up')
            enabled: root.selected > 0
            onClicked: root.stage({
                id: root.rule.id,
                op: 'move',
                direction: -1
            })
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Move down')
            enabled: root.selected < root.rules.length - 1
            onClicked: root.stage({
                id: root.rule.id,
                op: 'move',
                direction: 1
            })
        }
    }
    Repeater {
        model: root.rule ? Rules.fields : []
        RowLayout {
            id: row
            required property var modelData
            readonly property var value: root.rule?.values[modelData.key]
            Layout.fillWidth: true
            Label {
                text: row.modelData.label
                Layout.preferredWidth: 155
            }
            Aq.ComboBox {
                Layout.fillWidth: true
                visible: row.modelData.type === 'boolean' || row.modelData.type === 'select'
                model: ['Unset'].concat(row.modelData.type === 'boolean' ? ['false', 'true'] : row.modelData.options || [])
                currentIndex: row.value === undefined || row.value === '' ? 0 : model.indexOf(String(row.value))
                onActivated: root.set(row.modelData.key, currentIndex === 0 ? '' : row.modelData.type === 'boolean' ? currentText === 'true' : currentText)
            }
            Aq.TextField {
                Layout.fillWidth: true
                visible: row.modelData.type === 'number' || row.modelData.type === 'string'
                text: String(row.value ?? '')
                selectByMouse: true
                onTextEdited: root.set(row.modelData.key, row.modelData.type === 'number' && text.trim() && Number.isFinite(Number(text)) ? Number(text) : text)
            }
        }
    }
    SchemaFields {
        Layout.fillWidth: true
        controller: root.controller
        category: 'rules'
    }
}
