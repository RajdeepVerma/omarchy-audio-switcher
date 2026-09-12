import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Bottom-center toast for the audio-switcher plugin. Summoned by the service
// with an { icon, title, body } payload; auto-hides after a couple of seconds.
Item {
  id: root

  property bool opened: false
  property string icon: ""
  property string title: ""
  property string body: ""

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      icon = p.icon || ""
      title = p.title || ""
      body = p.body || ""
    } catch (e) {
      icon = ""
      title = ""
      body = ""
    }
    opened = true
    hideTimer.restart()
  }

  function close() { opened = false }

  Timer {
    id: hideTimer
    interval: 2000
    repeat: false
    onTriggered: root.opened = false
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "io.github.solkkku.audio-switcher-toast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: card
      width: contentRow.implicitWidth + Style.space(32) + card.borderLeft + card.borderRight
      height: contentRow.implicitHeight + Style.space(24) + card.borderTop + card.borderBottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(67)
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Style.space(12)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.icon
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          visible: root.icon !== ""
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: root.title
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
            visible: root.title !== ""
            elide: Text.ElideRight
            width: Math.min(implicitWidth, Style.space(240))
          }

          Text {
            textFormat: Text.PlainText
            text: root.body
            color: Qt.darker(Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            visible: root.body !== ""
            elide: Text.ElideRight
            width: Math.min(implicitWidth, Style.space(240))
          }
        }
      }
    }
  }
}
