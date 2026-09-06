import QtQuick
import "../controls" as Aq
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common

ColumnLayout {
    id: root
    required property var controller
    Label {
        text: root.controller?.status
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        color: root.controller?.errorCode ? Theme.error : Theme.surfaceText
    }
    RowLayout {
        Layout.fillWidth: true
        Label {
            color: Theme.surfaceText
            text: root.controller?.model.count + ' draft changes'
            Layout.fillWidth: true
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Reload / Discard')
            enabled: !root.controller?.client.busy
            onClicked: {
                if (root.controller?.model.count || root.controller?.model.hasErrors)
                    discard.open();
                else
                    root.controller?.load();
            }
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Validate')
            enabled: !root.controller?.client.busy && !root.controller?.model.hasErrors && !!root.controller?.model.snapshot.generation
            onClicked: root.controller?.submit('validate')
        }
        Aq.Button {
            text: I18n.trFor('aqueousSettings', 'Apply')
            highlighted: true
            enabled: !root.controller?.client.busy && !root.controller?.model.hasErrors && root.controller?.model.count > 0 && !['timeout', 'invalid_response'].includes(root.controller?.errorCode)
            onClicked: root.controller?.submit('apply')
        }
    }
    Dialog {
        id: discard
        title: I18n.trFor('aqueousSettings', 'Discard drafts and reload?')
        modal: true
        standardButtons: Dialog.Discard | Dialog.Cancel
        onDiscarded: {
            root.controller?.model.accept(root.controller?.model.snapshot);
            root.controller?.load();
        }
    }
}
