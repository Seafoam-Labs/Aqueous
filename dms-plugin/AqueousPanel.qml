import QtQuick
import "controls" as Aq
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import "components"
import "pages"

Pane {
    id: root
    property var controller: null
    signal closeRequested
    focus: true
    Keys.onEscapePressed: closeRequested()
    padding: 12
    palette.window: Theme.surface
    palette.base: Theme.surfaceContainer
    palette.text: Theme.surfaceText
    palette.windowText: Theme.surfaceText
    palette.button: Theme.surfaceContainerHigh
    palette.buttonText: Theme.surfaceText
    palette.highlight: Theme.primary
    palette.highlightedText: Theme.primaryText
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeMedium
    background: Rectangle {
        color: Theme.surface
    }
    readonly property var pages: ['overview', 'appearance', 'layouts', 'input', 'displays', 'rules', 'keybinds', 'advanced']
    readonly property var labels: ['Overview', 'Appearance', 'Layouts', 'Input', 'Displays', 'Rules', 'Keybinds', 'Advanced']
    ColumnLayout {
        anchors.fill: parent
        visible: !!root.controller
        RowLayout {
            Layout.fillWidth: true
            Aq.ComboBox {
                model: root.labels.map(s => I18n.trFor('aqueousSettings', s))
                currentIndex: root.pages.indexOf(root.controller?.page || 'overview')
                onActivated: root.controller.page = root.pages[currentIndex]
            }
            Aq.TextField {
                Layout.fillWidth: true
                placeholderText: I18n.trFor('aqueousSettings', 'Search settings')
                text: root.controller?.search || ''
                onTextEdited: root.controller.search = text
            }
            BusyIndicator {
                running: root.controller?.client.busy || false
                visible: running
                implicitWidth: 30
                implicitHeight: 30
            }
        }
        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                width: scroll.availableWidth
                enabled: !!root.controller && !root.controller.client.busy
                Loader {
                    Layout.fillWidth: true
                    source: root.controller ? 'pages/' + root.labels[root.pages.indexOf(root.controller.page)] + 'Page.qml' : ''
                    onLoaded: item.controller = Qt.binding(() => root.controller)
                }
            }
        }
        ApplyBar {
            Layout.fillWidth: true
            controller: root.controller
            visible: !!root.controller
        }
    }
}
