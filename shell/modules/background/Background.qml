import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Multi-monitor wallpaper layer backed by ~/.local/state/kaye/current/background.
Scope {
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property var modelData
      screen: modelData

      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.namespace: "kaye-background"
      exclusionMode: ExclusionMode.Ignore
      color: Commons.Color.darkBackground

      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }

      Image {
        anchors.fill: parent
        source: "file://" + Commons.Color.backgroundPath + "?r=" + Commons.Color.revision
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
      }
    }
  }
}
