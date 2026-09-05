import QtQuick
import QtQuick.Controls.Basic as Basic
import qs.Common

Basic.TextField {
    id: control
    implicitHeight: 38
    implicitWidth: 160
    leftPadding: 12
    rightPadding: 12
    color: Theme.surfaceText
    placeholderTextColor: Theme.surfaceVariantText
    selectionColor: Theme.primary
    selectedTextColor: Theme.primaryText
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeMedium
    selectByMouse: true
    background: Rectangle {
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: control.activeFocus ? 2 : 1
        border.color: control.activeFocus ? Theme.primary : Theme.outline
        opacity: control.enabled ? 1 : 0.45
    }
}
