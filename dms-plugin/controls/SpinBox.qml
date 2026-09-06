import QtQuick
import QtQuick.Controls.Basic as Basic
import qs.Common

Basic.SpinBox {
    id: control
    implicitHeight: 38
    implicitWidth: 140
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeMedium
    palette.text: Theme.surfaceText
    palette.buttonText: Theme.surfaceText
    palette.button: Theme.surfaceContainerHigh
    palette.base: Theme.surfaceContainerHigh
    palette.highlight: Theme.primary
    palette.highlightedText: Theme.primaryText
    background: Rectangle {
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: control.visualFocus ? 2 : 1
        border.color: control.visualFocus ? Theme.primary : Theme.outline
    }
}
