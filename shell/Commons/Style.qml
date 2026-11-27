pragma Singleton
import QtQuick
import Quickshell

Singleton {
  id: root

  readonly property string fontFamily: "JetBrainsMono Nerd Font"
  readonly property int fontSizeSmall: 11
  readonly property int fontSizeBody: 12
  readonly property int fontSizeTitle: 14
  readonly property int fontSizeClock: 12
  readonly property int radius: 8
  readonly property int radiusSmall: 6
  readonly property int padX: 10
  readonly property int padY: 6

  function duration(ms) {
    return Config.animationsEnabled ? ms : 0
  }
}
