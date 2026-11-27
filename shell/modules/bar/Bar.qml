import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.SystemTray
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Kaye OS Multi-Monitor Bar with rock-solid tooltips on EVERY widget.
// Avoids Qt 6 HoverHandler-over-MouseArea blocking, uses ancestor-walk window matching,
// and guards fractional-scaling PopupWindow with a 120ms reveal fallback timer.
Scope {
  id: root

  readonly property int barHeight: Config.barHeight
  property var tooltipTarget: null
  property string tooltipText: ""
  property bool tooltipShown: false

  // Live indicator & hardware states
  property bool stayAwake: false
  property bool nightLight: false
  property bool dnd: false
  property int volumePct: 50
  property bool audioMuted: false
  property string netStatus: "offline"
  property string netSsid: ""
  property bool btPowered: false
  property int batteryPct: -1
  property bool batteryCharging: false
  property string clockText: Qt.formatDateTime(new Date(), "ddd HH:mm")

  function showTooltip(target, text) {
    if (!target || !text) {
      if (target && tooltipTarget === target) hideTooltip(target)
      return
    }
    tooltipTarget = target
    tooltipText = String(text)
    if (tooltipShown || tooltipWarmTimer.running) {
      tooltipShown = true
    } else {
      tooltipTimer.restart()
    }
  }

  function hideTooltip(target) {
    if (target && tooltipTarget !== target) return
    tooltipTimer.stop()
    if (tooltipShown) tooltipWarmTimer.restart()
    tooltipShown = false
    tooltipTarget = null
    tooltipText = ""
  }

  // Ancestor walk works reliably for every QML Item even if QsWindow is absent.
  function targetBelongsToWindow(target, window) {
    if (!target || !window) return false
    var rootItem = window.contentItem
    var item = target
    while (item) {
      if (item === rootItem) return true
      item = item.parent
    }
    return false
  }

  function runDetached(cmd) {
    Quickshell.execDetached(["bash", "-lc", cmd])
  }

  Timer {
    id: tooltipTimer
    interval: 220
    onTriggered: {
      if (root.tooltipTarget && root.tooltipTarget.tooltipHovered) root.tooltipShown = true
      else root.hideTooltip(null)
    }
  }

  Timer {
    id: tooltipWarmTimer
    interval: 400
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.clockText = Qt.formatDateTime(new Date(), "ddd HH:mm")
  }

  // Periodic lightweight status probe (toggles, audio, network, bluetooth, battery).
  Process {
    id: statusProbe
    running: true
    command: [
      "bash", "-c",
      "tdir=\"$HOME/.local/state/kaye/toggles\"; " +
      "sa=$(test -f \"$tdir/stay-awake\" && echo 1 || echo 0); " +
      "nl=$(test -f \"$tdir/nightlight\" && echo 1 || echo 0); " +
      "dn=$(test -f \"$tdir/dnd\" && echo 1 || echo 0); " +
      "vol=$(pamixer --get-volume 2>/dev/null || echo 0); " +
      "mut=$(pamixer --get-mute 2>/dev/null || echo false); " +
      "ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1==\"yes\"{print $2; exit}'); " +
      "eth=$(nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q '^ethernet:connected' && echo 1 || echo 0); " +
      "bt=$(bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && echo 1 || echo 0); " +
      "bat=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n1); " +
      "bst=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -n1); " +
      "printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' \"$sa\" \"$nl\" \"$dn\" \"$vol\" \"$mut\" \"$ssid\" \"$eth\" \"$bt\" \"${bat:--1}\" \"${bst:-Unknown}\""
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text).trim().split("|")
        if (parts.length < 10) return
        root.stayAwake = parts[0] === "1"
        root.nightLight = parts[1] === "1"
        root.dnd = parts[2] === "1"
        root.volumePct = Number(parts[3]) || 0
        root.audioMuted = parts[4] === "true"
        root.netSsid = parts[5] || ""
        root.netStatus = parts[6] === "1" ? "ethernet" : (root.netSsid !== "" ? "wifi" : "offline")
        root.btPowered = parts[7] === "1"
        root.batteryPct = Number(parts[8])
        root.batteryCharging = parts[9] === "Charging" || parts[9] === "Full"
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: if (!statusProbe.running) statusProbe.running = true
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: barWindow
      required property var modelData
      screen: modelData

      visible: !Config.barHidden
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.namespace: "kaye-bar"
      implicitHeight: root.barHeight
      color: "transparent"

      anchors {
        top: Config.barPosition !== "bottom"
        bottom: Config.barPosition === "bottom"
        left: true
        right: true
      }

      Rectangle {
        anchors.fill: parent
        color: Config.barBackground === "none"
          ? "transparent"
          : (Config.barBackground === "glassy"
            ? Qt.rgba(Commons.Color.barBackground.r, Commons.Color.barBackground.g, Commons.Color.barBackground.b, 0.72)
            : Commons.Color.barBackground)

        // Subtle bottom hairline border
        Rectangle {
          visible: Config.barBackground !== "none"
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: Config.barPosition !== "bottom" ? parent.bottom : undefined
          anchors.top: Config.barPosition === "bottom" ? parent.top : undefined
          height: 1
          color: Commons.Color.lighterBackground
        }

        // LEFT SECTION: Kaye Menu + Workspaces
        Row {
          anchors.left: parent.left
          anchors.leftMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2

          WidgetButton {
            bar: root
            text: "󰣇"
            fontSize: 15
            textColor: Commons.Color.accent
            tooltipText: "Kaye Menu (Super+Space)"
            onPressed: root.runDetached("qs -p \"$KAYE_PATH/shell\" ipc call menu toggle root")
          }

          Repeater {
            model: 9

            WidgetButton {
              required property int index
              readonly property int wsId: index + 1
              readonly property var wsObj: Hyprland.workspaces.values.find(function(w) { return w.id === wsId }) || null
              readonly property bool isFocused: Hyprland.focusedWorkspace && Hyprland.focusedWorkspace.id === wsId

              visible: isFocused || wsObj !== null || wsId <= 3
              bar: root
              text: String(wsId)
              active: isFocused
              dimmed: !isFocused && wsObj === null
              horizontalPadding: 6
              tooltipText: "Workspace " + wsId
              onPressed: Hyprland.dispatch("workspace " + wsId)
            }
          }
        }

        // CENTER SECTION: Indicators (Stay Awake, Night Light, DND) + Clock
        Row {
          anchors.centerIn: parent
          spacing: 2

          WidgetButton {
            bar: root
            text: ""
            active: root.stayAwake
            dimmed: !root.stayAwake
            tooltipText: root.stayAwake ? "Stay Awake: ON (Click to allow sleep)" : "Stay Awake: OFF (Click to enable)"
            onPressed: {
              root.stayAwake = !root.stayAwake
              root.runDetached("kaye toggle stay-awake")
            }
          }

          WidgetButton {
            bar: root
            text: "󰔎"
            active: root.nightLight
            dimmed: !root.nightLight
            tooltipText: root.nightLight ? "Night Light: ON (Click for daylight)" : "Night Light: OFF (Click to enable)"
            onPressed: {
              root.nightLight = !root.nightLight
              root.runDetached("kaye toggle nightlight")
            }
          }

          WidgetButton {
            bar: root
            text: "󰂛"
            active: root.dnd
            dimmed: !root.dnd
            tooltipText: root.dnd ? "Do Not Disturb: ON (Click to allow notifications)" : "Do Not Disturb: OFF (Click to silence)"
            onPressed: {
              root.dnd = !root.dnd
              root.runDetached("kaye toggle dnd")
            }
          }

          WidgetButton {
            bar: root
            text: root.clockText
            fontSize: Style.fontSizeClock
            tooltipText: "Clock · Click to open Kaye Menu"
            onPressed: root.runDetached("qs -p \"$KAYE_PATH/shell\" ipc call menu toggle root")
          }
        }

        // RIGHT SECTION: Tray + Audio + Network + Bluetooth + Battery + Power
        Row {
          anchors.right: parent.right
          anchors.rightMargin: 6
          anchors.verticalCenter: parent.verticalCenter
          spacing: 2

          Repeater {
            model: SystemTray.items

            WidgetButton {
              required property var modelData
              bar: root
              text: "●"
              textColor: Commons.Color.cyan
              tooltipText: String(modelData.tooltipTitle || modelData.title || modelData.id || "Tray App")
              onPressed: modelData.activate()
            }
          }

          WidgetButton {
            bar: root
            text: root.audioMuted ? "󰝟" : ("󰕾 " + root.volumePct + "%")
            dimmed: root.audioMuted
            tooltipText: root.audioMuted ? "Audio Muted (Click to unmute, scroll for volume)" : ("Volume " + root.volumePct + "% (Click mute, scroll adjust)")
            onPressed: function(btn) {
              if (btn === Qt.RightButton) root.runDetached("foot -e wpctl status")
              else {
                root.runDetached("pamixer -t")
                statusProbe.running = true
              }
            }
            onWheelDelta: function(delta) {
              root.runDetached(delta > 0 ? "pamixer -i 5" : "pamixer -d 5")
              statusProbe.running = true
            }
          }

          WidgetButton {
            bar: root
            text: root.netStatus === "ethernet" ? "󰈀" : (root.netStatus === "wifi" ? "󰤨" : "󰤭")
            dimmed: root.netStatus === "offline"
            tooltipText: root.netStatus === "ethernet" ? "Ethernet Connected" : (root.netStatus === "wifi" ? ("Wi-Fi: " + root.netSsid) : "Network Offline (Click for nmtui)")
            onPressed: root.runDetached("foot -e nmtui")
          }

          WidgetButton {
            bar: root
            text: root.btPowered ? "󰂯" : "󰂲"
            dimmed: !root.btPowered
            tooltipText: root.btPowered ? "Bluetooth: ON (Click to manage)" : "Bluetooth: OFF (Click to manage)"
            onPressed: root.runDetached("foot -e bluetoothctl")
          }

          WidgetButton {
            visible: root.batteryPct >= 0
            bar: root
            text: (root.batteryCharging ? "󰂄 " : "󰁹 ") + root.batteryPct + "%"
            textColor: root.batteryPct <= 15 && !root.batteryCharging ? Commons.Color.barUrgent : Commons.Color.barText
            tooltipText: "Battery " + root.batteryPct + "%" + (root.batteryCharging ? " (Charging)" : "")
            onPressed: root.runDetached("qs -p \"$KAYE_PATH/shell\" ipc call menu toggle system")
          }

          WidgetButton {
            bar: root
            text: ""
            textColor: Commons.Color.barUrgent
            tooltipText: "System & Power Menu"
            onPressed: root.runDetached("qs -p \"$KAYE_PATH/shell\" ipc call menu toggle system")
          }
        }
      }

      // Per-monitor Tooltip PopupWindow with fractional-scale reveal fallback
      PopupWindow {
        id: tooltipWindow
        visible: root.tooltipShown && root.tooltipTarget !== null && root.tooltipText !== "" && root.targetBelongsToWindow(root.tooltipTarget, barWindow)
        color: "transparent"
        implicitWidth: Math.ceil(tooltipBubble.implicitWidth)
        implicitHeight: Math.ceil(tooltipBubble.implicitHeight)

        readonly property bool scaleReady: visible && Math.round(devicePixelRatio * 120) === Math.round(barWindow.devicePixelRatio * 120)
        property bool revealed: false

        onVisibleChanged: if (!visible) revealed = false
        onScaleReadyChanged: if (scaleReady) Qt.callLater(function() {
          if (tooltipWindow.scaleReady) tooltipWindow.revealed = true
        })

        Timer {
          interval: 120
          running: tooltipWindow.visible && !tooltipWindow.revealed
          onTriggered: if (tooltipWindow.visible) tooltipWindow.revealed = true
        }

        anchor {
          window: barWindow
          adjustment: PopupAdjustment.Slide
          edges: Edges.Top | Edges.Left
          gravity: Edges.Bottom | Edges.Right
          rect.width: 1
          rect.height: 1

          onAnchoring: {
            var target = root.tooltipTarget
            if (!root.targetBelongsToWindow(target, barWindow)) return
            var localX = target.width / 2 - tooltipWindow.implicitWidth / 2
            var localY = Config.barPosition === "bottom" ? (-tooltipWindow.implicitHeight - 6) : (target.height + 6)
            var pt = barWindow.contentItem.mapFromItem(target, localX, localY)
            tooltipWindow.anchor.rect.x = Math.round(pt.x)
            tooltipWindow.anchor.rect.y = Math.round(pt.y)
          }
        }

        Rectangle {
          id: tooltipBubble
          opacity: tooltipWindow.revealed ? 1 : 0
          implicitWidth: tipText.implicitWidth + 18
          implicitHeight: tipText.implicitHeight + 10
          radius: Style.radiusSmall
          color: Commons.Color.tooltipBackground
          border.width: 1
          border.color: Commons.Color.tooltipBorder

          Text {
            id: tipText
            anchors.centerIn: parent
            text: root.tooltipText
            textFormat: Text.PlainText
            color: Commons.Color.tooltipText
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSizeSmall
          }
        }
      }
    }
  }
}
