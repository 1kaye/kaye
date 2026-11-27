pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Reactive theme palette backed by ~/.local/state/kaye/current/theme/shell.toml.
// Switching themes via `kaye theme set <name>` updates the entire shell live.
Singleton {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string themeTomlPath: home + "/.local/state/kaye/current/theme/shell.toml"
  readonly property string backgroundPath: home + "/.local/state/kaye/current/background"
  readonly property string logoSvgPath: (Quickshell.env("KAYE_PATH") || (home + "/kaye")) + "/branding/logo.svg"

  property int revision: 0
  property string mode: "dark"

  property color accent: "#89b4fa"
  property color selection: "#45475a"
  property color muted: "#585b70"
  property color background: "#1e1e2e"
  property color darkBackground: "#161622"
  property color lighterBackground: "#313244"
  property color foreground: "#cdd6f4"
  property color subtext: "#6c7086"
  property color red: "#f38ba8"
  property color yellow: "#f9e2af"
  property color green: "#a6e3a1"
  property color cyan: "#94e2d5"
  property color magenta: "#cba6f7"

  property color barBackground: "#161622"
  property color barText: "#cdd6f4"
  property color barActive: "#89b4fa"
  property color barUrgent: "#f38ba8"

  property color tooltipBackground: "#161622"
  property color tooltipText: "#cdd6f4"
  property color tooltipBorder: "#89b4fa"

  function parseToml(text) {
    if (!text) return
    var section = ""
    var map = {}
    var lines = String(text).split(/\r?\n/)
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line || line.startsWith("#")) continue
      if (line.startsWith("[") && line.endsWith("]")) {
        section = line.slice(1, -1).trim()
        continue
      }
      var eq = line.indexOf("=")
      if (eq === -1) continue
      var key = line.slice(0, eq).trim()
      var val = line.slice(eq + 1).trim().replace(/^"(.*)"$/, "$1")
      var fullKey = section ? (section + "." + key) : key
      map[fullKey] = val
    }
    if (map["mode"]) root.mode = map["mode"]
    if (map["palette.accent"]) root.accent = map["palette.accent"]
    if (map["palette.selection"]) root.selection = map["palette.selection"]
    if (map["palette.muted"]) root.muted = map["palette.muted"]
    if (map["palette.background"]) root.background = map["palette.background"]
    if (map["palette.dark_background"]) root.darkBackground = map["palette.dark_background"]
    if (map["palette.lighter_background"]) root.lighterBackground = map["palette.lighter_background"]
    if (map["palette.foreground"]) root.foreground = map["palette.foreground"]
    if (map["palette.dark_foreground"]) root.subtext = map["palette.dark_foreground"]
    if (map["palette.red"]) root.red = map["palette.red"]
    if (map["palette.yellow"]) root.yellow = map["palette.yellow"]
    if (map["palette.green"]) root.green = map["palette.green"]
    if (map["palette.cyan"]) root.cyan = map["palette.cyan"]
    if (map["palette.magenta"]) root.magenta = map["palette.magenta"]

    if (map["bar.background"]) root.barBackground = map["bar.background"]
    if (map["bar.text"]) root.barText = map["bar.text"]
    if (map["bar.active"]) root.barActive = map["bar.active"]
    if (map["bar.urgent"]) root.barUrgent = map["bar.urgent"]

    if (map["tooltip.background"]) root.tooltipBackground = map["tooltip.background"]
    if (map["tooltip.text"]) root.tooltipText = map["tooltip.text"]
    if (map["tooltip.border"]) root.tooltipBorder = map["tooltip.border"]

    root.revision += 1
  }

  FileView {
    id: themeFile
    path: root.themeTomlPath
    watchChanges: true
    printErrors: false
    onLoaded: root.parseToml(text())
    onFileChanged: reload()
  }
}
