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
  property string pendingDelete: ""
  property string pendingDeleteLabel: ""

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

  // The bar hides a slot whose item reports no size. The button is anchored
  // to fill this item, so the item has to copy the button's own size or the
  // icon shows for one layout pass and then disappears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Service { id: vpn }

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
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

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
            meta: ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: 1
            iconComponent: Component {
              Image {
                source: Qt.resolvedUrl("logo.png")
                sourceSize.width: 256
                sourceSize.height: 256
                width: Style.font.display
                height: Style.font.display
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
              }
            }
            trailingControl: Component {
              Rectangle {
                id: statusBadge
                readonly property string caption: vpn.active ? ("Connected to " + vpn.activeLabel) : "Disconnected"
                implicitWidth: statusText.implicitWidth + Style.space(28)
                implicitHeight: Math.max(statusText.implicitHeight + Style.space(12), Style.space(32))
                radius: height / 2
                color: vpn.active ? "#1e8e3e" : "#c5221f"
                opacity: vpn.profiles.length > 0 && !vpn.busy ? 1 : 0.55
                Text {
                  id: statusText
                  anchors.centerIn: parent
                  text: statusBadge.caption
                  color: "#ffffff"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: vpn.profiles.length > 0 && !vpn.busy
                  cursorShape: Qt.PointingHandCursor
                  onClicked: vpn.toggle()
                }
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
            spacing: Style.space(8)
            visible: vpn.profiles.length > 0

            RowLayout {
              width: parent.width
              visible: root.pendingDelete !== ""
              spacing: Style.space(8)
              Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "Delete " + root.pendingDeleteLabel + "?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              PanelActionButton {
                iconText: "No"
                tooltipText: "Keep this VPN"
                foreground: root.dim
                hoverColor: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.pendingDelete = ""
              }
              PanelActionButton {
                iconText: "Yes"
                tooltipText: "Delete this VPN"
                foreground: root.urgent
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                enabled: !vpn.busy
                onClicked: {
                  var iface = root.pendingDelete
                  root.pendingDelete = ""
                  vpn.remove(iface)
                }
              }
            }

            Repeater {
              model: vpn.profiles
              Rectangle {
                id: profileCard
                required property var modelData
                required property int index
                width: parent.width
                implicitHeight: card.implicitHeight + Style.space(16)
                color: "transparent"
                border.width: index === root.configIndex ? 1 : 0
                border.color: root.dim
                radius: Style.space(4)

                RowLayout {
                  id: card
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  spacing: Style.space(10)

                  Text {
                    text: modelData.countryFlag ? modelData.countryFlag : "—"
                    color: root.foreground
                    font.pixelSize: Style.font.display
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: Style.space(36)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)
                    Repeater {
                      model: [
                        { name: "Name", value: vpn.shown(modelData.label) },
                        { name: "Country", value: vpn.shown(modelData.countryCode) },
                        { name: "Obfuscation", value: vpn.obfuscationLabel(modelData) },
                        { name: "Ad blocking", value: vpn.shown(modelData.adBlock) },
                        { name: "Rate limit", value: vpn.shown(modelData.rateLimit) },
                        { name: "Endpoint", value: vpn.shown(modelData.endpoint) }
                      ]
                      RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Style.space(8)
                        Text {
                          text: modelData.name
                          color: root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          Layout.preferredWidth: Style.space(92)
                        }
                        Text {
                          text: modelData.value
                          color: profileCard.index === root.configIndex ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                          Layout.fillWidth: true
                        }
                      }
                    }
                  }

                  ColumnLayout {
                    spacing: Style.space(6)
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                      implicitWidth: Style.space(64)
                      implicitHeight: Style.space(28)
                      radius: Style.space(4)
                      color: "#1e8e3e"
                      border.width: modelData.active ? 2 : 0
                      border.color: "#ffffff"
                      Text {
                        anchors.centerIn: parent
                        text: "ON"
                        color: "#ffffff"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !vpn.busy && !modelData.active
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: vpn.connectTo(modelData.iface)
                      }
                    }

                    Rectangle {
                      implicitWidth: Style.space(64)
                      implicitHeight: Style.space(28)
                      radius: Style.space(4)
                      color: "#c5221f"
                      border.width: modelData.active ? 0 : 2
                      border.color: "#ffffff"
                      Text {
                        anchors.centerIn: parent
                        text: "OFF"
                        color: "#ffffff"
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      MouseArea {
                        anchors.fill: parent
                        enabled: !vpn.busy && modelData.active
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: vpn.disconnect(modelData.iface)
                      }
                    }
                  }

                  PanelActionButton {
                    iconText: "⌫"
                    tooltipText: "Delete"
                    foreground: root.dim
                    hoverColor: root.urgent
                    fontFamily: root.fontFamily
                    enabled: !vpn.busy
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: {
                      root.pendingDelete = modelData.iface
                      root.pendingDeleteLabel = modelData.label || modelData.iface
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
}
