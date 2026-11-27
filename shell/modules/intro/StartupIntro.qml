import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Kaye OS Startup Intro Splash (inspired by Omarchy's smooth login cover).
// Plays once per Hyprland session when Quickshell boots, displaying the KAYE logo
// before smoothly fading out to reveal the desktop.
Scope {
  id: root

  readonly property string sessionId: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "default"
  readonly property string markerFile: "/tmp/kaye-intro-" + sessionId + ".done"

  property bool active: false
  property real coverOpacity: 1.0
  property real logoScale: 0.95
  property real progressWidth: 0.0

  function startIntro() {
    if (!Config.showIntro) return
    root.active = true
    root.coverOpacity = 1.0
    root.logoScale = 1.0
    root.progressWidth = 1.0
    holdTimer.restart()
  }

  Process {
    id: checkMarker
    running: true
    command: ["bash", "-c", "test -f \"$1\" && echo done || (touch \"$1\" && echo play)", "--", root.markerFile]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text).trim() === "play") root.startIntro()
      }
    }
  }

  Timer {
    id: holdTimer
    interval: 950
    onTriggered: {
      root.coverOpacity = 0.0
      finishTimer.restart()
    }
  }

  Timer {
    id: finishTimer
    interval: 420
    onTriggered: root.active = false
  }

  Variants {
    model: root.active ? Quickshell.screens : []

    PanelWindow {
      required property var modelData
      screen: modelData

      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "kaye-intro"
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      color: "transparent"

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      Rectangle {
        anchors.fill: parent
        color: Commons.Color.darkBackground
        opacity: root.coverOpacity

        Behavior on opacity {
          NumberAnimation { duration: Style.duration(380); easing.type: Easing.OutCubic }
        }

        Column {
          anchors.centerIn: parent
          spacing: 24
          scale: root.logoScale

          Behavior on scale {
            NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutCubic }
          }

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: "file://" + Commons.Color.logoSvgPath
            sourceSize.width: 340
            sourceSize.height: 85
            width: 340
            height: 85
            fillMode: Image.PreserveAspectFit
            smooth: true
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 240
            height: 4
            radius: 2
            color: Commons.Color.lighterBackground

            Rectangle {
              height: parent.height
              width: parent.width * root.progressWidth
              radius: 2
              color: Commons.Color.accent

              Behavior on width {
                NumberAnimation { duration: Style.duration(850); easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }
    }
  }
}
