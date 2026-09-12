import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Headless service for the audio-switcher plugin. Owns config, switching,
// persistence, and the managed Hyprland binding block. The bar widget (Panel.qml)
// is a thin view over this object, reached via bar.shell.serviceFor(...).
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string moduleName: "io.github.solkkku.audio-switcher"
  readonly property string shellConfigPath: home + "/.config/omarchy/shell.json"
  readonly property string bindingsPath: home + "/.config/hypr/bindings.lua"
  readonly property string defaultCycleHotkey: ""
  readonly property string defaultPreviousHotkey: ""
  readonly property string defaultNotificationPosition: "off"

  // ---------------- config (read from shell.json) ----------------
  property var profiles: []
  property string cycleHotkey: defaultCycleHotkey
  property string previousHotkey: defaultPreviousHotkey
  property string micMuteHotkey: ""
  property string outputMuteHotkey: ""
  property string notificationPosition: defaultNotificationPosition
  property bool configLoaded: false

  // ---------------- persistence ----------------
  property bool persistedLoaded: false

  // ---------------- live pipewire state ----------------
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property var defaultSource: Pipewire.defaultAudioSource
  readonly property string defaultSinkName: defaultSink ? String(defaultSink.name || "") : ""

  // Bind the nodes so their audio interface is live and writes (volume/mute)
  // propagate back to PipeWire.
  PwObjectTracker {
    objects: root.nodes
  }
  readonly property string currentProfileName: {
    var i = currentProfileIndex()
    return (i >= 0 && profiles[i]) ? String(profiles[i].name || "") : ""
  }
  property string lastResult: "ok"

  // ---------------- device option lists (reactive) ----------------
  readonly property var outputOptions: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream)
        list.push({ value: String(n.name || ""), label: deviceLabel(n) })
    }
    return list
  }

  readonly property var inputOptions: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || !isAudioSource(n)) continue
      var name = String(n.name || "")
      if (name === "quickshell") continue
      if (name.indexOf(".monitor") !== -1) continue
      list.push({ value: name, label: deviceLabel(n) })
    }
    return list
  }

  PersistentProperties {
    id: persisted
    reloadableId: "io.github.solkkku.audio-switcher"
    property string lastProfile: ""
    onLoaded: {
      root.persistedLoaded = true
      root.applyPersistedProfile()
    }
  }

  FileView {
    id: shellConfigFile
    path: root.shellConfigPath
    watchChanges: true
    printErrors: false
    onLoaded: root.readConfig()
    onLoadFailed: root.readConfig()
    onFileChanged: reload()
  }

  FileView {
    id: bindingsFile
    path: root.bindingsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.bindingsLoaded = true
      root.writeBindingsNow()
    }
    onLoadFailed: root.bindingsLoaded = true
  }
  property bool bindingsLoaded: false
  property string pendingBindingsText: ""

  function deviceLabel(node) {
    var label = String(node.nickname || node.description || node.name || "")
    label = label.replace(/^sof-soundwire\s+/i, "")
    label = label.replace(/^built-?in audio\s+/i, "")
    label = label.replace(/\s+Output$/i, "")
    label = label.replace(/\s+Input$/i, "")
    return label
  }

  function isAudioSource(node) {
    if (!node) return false
    if (node.audio) return true
    var mediaClass = String(node.type || "")
    return mediaClass.indexOf("Audio/Source") !== -1
      || mediaClass.indexOf("AudioSource") !== -1
      || mediaClass.indexOf("Source") !== -1
  }

  // ---------------- config read ----------------
  function readConfig() {
    var text = String(shellConfigFile.text() || "")
    if (!text.trim()) return
    var entry = null
    try {
      entry = findEntry(JSON.parse(text))
    } catch (e) {
      console.warn("audio-switcher: shell.json parse failed: " + e)
      return
    }
    if (!entry) {
      profiles = []
      cycleHotkey = defaultCycleHotkey
      previousHotkey = defaultPreviousHotkey
      micMuteHotkey = ""
      outputMuteHotkey = ""
      notificationPosition = defaultNotificationPosition
    } else {
      profiles = Array.isArray(entry.profiles) ? entry.profiles.map(sanitizeProfile) : []
      cycleHotkey = String(entry.cycleHotkey || "").trim() || defaultCycleHotkey
      previousHotkey = String(entry.previousHotkey || "").trim() || defaultPreviousHotkey
      micMuteHotkey = String(entry.micMuteHotkey || "").trim()
      outputMuteHotkey = String(entry.outputMuteHotkey || "").trim()
      notificationPosition = String(entry.notificationPosition || "").trim() || defaultNotificationPosition
    }
    configLoaded = true
    syncBindings()
  }

  function findEntry(parsed) {
    if (!parsed) return null
    var sections = ["left", "center", "right"]
    if (parsed.bar && parsed.bar.layout) {
      for (var s = 0; s < sections.length; s++) {
        var entries = parsed.bar.layout[sections[s]]
        if (!Array.isArray(entries)) continue
        for (var i = 0; i < entries.length; i++)
          if (entries[i] && String(entries[i].id) === moduleName) return entries[i]
      }
    }
    if (Array.isArray(parsed.plugins)) {
      for (var j = 0; j < parsed.plugins.length; j++)
        if (parsed.plugins[j] && String(parsed.plugins[j].id) === moduleName) return parsed.plugins[j]
    }
    return null
  }

  function sanitizeProfile(p) {
    p = p || {}
    return {
      name: String(p.name || "").trim(),
      output: String(p.output || "").trim(),
      input: String(p.input || "").trim(),
      hotkey: String(p.hotkey || "").trim(),
      icon: String(p.icon || "")
    }
  }

  // ---------------- device lookup / switching ----------------
  function findSink(name) {
    if (!name) return null
    var target = String(name)
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream) continue
      if (String(n.name || "") === target) return n
    }
    var lower = target.toLowerCase()
    for (var j = 0; j < nodes.length; j++) {
      var m = nodes[j]
      if (!m || !m.isSink || m.isStream) continue
      if (String(m.name || "").toLowerCase().indexOf(lower) !== -1) return m
    }
    return null
  }

  function findSource(name) {
    if (!name) return null
    var target = String(name)
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream || !isAudioSource(n)) continue
      if (String(n.name || "") === target) return n
    }
    var lower = target.toLowerCase()
    for (var j = 0; j < nodes.length; j++) {
      var m = nodes[j]
      if (!m || m.isSink || m.isStream || !isAudioSource(m)) continue
      if (String(m.name || "").toLowerCase().indexOf(lower) !== -1) return m
    }
    return null
  }

  function isInputMuted(name) {
    if (!name) return false
    var src = findSource(name)
    return !!(src && src.audio && src.audio.muted)
  }

  function isOutputMuted(name) {
    if (!name) return false
    var sink = findSink(name)
    return !!(sink && sink.audio && sink.audio.muted)
  }

  function sinkMatches(sinkName, configured) {
    if (!configured || !sinkName) return false
    var c = String(configured).toLowerCase()
    var n = String(sinkName).toLowerCase()
    return n === c || n.indexOf(c) !== -1
  }

  function currentProfileIndex() {
    // Prefer the last-activated profile when its output matches the current
    // sink. Profiles may share an output (and input); matching by sink alone
    // would always resolve to the first such profile, so a click on the second
    // one would highlight the wrong row.
    var last = String(persisted.lastProfile || "")
    if (last) {
      for (var k = 0; k < profiles.length; k++) {
        if (profiles[k].name === last && sinkMatches(defaultSinkName, profiles[k].output))
          return k
      }
    }
    for (var i = 0; i < profiles.length; i++)
      if (sinkMatches(defaultSinkName, profiles[i].output)) return i
    return -1
  }

  function setDefaultSink(node) {
    if (!node) return false
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-output-set-default", String(node.id), String(node.name)])
    return true
  }

  function setDefaultSource(node) {
    if (!node) return false
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["omarchy-audio-input-set-default", String(node.id), String(node.name)])
    return true
  }

  function switchProfile(p) {
    if (!p) {
      lastResult = "unknown"
      return lastResult
    }
    var okOut = setDefaultSink(findSink(p.output))
    var okIn = setDefaultSource(findSource(p.input))
    if (!okOut && !okIn) {
      lastResult = "unavailable"
      return lastResult
    }
    persisted.lastProfile = String(p.name || "")
    lastResult = "ok"
    notifyProfile(p)
    return lastResult
  }

  function notifyProfile(p) {
    var icon = String(p.icon || "󰓃")
    var name = String(p.name || "Unnamed")
    if (notificationPosition === "off") return
    if (notificationPosition === "top-right") {
      Quickshell.execDetached(["omarchy-notification-send", "-g", icon, "-u", "low", "Profile switched", name])
    } else {
      if (shell && typeof shell.summon === "function")
        shell.summon(moduleName, JSON.stringify({ icon: icon, title: "Profile switched", body: name }))
      else
        Quickshell.execDetached(["omarchy-osd", "-i", icon, "-m", name])
    }
  }

  function toggleSourceNode(src) {
    if (!src || !src.audio) {
      lastResult = "unavailable"
      return lastResult
    }
    src.audio.muted = !src.audio.muted
    lastResult = "ok"
    notifyMicMute(src.audio.muted)
    return lastResult
  }

  function toggleMicMute() {
    return toggleSourceNode(sourceForActiveProfile())
  }

  function toggleSourceMute(name) {
    return toggleSourceNode(findSource(name))
  }

  function toggleSinkMute(name) {
    return toggleSinkNode(findSink(name))
  }

  function sourceForActiveProfile() {
    var idx = currentProfileIndex()
    if (idx >= 0 && profiles[idx]) {
      var inputName = String(profiles[idx].input || "")
      if (inputName) {
        var src = findSource(inputName)
        if (src) return src
      }
    }
    return defaultSource
  }

  function notifyMicMute(muted) {
    if (notificationPosition === "off") return
    var icon = muted ? "󰍭" : "󰍬"
    var title = muted ? "Microphone muted" : "Microphone active"
    if (notificationPosition === "top-right") {
      Quickshell.execDetached(["omarchy-notification-send", "-g", icon, "-u", "low", title])
    } else if (shell && typeof shell.summon === "function") {
      shell.summon(moduleName, JSON.stringify({ icon: icon, title: title, body: "" }))
    }
  }

  // Toggle a node's mute and notify. Best-effort: a sink owned by an external
  // software mixer (e.g. GoXLR/OpenXLR) can revert out-of-band mute changes.
  function toggleSinkNode(sink) {
    if (!sink || !sink.audio) {
      lastResult = "unavailable"
      return lastResult
    }
    sink.audio.muted = !sink.audio.muted
    lastResult = "ok"
    notifyOutputMute(sink.audio.muted)
    return lastResult
  }

  function toggleOutputMute() {
    return toggleSinkNode(sinkForActiveProfile())
  }

  function sinkForActiveProfile() {
    var idx = currentProfileIndex()
    if (idx >= 0 && profiles[idx]) {
      var outputName = String(profiles[idx].output || "")
      if (outputName) {
        var sink = findSink(outputName)
        if (sink) return sink
      }
    }
    return defaultSink
  }

  function notifyOutputMute(muted) {
    if (notificationPosition === "off") return
    var icon = muted ? "󰖁" : "󰕾"
    var title = muted ? "Output muted" : "Output active"
    if (notificationPosition === "top-right") {
      Quickshell.execDetached(["omarchy-notification-send", "-g", icon, "-u", "low", title])
    } else if (shell && typeof shell.summon === "function") {
      shell.summon(moduleName, JSON.stringify({ icon: icon, title: title, body: "" }))
    }
  }

  function activate(index) {
    var i = parseInt(index, 10)
    var p = profiles[i]
    if (!p) {
      lastResult = "unknown"
      return lastResult
    }
    return switchProfile(p)
  }

  function next() {
    var n = profiles.length
    if (n === 0) {
      lastResult = "none"
      return lastResult
    }
    var idx = currentProfileIndex()
    var nextIdx = idx === -1 ? 0 : (idx + 1) % n
    return switchProfile(profiles[nextIdx])
  }

  function previous() {
    var n = profiles.length
    if (n === 0) {
      lastResult = "none"
      return lastResult
    }
    var idx = currentProfileIndex()
    var prevIdx = idx === -1 ? n - 1 : (idx - 1 + n) % n
    return switchProfile(profiles[prevIdx])
  }

  function applyPersistedProfile() {
    if (!persistedLoaded || !configLoaded) return
    var last = String(persisted.lastProfile || "")
    if (!last) {
      applyTimer.stop()
      return
    }
    for (var i = 0; i < profiles.length; i++) {
      if (profiles[i].name !== last) continue
      if (currentProfileIndex() === i) {
        applyTimer.stop()
        return
      }
      if (!findSink(profiles[i].output)) return // device not present yet; keep polling
      switchProfile(profiles[i])
      applyTimer.stop()
      return
    }
    applyTimer.stop()
  }

  Timer {
    id: applyTimer
    interval: 4000
    repeat: true
    running: true
    onTriggered: root.applyPersistedProfile()
  }

  // ---------------- config write ----------------
  function writeConfig() {
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(moduleName, {
        cycleHotkey: cycleHotkey,
        previousHotkey: previousHotkey,
        micMuteHotkey: micMuteHotkey,
        outputMuteHotkey: outputMuteHotkey,
        notificationPosition: notificationPosition,
        profiles: profiles
      })
    syncBindings()
  }

  function setCycleHotkey(combo) {
    cycleHotkey = String(combo || "").trim()
    writeConfig()
    return "ok"
  }

  function setPreviousHotkey(combo) {
    previousHotkey = String(combo || "").trim()
    writeConfig()
    return "ok"
  }

  function setMicMuteHotkey(combo) {
    micMuteHotkey = String(combo || "").trim()
    writeConfig()
    return "ok"
  }

  function setOutputMuteHotkey(combo) {
    outputMuteHotkey = String(combo || "").trim()
    writeConfig()
    return "ok"
  }

  function setNotificationPosition(pos) {
    notificationPosition = String(pos || "bottom-center").trim()
    writeConfig()
    return "ok"
  }

  function addProfile(name, output, input, hotkey, icon) {
    var list = profiles.map(cloneProfile)
    list.push({ name: name, output: output, input: input, hotkey: hotkey, icon: icon || "" })
    profiles = list
    writeConfig()
    return "ok"
  }

  function updateProfile(index, name, output, input, hotkey, icon) {
    var i = parseInt(index, 10)
    if (i < 0 || i >= profiles.length) return "unknown"
    var list = profiles.map(cloneProfile)
    list[i] = { name: name, output: output, input: input, hotkey: hotkey, icon: icon || "" }
    profiles = list
    writeConfig()
    return "ok"
  }

  function removeProfile(index) {
    var i = parseInt(index, 10)
    if (i < 0 || i >= profiles.length) return "unknown"
    var list = profiles.map(cloneProfile)
    list.splice(i, 1)
    profiles = list
    writeConfig()
    return "ok"
  }

  function moveProfile(from, to) {
    var f = parseInt(from, 10)
    var t = parseInt(to, 10)
    if (f < 0 || f >= profiles.length || t < 0 || t >= profiles.length) return "unknown"
    var list = profiles.map(cloneProfile)
    var item = list.splice(f, 1)[0]
    list.splice(t, 0, item)
    profiles = list
    writeConfig()
    return "ok"
  }

  function cloneProfile(p) {
    return { name: p.name, output: p.output, input: p.input, hotkey: p.hotkey, icon: p.icon }
  }

  function statusJson() {
    return JSON.stringify({
      currentProfile: currentProfileName,
      defaultSink: defaultSinkName,
      cycleHotkey: cycleHotkey,
      previousHotkey: previousHotkey,
      micMuteHotkey: micMuteHotkey,
      outputMuteHotkey: outputMuteHotkey,
      notificationPosition: notificationPosition,
      profiles: profiles
    })
  }

  // ---------------- hotkey sync (managed block in bindings.lua) ----------------
  function luaString(s) {
    return '"' + String(s || "").replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'
  }

  function buildBindingsBlock() {
    var lines = []
    for (var i = 0; i < profiles.length; i++) {
      var p = profiles[i]
      var key = String(p.hotkey || "").trim()
      if (!key) continue
      lines.push("hl.unbind(" + luaString(key) + ")")
      lines.push("o.bind(" + luaString(key) + ", " + luaString("Profile: " + (p.name || "")) + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher activate " + i) + ", { locked = true })")
    }
    var prev = String(previousHotkey || "").trim()
    if (prev) {
      lines.push("hl.unbind(" + luaString(prev) + ")")
      lines.push("o.bind(" + luaString(prev) + ", " + luaString("Previous audio profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher previous") + ", { locked = true })")
    }
    var cyc = String(cycleHotkey || "").trim()
    if (cyc) {
      lines.push("hl.unbind(" + luaString(cyc) + ")")
      lines.push("o.bind(" + luaString(cyc) + ", " + luaString("Next audio profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher next") + ", { locked = true })")
    }
    var mic = String(micMuteHotkey || "").trim()
    if (mic) {
      lines.push("hl.unbind(" + luaString(mic) + ")")
      lines.push("o.bind(" + luaString(mic) + ", " + luaString("Toggle mic mute for selected profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher toggleMicMute") + ", { locked = true })")
    }
    var out = String(outputMuteHotkey || "").trim()
    if (out) {
      lines.push("hl.unbind(" + luaString(out) + ")")
      lines.push("o.bind(" + luaString(out) + ", " + luaString("Toggle output mute for selected profile") + ", "
        + luaString("omarchy-shell io.github.solkkku.audio-switcher toggleOutputMute") + ", { locked = true })")
    }
    return lines.join("\n")
  }

  function replaceBlock(current, block) {
    var start = "-- BEGIN audio-switcher (managed, do not edit)"
    var end = "-- END audio-switcher (managed, do not edit)"
    var si = current.indexOf(start)
    var ei = current.indexOf(end)
    var head = current
    var tail = ""
    if (si !== -1 && ei !== -1 && ei > si) {
      head = current.slice(0, si)
      tail = current.slice(ei + end.length)
    }
    head = head.replace(/\s+$/, "")
    tail = tail.replace(/^\s*/, "")
    if (block)
      return head + "\n\n" + start + "\n" + block + "\n" + end + "\n" + (tail ? "\n" + tail : "")
    return (head ? head + "\n" : "") + (tail ? tail + "\n" : "")
  }

  function syncBindings() {
    if (!configLoaded) return
    pendingBindingsText = buildBindingsBlock()
    if (bindingsLoaded) writeBindingsNow()
    else bindingsFile.reload()
  }

  function writeBindingsNow() {
    if (!configLoaded) return
    var current = String(bindingsFile.text() || "")
    var updated = replaceBlock(current, pendingBindingsText)
    if (updated !== current) bindingsFile.setText(updated)
  }

  Component.onCompleted: readConfig()

  IpcHandler {
    target: "io.github.solkkku.audio-switcher"

    function activate(index: string): string { return root.activate(index) }
    function next(): string { return root.next() }
    function previous(): string { return root.previous() }
    function toggleMicMute(): string { return root.toggleMicMute() }
    function toggleSourceMute(name: string): string { return root.toggleSourceMute(name) }
    function toggleSinkMute(name: string): string { return root.toggleSinkMute(name) }
    function toggleOutputMute(): string { return root.toggleOutputMute() }
    function status(): string { return root.statusJson() }
    function outputs(): string { return JSON.stringify(root.outputOptions) }
    function inputs(): string { return JSON.stringify(root.inputOptions) }
    function setCycleHotkey(combo: string): string { return root.setCycleHotkey(combo) }
    function setPreviousHotkey(combo: string): string { return root.setPreviousHotkey(combo) }
    function setMicMuteHotkey(combo: string): string { return root.setMicMuteHotkey(combo) }
    function setOutputMuteHotkey(combo: string): string { return root.setOutputMuteHotkey(combo) }
    function setNotificationPosition(pos: string): string { return root.setNotificationPosition(pos) }
    function addProfile(name: string, output: string, input: string, hotkey: string, icon: string): string { return root.addProfile(name, output, input, hotkey, icon) }
    function updateProfile(index: string, name: string, output: string, input: string, hotkey: string, icon: string): string { return root.updateProfile(index, name, output, input, hotkey, icon) }
    function removeProfile(index: string): string { return root.removeProfile(index) }
    function moveProfile(from: string, to: string): string { return root.moveProfile(from, to) }
  }
}
