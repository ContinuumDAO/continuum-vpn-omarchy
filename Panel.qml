import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "continuum.vpn"
  ipcTarget: "continuum.vpn"

  property int configIndex: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: vpn.lastError !== ""
    ? urgent
    : (vpn.active ? (bar ? bar.foreground : Color.foreground) : dim)

  function selected() {
    if (vpn.profiles.length === 0) return null
    var index = Math.max(0, Math.min(configIndex, vpn.profiles.length - 1))
    return vpn.profiles[index]
  }

  function activateSelected() {
    var profile = selected()
    if (!profile || vpn.busy) return
    if (profile.active) vpn.disconnect(profile.iface)
    else vpn.connectTo(profile.iface)
  }

  Service { id: vpn }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): string { return vpn.toggle() ? "ok" : "error: " + vpn.actionRejection }
    function refresh(): string { return vpn.refresh() ? "ok" : "error: " + vpn.actionRejection }
    function status(): string { return vpn.statusText }
    function importPick(): string { return vpn.importPick() ? "ok" : "error: " + vpn.actionRejection }
    function importPaste(): string { return vpn.importPaste() ? "ok" : "error: " + vpn.actionRejection }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    foreground: root.barIconColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (vpn.active) {
          var current = null
          for (var i = 0; i < vpn.profiles.length; i++) {
            if (vpn.profiles[i].active) current = vpn.profiles[i]
          }
          if (current) vpn.disconnect(current.iface)
        } else {
          root.open()
        }
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(420))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (vpn.profiles.length === 0 || dy === 0) return
        root.configIndex = Math.max(0, Math.min(vpn.profiles.length - 1, root.configIndex + dy))
      }
      onActivateRequested: root.activateSelected()
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "t" || t === "T") vpn.toggle()
        else if (t === "r" || t === "R") vpn.refresh()
        else if (t === "i" || t === "I") vpn.importPick()
        else if (t === "v" || t === "V") vpn.importPaste()
        else if (t === "d" || t === "D") {
          for (var i = 0; i < vpn.profiles.length; i++) {
            if (vpn.profiles[i].active) vpn.disconnect(vpn.profiles[i].iface)
          }
        }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Continuum VPN"
            meta: vpn.active ? vpn.activeLabel : "Disconnected"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: vpn.active ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰖂"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                visible: vpn.profiles.length > 0
                checked: vpn.active
                busy: vpn.busy
                foreground: root.foreground
                onToggled: vpn.toggle()
              }
            }
          }

          Text {
            visible: vpn.actionStatus !== "" || vpn.lastError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
            color: vpn.lastError !== "" && vpn.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.foreground }

          RowLayout {
            width: parent.width
            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.fillWidth: true
            }
            PanelActionButton {
              iconText: "+"
              tooltipText: "Import a bundle (i)"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              enabled: !vpn.busy
              onClicked: vpn.importPick()
            }
            PanelActionButton {
              iconText: "v"
              tooltipText: "Import from clipboard (v)"
              foreground: root.dim
              hoverColor: root.foreground
              fontFamily: root.fontFamily
              enabled: !vpn.busy
              onClicked: vpn.importPaste()
            }
          }

          Text {
            visible: vpn.profiles.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: "No profiles yet. Download a bundle from the node VPN panel, then import it here."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: vpn.profiles.length > 0
            Repeater {
              model: vpn.profiles
              RowLayout {
                required property var modelData
                required property int index
                width: parent.width
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  text: modelData.label
                  color: index === root.configIndex ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                ToggleSwitch {
                  checked: modelData.active
                  busy: vpn.busy
                  foreground: root.foreground
                  onToggled: {
                    if (modelData.active) vpn.disconnect(modelData.iface)
                    else vpn.connectTo(modelData.iface)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
