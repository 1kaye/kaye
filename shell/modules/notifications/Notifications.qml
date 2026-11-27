import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Notification daemon & toast cards (respects ~/.local/state/kaye/toggles/dnd).
Scope {
  id: root

  property bool dnd: false
  readonly property string dndPath: Config.home + "/.local/state/kaye/toggles/dnd"

  ListModel { id: toastModel }

  Process {
    id: dndProbe
    running: true
    command: ["bash", "-c", "test -f \"$1\" && echo on || echo off", "--", root.dndPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dnd = String(text).trim() === "on"
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: if (!dndProbe.running) dndProbe.running = true
  }

  NotificationServer {
    id: server
    bodySupported: true
    onNotification: function(n) {
      if (root.dnd && n.urgency !== NotificationUrgency.Critical) return
      toastModel.insert(0, {
        summary: String(n.summary || "Notification"),
        body: String(n.body || ""),
        urgent: n.urgency === NotificationUrgency.Critical
      })
      if (toastModel.count > 4) toastModel.remove(toastModel.count - 1)
      dismissTimer.restart()
    }
  }

  Timer {
    id: dismissTimer
    interval: 4500
    onTriggered: {
      if (toastModel.count > 0) {
        toastModel.remove(toastModel.count - 1)
        if (toastModel.count > 0) restart()
      }
    }
  }

  PanelWindow {
    visible: toastModel.count > 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "kaye-notifications"
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    anchors.top: true
    anchors.right: true
    margins.top: Config.barHeight + 12
    margins.right: 12
    implicitWidth: 330
    implicitHeight: toastColumn.implicitHeight

    Column {
      id: toastColumn
      width: parent.width
      spacing: 8

      Repeater {
        model: toastModel

        Rectangle {
          required property int index
          required property string summary
          required property string body
          required property bool urgent

          width: toastColumn.width
          implicitHeight: contentCol.implicitHeight + 20
          radius: Style.radius
          color: Commons.Color.darkBackground
          border.width: 1
          border.color: urgent ? Commons.Color.red : Commons.Color.muted

          Column {
            id: contentCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 12
            spacing: 4

            Text {
              width: parent.width
              text: summary
              textFormat: Text.PlainText
              color: urgent ? Commons.Color.red : Commons.Color.accent
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSizeBody
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              visible: body !== ""
              width: parent.width
              text: body
              textFormat: Text.PlainText
              color: Commons.Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSizeSmall
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }
          }

          MouseArea {
            anchors.fill: parent
            onClicked: toastModel.remove(index)
          }
        }
      }
    }
  }
}
