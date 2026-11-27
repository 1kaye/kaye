pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Reactive shell configuration backed by ~/.config/kaye/shell.json.
Singleton {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string kayePath: Quickshell.env("KAYE_PATH") || (home + "/kaye")
  readonly property string configPath: home + "/.config/kaye/shell.json"

  property string barPosition: "top"
  property string barBackground: "opaque"
  property bool barHidden: false
  property int barHeight: 30
  property bool showIntro: true
  property bool animationsEnabled: true
  property int idleScreensaver: 180
  property int idleLock: 300

  function parseJson(raw) {
    if (!raw) return
    try {
      var data = JSON.parse(raw)
      if (data.bar) {
        if (data.bar.position) root.barPosition = String(data.bar.position)
        if (data.bar.background) root.barBackground = String(data.bar.background)
        if (data.bar.hidden !== undefined) root.barHidden = data.bar.hidden === true
        if (data.bar.height) root.barHeight = Number(data.bar.height)
        if (data.bar.showIntro !== undefined) root.showIntro = data.bar.showIntro === true
      }
      if (data.idle) {
        if (data.idle.screensaver) root.idleScreensaver = Number(data.idle.screensaver)
        if (data.idle.lock) root.idleLock = Number(data.idle.lock)
      }
    } catch (e) {
      console.warn("kaye-shell: failed to parse shell.json:", e)
    }
  }

  FileView {
    id: cfgFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseJson(text())
    onFileChanged: reload()
  }
}
