import QtQuick
import qs.Commons
import qs.Commons as Commons

// Reusable bar button with hover, tooltip, and click feedback.
// Never place a HoverHandler above this item's MouseArea (Qt 6 hover blocking pitfall).
Item {
  id: root

  property var bar: null
  property string text: ""
  property string tooltipText: ""
  property bool active: false
  property bool dimmed: false
  property color textColor: active ? Commons.Color.barActive : Commons.Color.barText
  property real horizontalPadding: 8
  property int fontSize: Style.fontSizeBody

  signal pressed(int button)
  signal wheelDelta(int delta)

  readonly property bool tooltipHovered: visible && mouseArea.containsMouse

  implicitWidth: Math.max(24, label.implicitWidth + horizontalPadding * 2)
  implicitHeight: bar ? bar.barHeight : Config.barHeight

  Rectangle {
    anchors.fill: parent
    anchors.margins: 3
    radius: Style.radiusSmall
    color: mouseArea.containsMouse ? Commons.Color.lighterBackground : "transparent"
    opacity: mouseArea.containsMouse ? 0.85 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.text
    textFormat: Text.PlainText
    color: root.textColor
    opacity: root.dimmed ? 0.45 : 1.0
    font.family: Style.fontFamily
    font.pixelSize: root.fontSize
    scale: mouseArea.pressed ? 0.92 : 1.0

    Behavior on opacity { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      if (root.bar && root.tooltipText !== "") {
        root.bar.showTooltip(root, root.tooltipText)
      }
    }
    onExited: {
      if (root.bar) root.bar.hideTooltip(root)
    }
    onClicked: function(mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      root.pressed(mouse.button)
    }
    onWheel: function(wheel) {
      root.wheelDelta(wheel.angleDelta.y)
    }
  }
}
