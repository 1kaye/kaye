import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// Kaye OS Lock Screen (WlSessionLock + PAM) featuring the KAYE logo.
Scope {
  id: root

  property bool locked: false
  property string statusText: ""
  property string passwordBuffer: ""

  IpcHandler {
    target: "lock"
    function open(): void {
      root.passwordBuffer = ""
      root.statusText = ""
      root.locked = true
    }
  }

  PamContext {
    id: pam
    config: "login"

    onPamMessage: {
      if (pam.responseRequired) {
        pam.respond(root.passwordBuffer)
        root.passwordBuffer = ""
      }
    }

    onCompleted: function(result) {
      if (result === PamResult.Success) {
        root.locked = false
        root.statusText = ""
      } else {
        root.statusText = "Wrong password"
      }
    }
  }

  WlSessionLock {
    id: sessionLock
    locked: root.locked

    WlSessionLockSurface {
      color: Commons.Color.darkBackground

      Image {
        anchors.fill: parent
        source: "file://" + Commons.Color.backgroundPath + "?r=" + Commons.Color.revision
        fillMode: Image.PreserveAspectCrop
        opacity: 0.25
      }

      Column {
        anchors.centerIn: parent
        spacing: 20

        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          source: "file://" + Commons.Color.logoSvgPath
          sourceSize.width: 280
          sourceSize.height: 70
          width: 280
          height: 70
          fillMode: Image.PreserveAspectFit
        }

        Text {
          id: lockClock
          anchors.horizontalCenter: parent.horizontalCenter
          text: Qt.formatDateTime(new Date(), "HH:mm")
          textFormat: Text.PlainText
          color: Commons.Color.foreground
          font.family: Style.fontFamily
          font.pixelSize: 42
          font.bold: true

          Timer {
            interval: 1000
            running: root.locked
            repeat: true
            onTriggered: lockClock.text = Qt.formatDateTime(new Date(), "HH:mm")
          }
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: 280
          height: 40
          radius: Style.radius
          color: Commons.Color.background
          border.width: 1
          border.color: Commons.Color.accent

          TextInput {
            id: passInput
            anchors.fill: parent
            anchors.margins: 10
            echoMode: TextInput.Password
            color: Commons.Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontSizeBody
            verticalAlignment: TextInput.AlignVCenter
            focus: root.locked

            Keys.onReturnPressed: {
              if (!text) return
              root.passwordBuffer = text
              text = ""
              root.statusText = "Unlocking..."
              pam.start()
            }
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.statusText !== ""
          text: root.statusText
          textFormat: Text.PlainText
          color: root.statusText === "Wrong password" ? Commons.Color.red : Commons.Color.subtext
          font.family: Style.fontFamily
          font.pixelSize: Style.fontSizeSmall
        }
      }
    }
  }
}
