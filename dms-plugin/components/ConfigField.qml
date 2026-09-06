import QtQuick
import "../controls" as Aq
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import qs.Common

ColumnLayout {
    id: root
    required property var field
    required property var draftModel
    readonly property var current: draftModel.value(field.id)
    readonly property bool numeric: field.type === 'integer' || field.type === 'double'
    readonly property var choices: field.options || []
    spacing: 4
    function tr(text) {
        return I18n.trFor('aqueousSettings', text);
    }
    function set(value) {
        draftModel.error(field.id, '');
        draftModel.change(field.id, value);
    }
    RowLayout {
        Layout.fillWidth: true
        Label {
            color: Theme.surfaceText
            text: root.tr(root.field.label) + (root.field.inherited ? ' · inherited' : '')
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.bold: true
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', '↶')
            Accessible.name: root.tr('Use default')
            onClicked: root.set(root.field.default)
        }
    }
    Label {
        color: Theme.surfaceVariantText
        text: root.tr(root.field.description)
        visible: text.length > 0
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
    }
    Switch {
        visible: root.field.type === 'boolean'
        checked: root.current === true
        onToggled: root.set(checked)
    }
    Aq.ComboBox {
        visible: root.field.type === 'select'
        Layout.fillWidth: true
        model: root.choices
        currentIndex: root.choices.indexOf(root.current)
        onActivated: root.set(root.choices[currentIndex])
    }
    RowLayout {
        visible: root.field.type !== 'boolean' && root.field.type !== 'select'
        Layout.fillWidth: true
        Aq.TextField {
            id: editor
            Layout.fillWidth: true
            text: Array.isArray(root.current) ? root.current.join(', ') : String(root.current ?? '')
            selectByMouse: true
            placeholderText: root.field.type === 'string_list' ? root.tr('Comma-separated values') : ''
            onTextEdited: {
                if (root.numeric) {
                    const number = Number(text);
                    if (!text.trim() || !Number.isFinite(number) || (root.field.type === 'integer' && !Number.isInteger(number)) || (root.field.min !== undefined && number < root.field.min) || (root.field.max !== undefined && number > root.field.max)) {
                        root.draftModel.error(root.field.id, root.field.label + ': enter a valid number (' + (root.field.min ?? '−∞') + ' … ' + (root.field.max ?? '∞') + ').');
                        return;
                    }
                    root.set(number);
                } else
                    root.set(root.field.type === 'string_list' ? text.split(',').map(s => s.trim()).filter(Boolean) : text);
            }
        }
        Aq.Button {
            visible: root.field.type === 'color'
            text: root.tr('Pick color')
            onClicked: {
                const raw = String(root.current);
                picker.selectedColor = raw.startsWith('0x') ? '#' + raw.slice(2) : raw;
                picker.open();
            }
        }
    }
    ColorDialog {
        id: picker
        options: ColorDialog.ShowAlphaChannel
        onAccepted: {
            const c = selectedColor;
            function byte(v) {
                return Math.round(v * 255).toString(16).padStart(2, '0');
            }
            root.set('0x' + byte(c.a) + byte(c.r) + byte(c.g) + byte(c.b));
        }
    }
    Label {
        visible: !!root.draftModel.errors[root.field.id]
        text: root.draftModel.errors[root.field.id] || ''
        color: Theme.error
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
    }
}
