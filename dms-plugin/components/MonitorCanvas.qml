import QtQuick
import QtQuick.Controls
import qs.Common

Rectangle {
    id: root
    required property var monitors
    property string selected: ''
    signal moved(var monitor, int x, int y)
    signal selectedMonitor(string id)
    color: Theme.surfaceContainer
    radius: 8
    implicitHeight: 240
    clip: true
    function dimensions(m) {
        const rotated = ['90', '270', 'flipped-90', 'flipped-270'].includes(m.transform);
        return {
            width: rotated ? m.height : m.width,
            height: rotated ? m.width : m.height
        };
    }
    readonly property real minX: Math.min(0, ...monitors.map(m => m.x))
    readonly property real minY: Math.min(0, ...monitors.map(m => m.y))
    readonly property real maxX: Math.max(1, ...monitors.map(m => m.x + dimensions(m).width))
    readonly property real maxY: Math.max(1, ...monitors.map(m => m.y + dimensions(m).height))
    readonly property real scale: Math.min((width - 36) / (maxX - minX), (height - 36) / (maxY - minY))
    Repeater {
        model: root.monitors
        Rectangle {
            id: card
            required property var modelData
            x: 18 + (modelData.x - root.minX) * root.scale
            y: 18 + (modelData.y - root.minY) * root.scale
            width: Math.max(16, root.dimensions(modelData).width * root.scale)
            height: Math.max(16, root.dimensions(modelData).height * root.scale)
            color: Theme.surfaceContainerHigh
            border.width: 2
            border.color: root.selected === modelData.id ? Theme.primary : Theme.outline
            radius: 5
            Label {
                anchors.centerIn: parent
                width: parent.width - 8
                text: card.modelData.name + (card.modelData.connected ? '' : '\nOffline')
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                font.pixelSize: Math.max(9, Math.min(14, card.width / 10))
                color: Theme.surfaceText
            }
            MouseArea {
                anchors.fill: parent
                drag.target: card
                property real initialX
                property real initialY
                property real initialScale
                property real originX
                property real originY
                onPressed: {
                    root.selectedMonitor(card.modelData.id);
                    initialX = card.x;
                    initialY = card.y;
                    initialScale = root.scale;
                    originX = card.modelData.x;
                    originY = card.modelData.y;
                }
                onReleased: root.moved(card.modelData, Math.round(originX + (card.x - initialX) / initialScale), Math.round(originY + (card.y - initialY) / initialScale))
            }
        }
    }
}
