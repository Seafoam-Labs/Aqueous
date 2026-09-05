import QtQuick
import QtQuick.Controls.Basic as Basic
import qs.Common

Basic.Button {
    id: control
    implicitHeight: 36
    implicitWidth: Math.max(68, contentItem.implicitWidth + 24)
    padding: 10
    leftPadding: 12
    rightPadding: 12
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeMedium
    opacity: enabled ? 1 : 0.45
    background: Rectangle {
        radius: Theme.cornerRadius
        color: control.highlighted ? Theme.primary : control.hovered ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
        border.width: control.visualFocus ? 2 : 0
        border.color: Theme.primary
    }
    contentItem: Text {
        text: control.text
        font: control.font
        color: control.highlighted ? Theme.primaryText : Theme.surfaceText
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
