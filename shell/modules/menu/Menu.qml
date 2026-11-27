import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Kaye OS Omarchy-Style Menu Manager (Super+Space, Super+Alt+Space, Super+K).
// Thin QML overlay — all JSONC parsing, .desktop scanning, and fuzzy search
// are handled by the Rust `kaye` binary via `--json`.
Scope {
  id: root

  property bool open: false
  property string mode: "menu" // "menu" | "keybindings"
  property string currentRoute: "root"
  property var routeStack: []
  property string searchQuery: ""
  property var items: []
  property int selectedIndex: 0

  function openMenu(route) {
    root.mode = "menu"
    root.currentRoute = route || "root"
    root.routeStack = []
    root.searchQuery = ""
    root.selectedIndex = 0
    root.open = true
    root.fetchItems()
  }

  function openKeybindings() {
    root.mode = "keybindings"
    root.searchQuery = ""
    root.selectedIndex = 0
    root.open = true
    root.fetchItems()
  }

  function closeMenu() {
    root.open = false
    root.searchQuery = ""
  }

  function fetchItems() {
    if (queryProc.running) queryProc.running = false
    if (root.mode === "keybindings") {
      queryProc.command = ["kaye", "menu", "keybindings", "--json"]
    } else if (root.currentRoute === "apps") {
      queryProc.command = root.searchQuery.trim() !== ""
        ? ["kaye", "menu", "apps", "--search", root.searchQuery, "--json"]
        : ["kaye", "menu", "apps", "--json"]
    } else {
      queryProc.command = root.searchQuery.trim() !== ""
        ? ["kaye", "menu", "query", root.currentRoute, "--search", root.searchQuery, "--json"]
        : ["kaye", "menu", "query", root.currentRoute, "--json"]
    }
    queryProc.running = true
  }

  function activateSelected() {
    if (root.mode === "keybindings") return
    if (root.selectedIndex < 0 || root.selectedIndex >= root.items.length) return
    var item = root.items[root.selectedIndex]
    if (!item) return

    if (item.kind === "submenu") {
      var nextStack = root.routeStack.slice()
      nextStack.push(root.currentRoute)
      root.routeStack = nextStack
      root.currentRoute = item.id
      root.searchQuery = ""
      root.selectedIndex = 0
      root.fetchItems()
    } else if (item.kind === "provider" && item.provider) {
      var pStack = root.routeStack.slice()
      pStack.push(root.currentRoute)
      root.routeStack = pStack
      root.currentRoute = item.provider === "apps" ? "apps" : item.id
      root.searchQuery = ""
      root.selectedIndex = 0
      root.fetchItems()
    } else if (item.action) {
      var cmd = item.kind === "app" ? ("uwsm app -- " + item.action) : item.action
      root.closeMenu()
      Quickshell.execDetached(["bash", "-lc", cmd])
    }
  }

  function goBack() {
    if (root.routeStack.length === 0) {
      root.closeMenu()
      return
    }
    var nextStack = root.routeStack.slice()
    root.currentRoute = nextStack.pop()
    root.routeStack = nextStack
    root.searchQuery = ""
    root.selectedIndex = 0
    root.fetchItems()
  }

  IpcHandler {
    target: "menu"
    function toggle(route: string): void {
      if (root.open && root.mode === "menu" && root.currentRoute === (route || "root")) root.closeMenu()
      else root.openMenu(route || "root")
    }
    function open(route: string): void {
      root.openMenu(route || "root")
    }
    function keybindings(): void {
      if (root.open && root.mode === "keybindings") root.closeMenu()
      else root.openKeybindings()
    }
    function close(): void {
      root.closeMenu()
    }
  }

  Process {
    id: queryProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "[]")
          if (root.mode === "keybindings" && root.searchQuery.trim() !== "") {
            var q = root.searchQuery.toLowerCase()
            parsed = parsed.filter(function(r) {
              return (r.keys + " " + r.description + " " + r.command).toLowerCase().indexOf(q) !== -1
            })
          }
          root.items = parsed
          root.selectedIndex = parsed.length > 0 ? 0 : -1
        } catch (e) {
          console.warn("kaye-menu: failed to parse JSON:", e)
          root.items = []
        }
      }
    }
  }

  PanelWindow {
    id: menuWindow
    visible: root.open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "kaye-menu"
    WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    // Dimmed click-outside backdrop
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.35)

      MouseArea {
        anchors.fill: parent
        onClicked: root.closeMenu()
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: 520
      height: Math.min(540, 108 + Math.max(1, Math.min(root.items.length, 10)) * 40)
      radius: Style.radius + 2
      color: Commons.Color.darkBackground
      border.width: 1
      border.color: Commons.Color.accent

      // Prevent backdrop clicks inside card
      MouseArea { anchors.fill: parent }

      Column {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 10

        // Header + Search Box
        Rectangle {
          width: parent.width
          height: 40
          radius: Style.radiusSmall
          color: Commons.Color.background
          border.width: 1
          border.color: Commons.Color.lighterBackground

          Row {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 8

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "keybindings" ? "" : (root.currentRoute === "apps" ? "󰀻" : "󰣇")
              textFormat: Text.PlainText
              color: Commons.Color.accent
              font.family: Style.fontFamily
              font.pixelSize: 15
            }

            TextInput {
              id: searchBox
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 36
              color: Commons.Color.foreground
              font.family: Style.fontFamily
              font.pixelSize: Style.fontSizeTitle
              focus: root.open
              text: root.searchQuery

              onTextEdited: {
                root.searchQuery = text
                root.fetchItems()
              }

              Keys.onEscapePressed: root.closeMenu()
              Keys.onDownPressed: if (root.items.length > 0) root.selectedIndex = (root.selectedIndex + 1) % root.items.length
              Keys.onUpPressed: if (root.items.length > 0) root.selectedIndex = (root.selectedIndex - 1 + root.items.length) % root.items.length
              Keys.onReturnPressed: root.activateSelected()
              Keys.onEnterPressed: root.activateSelected()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Backspace && text === "") {
                  root.goBack()
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_J) {
                  if (root.items.length > 0) root.selectedIndex = (root.selectedIndex + 1) % root.items.length
                  event.accepted = true
                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_K) {
                  if (root.items.length > 0) root.selectedIndex = (root.selectedIndex - 1 + root.items.length) % root.items.length
                  event.accepted = true
                }
              }

              Text {
                visible: searchBox.text === ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.mode === "keybindings"
                  ? "Search keybindings..."
                  : (root.currentRoute === "root" ? "Search Kaye menu & apps..." : ("Search " + root.currentRoute + "..."))
                textFormat: Text.PlainText
                color: Commons.Color.subtext
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSizeBody
              }
            }
          }
        }

        // Result List
        ListView {
          id: listView
          width: parent.width
          height: parent.height - 54
          clip: true
          model: root.items
          currentIndex: root.selectedIndex
          spacing: 2

          delegate: Rectangle {
            required property var modelData
            required property int index

            width: listView.width
            height: 38
            radius: Style.radiusSmall
            color: index === root.selectedIndex ? Commons.Color.selection : "transparent"

            Row {
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              spacing: 10

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.mode === "keybindings" ? String(modelData.keys || "") : String(modelData.icon || "•")
                textFormat: Text.PlainText
                color: index === root.selectedIndex ? Commons.Color.accent : Commons.Color.subtext
                font.family: Style.fontFamily
                font.pixelSize: root.mode === "keybindings" ? Style.fontSizeSmall : 14
                width: root.mode === "keybindings" ? 170 : 20
                elide: Text.ElideRight
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.mode === "keybindings" ? String(modelData.description || "") : String(modelData.label || "")
                textFormat: Text.PlainText
                color: Commons.Color.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.fontSizeBody
                width: parent.width - (root.mode === "keybindings" ? 190 : 120)
                elide: Text.ElideRight
              }

              Text {
                visible: root.mode !== "keybindings"
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.checked ? "✓" : (modelData.kind === "submenu" || modelData.kind === "provider" ? "›" : "")
                textFormat: Text.PlainText
                color: modelData.checked ? Commons.Color.green : Commons.Color.subtext
                font.family: Style.fontFamily
                font.pixelSize: 14
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onClicked: {
                root.selectedIndex = index
                root.activateSelected()
              }
            }
          }
        }
      }
    }
  }
}
