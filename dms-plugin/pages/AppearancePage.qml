import QtQuick
import "../controls" as Aq
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import "../components"

ColumnLayout {
    id: root
    property var controller
    readonly property var typography: controller?.model.snapshot.desktop_typography
    readonly property var faces: (typography?.faces || []).filter(f => f.family === controller?.model.value('desktop.font.family'))
    spacing: 12
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Desktop typography')
        font.bold: true
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        editable: true
        model: root.typography?.families || []
        currentIndex: model.indexOf(root.controller?.model.value('desktop.font.family'))
        onActivated: root.family(currentText)
        onAccepted: root.family(editText)
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        model: ['Automatic face'].concat(root.faces.map(f => f.style + ' · ' + f.weight + ' · ' + f.slant + ' · ' + f.width))
        currentIndex: Math.max(0, root.faces.findIndex(f => f.style === root.controller?.model.value('desktop.font.style') && f.weight === root.controller?.model.value('desktop.font.weight') && f.slant === root.controller?.model.value('desktop.font.slant') && f.width === root.controller?.model.value('desktop.font.width')) + 1)
        onActivated: {
            const f = currentIndex ? root.faces[currentIndex - 1] : {
                style: '',
                weight: 400,
                slant: 'normal',
                width: 'normal'
            };
            for (const key of ['style', 'weight', 'slant', 'width'])
                root.controller.model.change('desktop.font.' + key, f[key]);
        }
    }
    function family(value) {
        controller.model.change('desktop.font.family', value);
        for (const [key, value] of Object.entries({
            style: '',
            weight: 400,
            slant: 'normal',
            width: 'normal'
        }))
            controller.model.change('desktop.font.' + key, value);
    }
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Cursor theme')
        font.bold: true
    }
    Aq.ComboBox {
        Layout.fillWidth: true
        editable: true
        model: root.controller?.model.snapshot.desktop_cursor?.themes || []
        currentIndex: model.indexOf(root.controller?.model.value('desktop.cursor.theme'))
        onActivated: root.controller.model.change('desktop.cursor.theme', currentText)
        onAccepted: root.controller.model.change('desktop.cursor.theme', editText)
    }
    SchemaFields {
        Layout.fillWidth: true
        controller: root.controller
        category: 'appearance'
        excluded: ['desktop.font.family', 'desktop.font.style', 'desktop.font.weight', 'desktop.font.slant', 'desktop.font.width', 'desktop.cursor.theme']
    }
    Label {
        color: Theme.surfaceText
        text: I18n.trFor('aqueousSettings', 'Synchronization targets')
        font.bold: true
    }
    Repeater {
        model: (root.typography?.targets || []).filter(t => t.id !== 'noctalia').concat(root.controller?.model.snapshot.desktop_cursor?.targets || [])
        Label {
            color: Theme.surfaceText
            required property var modelData
            text: modelData.id + ': ' + modelData.state
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }
    }
    Label {
        color: Theme.surfaceText
        text: 'DMS: ' + (root.controller?.appearance.state || '') + ' — ' + (root.controller?.appearance.message || '')
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
    }
    RowLayout {
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Retry DMS font sync')
            enabled: !!root.typography
            onClicked: root.controller.appearance.apply(root.typography)
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Stage toolkit font retry')
            onClicked: root.controller.model.mutate(d => d.sync_typography = true)
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Stage cursor sync retry')
            onClicked: root.controller.model.mutate(d => d.sync_cursor = true)
        }
    }
}
