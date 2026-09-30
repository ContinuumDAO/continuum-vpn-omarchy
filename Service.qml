import QtQuick
import Quickshell
import Quickshell.Io

// Profiles live in NetworkManager. This item only talks to backend.sh.
Item {
  id: root

  property var settings: ({})
  readonly property string backendPath: String(Qt.resolvedUrl("backend.sh")).replace(/^file:\/\//, "")

  property var profiles: []
  property string lastIface: ""
  property string actionStatus: ""
  property string lastError: ""
  property string actionRejection: ""
  readonly property bool busy: controlProcess.running || pickerProcess.running
  readonly property bool active: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) return true
    }
    return false
  }
  readonly property string activeLabel: {
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].active) return profileCaption(profiles[i])
    }
    return ""
  }

  function profileCaption(profile) {
    var code = profile && profile.countryCode ? String(profile.countryCode) : ""
    if (code === "") return profile ? String(profile.label || "") : ""
    var flag = profile.countryFlag ? String(profile.countryFlag) : ""
    return (flag !== "" ? flag + " " : "") + code + "  " + String(profile.label || "")
  }
  readonly property string statusText: active ? "VPN: " + activeLabel : "VPN disconnected"

  function reject(reason) {
    actionRejection = String(reason)
    lastError = actionRejection
    return false
  }

  function refresh() {
    if (statusProcess.running) {
      actionRejection = "a refresh is already running"
      return false
    }
    actionRejection = ""
    statusProcess.running = true
    return true
  }

  function applyList(text) {
    var parsed
    try {
      parsed = JSON.parse(String(text || "[]"))
    } catch (e) {
      lastError = "Could not read profiles"
      return
    }
    if (!Array.isArray(parsed)) parsed = []
    profiles = parsed
    var stillThere = false
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].iface === lastIface) stillThere = true
    }
    if (!stillThere) lastIface = profiles.length > 0 ? profiles[0].iface : ""
    for (var j = 0; j < profiles.length; j++) {
      if (profiles[j].active) lastIface = profiles[j].iface
    }
  }

  function run(args) {
    if (controlProcess.running) return reject("already working")
    actionRejection = ""
    lastError = ""
    actionStatus = "Working…"
    controlProcess.command = ["bash", backendPath].concat(args)
    controlProcess.running = true
    return true
  }

  function connectTo(iface) {
    return run(["up", iface])
  }

  function disconnect(iface) {
    return run(["down", iface])
  }

  function toggle() {
    var target = lastIface
    if (target === "" && profiles.length > 0) target = profiles[0].iface
    if (target === "") return reject("import a profile first")
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].iface === target && profiles[i].active) return disconnect(target)
    }
    return connectTo(target)
  }

  function importPick() {
    if (pickerProcess.running) return reject("a file picker is already open")
    actionRejection = ""
    lastError = ""
    pickerProcess.running = true
    return true
  }

  function importPaste() {
    return run(["import-paste"])
  }

  Component.onCompleted: refresh()

  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: ["bash", root.backendPath, "list"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyList(statusStdout.text)
      else root.lastError = String(statusStderr.text || "Could not list profiles").trim()
    }
  }

  Process {
    id: controlProcess
    running: false
    command: ["bash", root.backendPath, "list"]
    stdout: StdioCollector { id: controlStdout; waitForEnd: true }
    stderr: StdioCollector { id: controlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) root.lastError = String(controlStderr.text || "Action failed").trim()
      root.refresh()
    }
  }

  Process {
    id: pickerProcess
    running: false
    command: ["bash", root.backendPath, "import-pick"]
    stderr: StdioCollector { id: pickerStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = String(pickerStderr.text || "Import failed").trim()
      root.refresh()
    }
  }
}
