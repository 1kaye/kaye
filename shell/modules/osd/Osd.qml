import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Bottom-center OSD pill for volume & brightness triggered via `qs ipc call osd ...`.
Scope {
  id: root

  property bool shown: false
  property string icon: "󰕾"
  property string label: ""
  property real level: 0

  function present(ic, text, pct) {
    root.icon = ic
    root.label = text
    root.level = Math.max(0, Math.min(100, Number(pct) || 0))
    root.shown = true
    hideTimer.restart()
  }

  IpcHandler {
    target: "osd"
    function volume(pct: string): void {
      root.present("󰕾", pct + "%", pct)
    }
    function mute(state: string): void {
      var muted = String(state).trim() === "true"
      root.present(muted ? "󰝟" : "󰕾", muted ? "Muted" : "Unmuted", muted ? 0 : 100)
    }
    function brightness(pct: string): void {
      root.present("󰃠", pct + "%", pct)
    }
  }

  Timer {
    id: hideTimer
    interval: 1400
    onTriggered: root.shown = false
  }

  PanelWindow {
    visible: root.shown
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "kaye-osd"
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    anchors.bottom: true
    margins.bottom: 64
    implicitWidth: 230
    implicitHeight: 44

    Rectangle {
      anchors.fill: parent
      radius: Style.radius
      color: Commons.Color.darkBackground
      border.width: 1
      border.color: Commons.Color.accent

      Row {
        anchors.centerIn: parent
        spacing: 10

        Text {
          text: root.icon
          textFormat: Text.PlainText
          color: Commons.Color.accent
          font.family: Style.fontFamily
          font.pixelSize: 16
          anchors.verticalCenter: parent.verticalCenter
        }

        Rectangle {
          width: 118
          height: 6
          radius: 3
          color: Commons.Color.lighterBackground
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            height: parent.height
            width: parent.width * (root.level / 100.0)
            radius: 3
            color: Commons.Color.accent
          }
        }

        Text {
          text: root.label
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSizeSmall
          width: 44
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
