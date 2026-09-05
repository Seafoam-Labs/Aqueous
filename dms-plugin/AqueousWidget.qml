import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root
    readonly property var controller: pluginService?.pluginDaemonInstances?.[pluginId] || null
    popoutWidth: Math.min(860, (parentScreen?.width || 900) - 32)
    popoutHeight: Math.min(720, (parentScreen?.height || 800) - 80)
    horizontalBarPill: Component {
        Item {
            implicitWidth: 32
            implicitHeight: root.widgetThickness
            DankIcon {
                anchors.centerIn: parent
                name: 'tune'
                size: root.iconSize
                color: Theme.surfaceText
            }
        }
    }
    verticalBarPill: horizontalBarPill
    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: I18n.trFor('aqueousSettings', 'Aqueous Settings')
            showCloseButton: true
            function opened() {
                if (!parentPopout?.shouldBeVisible || !root.controller)
                    return;
                root.controller.outputName = root.parentScreen?.name || '';
            }
            onParentPopoutChanged: opened()
            Connections {
                target: popout.parentPopout
                function onShouldBeVisibleChanged() {
                    popout.opened();
                }
            }
            AqueousPanel {
                width: parent.width
                height: root.popoutHeight - 70
                controller: root.controller
                onCloseRequested: if (popout.closePopout)
                    popout.closePopout()
                Component.onCompleted: {
                    if (controller && root.parentScreen)
                        controller.outputName = root.parentScreen.name;
                }
            }
        }
    }
    pillRightClickAction: () => {
        if (controller)
            controller.show(parentScreen?.name || '');
    }
}
