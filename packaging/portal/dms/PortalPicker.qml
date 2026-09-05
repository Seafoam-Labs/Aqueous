import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

FocusScope {
    id: root
    required property var selection
    signal selected(int sourceIndex)
    signal cancelled

    function focusSearch() {
        search.forceActiveFocus();
    }
    function accept() {
        if (selection.selectedSource >= 0)
            selected(selection.selectedSource);
    }
    Keys.onEscapePressed: root.cancelled()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 12
        Text {
            text: "Select a source to share"
            color: Theme.surfaceText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeLarge
        }
        Controls.TextField {
            id: search
            Layout.fillWidth: true
            placeholderText: "Search monitors and windows"
            color: Theme.surfaceText
            placeholderTextColor: Theme.surfaceVariantText
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeMedium
            selectByMouse: true
            onTextChanged: root.selection.query = text
            onAccepted: root.accept()
            Keys.onDownPressed: root.selection.move(1)
            Keys.onUpPressed: root.selection.move(-1)
            background: Rectangle {
                color: Theme.surfaceContainerHigh
                radius: Theme.cornerRadius
                border.color: search.activeFocus ? Theme.primary : Theme.outline
            }
        }
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.selection.filtered
            currentIndex: root.selection.currentIndex
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
            spacing: 4
            Controls.ScrollBar.vertical: Controls.ScrollBar {}
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: 52
                radius: Theme.cornerRadius
                color: index === root.selection.currentIndex ? Theme.primary : Theme.surfaceContainerHigh
                Text {
                    anchors.fill: parent
                    anchors.margins: 12
                    text: modelData.label
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                    color: index === root.selection.currentIndex ? Theme.primaryText : Theme.surfaceText
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeMedium
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.selection.currentIndex = index
                    onDoubleClicked: root.selected(modelData.sourceIndex)
                }
            }
            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: "No matching sources"
                color: Theme.surfaceVariantText
                font.family: Theme.fontFamily
            }
        }
        RowLayout {
            Layout.alignment: Qt.AlignRight
            spacing: 12
            DankButton {
                text: "Cancel"
                onClicked: root.cancelled()
            }
            DankButton {
                text: "Share"
                enabled: root.selection.selectedSource >= 0
                onClicked: root.accept()
            }
        }
    }
    Connections {
        target: root.selection
        function onChoicesChanged() { search.text = ""; }
    }
}
