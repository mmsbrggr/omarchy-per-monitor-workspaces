import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Per-monitor workspace indicator. Each bar shows only its own screen's slots,
// numbered 1..effectiveCount, matching this plugin's hypr/init.lua: that file
// binds SUPER+N to the workspace named "<monitor key>:N" on the focused monitor.
// Omarchy's built-in widget cannot show these — it lists global ids 1-10, and
// per-monitor workspaces live in a block of ids per screen, from 101 up.
BarWidget {
  id: root
  moduleName: "mmsbrggr.per-monitor-workspaces"

  readonly property string parkedGlyph: "\uF108"
  readonly property string focusedGlyph: "\uDB85\uDCFB"

  // -------------------------------------------------------------- settings
  //
  // The count is this widget's own setting, and this widget is the source of
  // truth for it. hypr/init.lua reads it back out of a small file so the keys
  // and the dots cannot disagree.
  //
  // A persistent path rather than a runtime one: Hyprland parses its config
  // before the shell starts, so a runtime file would not exist yet at login and
  // the session would open with the wrong number of keys bound.
  readonly property int slotCount: {
    var count = Number(root.setting("count", 5))
    return count > 0 ? Math.max(1, Math.floor(count)) : 5
  }

  readonly property string home: Quickshell.env("HOME") || ""

  // Derived state, not configuration. The count is a setting on this widget's
  // shell.json entry -- Omarchy keeps every plugin setting inline there and
  // says so plainly: "there is one user config file", "no separate per-plugin
  // settings file". This is only a projection of that setting into a form the
  // Hyprland side can read, so it lives in state, under the plugin id, and
  // nobody should be editing it.
  //
  // A Lua table because that is how Omarchy already hands values to Hyprland
  // (the current theme is required the same way), which saves the shortcuts
  // parsing anything. Persistent rather than runtime: Hyprland parses its
  // config before the shell starts, so a runtime file would not exist yet at
  // login and the session would open with the wrong number of keys bound.
  readonly property string stateDir: home ? home + "/.local/state/omarchy" : ""
  readonly property string configPath:
    stateDir ? stateDir + "/" + root.moduleName + ".lua" : ""

  readonly property string blocksPath:
    stateDir ? stateDir + "/" + root.moduleName + ".blocks.lua" : ""

  // The Lua half hands out a block of ids per screen and keeps the map here.
  // The widget needs it to read and write guest trailers, which carry a block
  // number rather than a key.
  property var blocks: ({})

  FileView {
    id: blocksFile
    path: root.blocksPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var map = ({})
      var lines = String(text()).split("\n")
      for (var i = 0; i < lines.length; i++) {
        var match = lines[i].match(/^\s*\["(.+)"\]\s*=\s*(\d+),/)
        if (match) map[match[1]] = Number(match[2])
      }
      root.blocks = map
    }
  }

  readonly property int myBlock: root.prefix === "" ? 0 : (root.blocks[root.prefix] || 0)

  // Hoisted the way Tray.qml does, so the popup below is content rather than
  // a wall of `bar ? bar.x : fallback`.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  FileView {
    id: configFile
    path: root.configPath
    atomicWrites: true
    printErrors: false
    // Confirm on the way out rather than on the way in: a setText issued before
    // the view has settled is dropped silently, with neither signal, so the
    // count is only considered published once the write actually lands.
    onSaved: {
      root.publishedCount = root.globalCount
      root.pushCount()
    }
    onSaveFailed: publishDefer.restart()
  }

  // Written once per shell session, and again whenever the setting changes.
  // Confirmed on the way out rather than assumed on the way in.
  property int publishedCount: 0

  function publishCount() {
    if (root.configPath === "" || root.globalCount === root.publishedCount) return
    configFile.setText("-- Written by the Per-monitor Workspaces bar widget.\n"
      + "-- Derived from its `count` setting in shell.json; edit it there.\n"
      + "return { count = " + root.globalCount + " }\n")
  }

  // The file above is only read when Hyprland parses its config, so on its own
  // it would leave the keys at the old count until something reloaded --
  // the dots would move and SUPER+6 would still do nothing. Hand the running
  // config the new count as well, the way Omarchy's own workspace-layout toggle
  // applies a change now and leaves the file for later.
  //
  // After the write rather than beside it, so the two halves cannot disagree:
  // what Hyprland has now is what it will parse next time. A write that never
  // lands leaves the keys where they were, which is visible, rather than moving
  // them until the next reload puts them back, which is not. Every bar sends
  // it, and the Lua side drops an unchanged count.
  function pushCount() {
    root.runLua("local pmw = _G.per_monitor_workspaces; "
      + "if pmw and pmw.set_count then pmw.set_count(" + root.globalCount + ") end")
  }

  // The revision of hypr/actions.lua this widget is written against; see
  // `actions.version` there.
  readonly property int luaVersion: 3

  // An update replaces both halves on disk, and neither running copy notices.
  // The shell loads this file again only when it restarts, and Hyprland reads
  // the Lua half only when it next parses its config -- a plugin rescan does
  // not reload QML, and Hyprland does not watch files it reached by dofile.
  // The shell restarts at the end of `omarchy update`, so this widget tends to
  // arrive first, and then asks Hyprland to re-read its config: the same reload
  // Omarchy's theme switch does. Every bar asks, and only the first reloads: it
  // marks the table the reload is about to replace, so the rest find either
  // that mark or the new table, which is no longer behind.
  function reloadStaleLua() {
    root.runLua("local pmw = _G.per_monitor_workspaces; "
      + "if pmw and (pmw.version or 1) < " + root.luaVersion + " and not pmw.reloading then "
      + "pmw.reloading = true; hl.exec_cmd(\"hyprctl reload\") end")
  }

  onGlobalCountChanged: publishDefer.restart()
  Component.onCompleted: {
    publishDefer.restart()
    truthDefer.restart()
    root.reloadStaleLua()
    adoptSettle.restart()
  }

  Timer { id: publishDefer; interval: 800; onTriggered: root.publishCount() }

  // ---------------------------------------------------------------- monitor

  // The bar is built once per monitor, so this widget's own window identifies
  // which screen it is drawing for.
  readonly property var barWindow: root.QsWindow ? root.QsWindow.window : null
  readonly property var monitor: barWindow && barWindow.screen ? Hyprland.monitorFor(barWindow.screen) : null

  // Same key the Lua side builds: description follows the physical panel,
  // while connector names can swap on replug, and the connector is appended
  // only to break a tie between two panels that describe themselves alike.
  //
  // `description` rather than `lastIpcObject.description`: the ipc object is
  // only refilled by a full monitor refresh, so on hotplug it is briefly empty
  // and this would fall back to the connector name — long enough for a click
  // to create a connector-named workspace the keybindings never target.
  readonly property string prefix: {
    if (!root.monitor) return ""

    var description = String(root.monitor.description || "")
    if (description === "") return String(root.monitor.name || "")

    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      if (monitors[i] !== root.monitor && String(monitors[i].description || "") === description)
        return description + "@" + String(root.monitor.name || "")
    }

    return description
  }

  function slotName(slot) {
    return root.prefix === "" ? "" : root.prefix + ":" + slot
  }

  // The naming grammar, mirroring hypr/names.lua. The two runtimes cannot
  // share code, so they share a contract instead -- as they already do for
  // monitor_key and for <key>:<slot>. If they disagree, the dots and the keys
  // address different workspaces.
  function baseName(name) {
    return String(name).replace(/#\d+\.\d+$/, "")
  }

  function guestOrigin(name) {
    var match = String(name).match(/#(\d+)\.(\d+)$/)
    return match ? { block: Number(match[1]), slot: Number(match[2]) } : null
  }

  function matchesSlot(name, slot) {
    return root.prefix !== "" && root.baseName(name) === root.slotName(slot)
  }

  // A valid slot number: a plain positive integer below the id ceiling,
  // matching names.id's own range. `Number` alone is looser than the Lua
  // side's `%d+` pattern -- it accepts "+3", "0x10", "1e2", "3.0" and
  // "Infinity" -- and an unbounded or infinite result here would size
  // effectiveCount and buildEntries' own loop off a name nothing sane would
  // produce. Returns 0 for anything that does not qualify.
  function parseSlot(text) {
    var str = String(text)
    if (!/^[0-9]+$/.test(str)) return 0
    var slot = Number(str)
    return slot > 0 && slot < 100 ? slot : 0
  }

  // The same key the Lua half builds, for any screen rather than just this
  // one. `prefix` is this screen's; absorption needs every connected screen's
  // to tell a guest from a workspace whose screen is merely elsewhere.
  function keyForMonitor(monitorName) {
    var monitors = Hyprland.monitors.values
    var self = null
    for (var i = 0; i < monitors.length; i++) {
      if (String(monitors[i].name) === String(monitorName)) { self = monitors[i]; break }
    }
    if (!self) return ""

    var description = String(self.description || "")
    if (description === "") return String(self.name || "")
    for (var j = 0; j < monitors.length; j++) {
      if (monitors[j] !== self && String(monitors[j].description || "") === description)
        return description + "@" + String(self.name || "")
    }
    return description
  }

  // Slot number -> workspace, for the screen with this key. A guest counts as
  // occupying the slot it was given.
  function occupiedSlots(key) {
    var taken = ({})
    if (key === "") return taken
    for (var i = 0; i < root.workspaces.length; i++) {
      var workspace = root.workspaces[i]
      var base = root.baseName(workspace.name)
      var cut = base.lastIndexOf(":")
      if (cut <= 0 || base.substring(0, cut) !== key) continue
      var slot = root.parseSlot(base.substring(cut + 1))
      if (slot > 0) taken[slot] = workspace
    }
    return taken
  }

  // The configured count, plus whatever a guest has pushed past it on this
  // screen. Computed, never stored, so it falls back on its own when the
  // guests leave, and `shell.json` is never written.
  readonly property int effectiveCount: {
    var taken = root.occupiedSlots(root.prefix)
    var highest = root.slotCount
    for (var slot in taken) highest = Math.max(highest, Number(slot))
    return highest
  }

  // The keys are global, so the count handed to Lua is the largest any screen
  // needs. Every bar computes it from the same snapshot, so they all publish
  // the same number and none fight.
  readonly property int globalCount: {
    var monitors = Hyprland.monitors.values
    var highest = root.slotCount
    for (var i = 0; i < monitors.length; i++) {
      var taken = root.occupiedSlots(root.keyForMonitor(monitors[i].name))
      for (var slot in taken) highest = Math.max(highest, Number(slot))
    }
    return highest
  }

  // ------------------------------------------------------------------ truth
  //
  // Where the workspaces come from, and why not from Quickshell.
  //
  // Quickshell's Hyprland model files workspaces by id and has no handler for
  // `changeworkspaceid` -- Hyprland broadcasts it, nothing receives it. This
  // plugin renumbers workspaces whenever a slot is rehomed, so after any swap
  // that model is filing two of them under each other's ids. Nothing there
  // repairs it: `refreshWorkspaces()` re-reads monitors and windows but never
  // a name, and re-applying Hyprland's id-to-monitor mapping onto stale ids
  // moves the right workspaces to the wrong screens. The damage lands later
  // and permanently -- an emptied workspace is destroyed by id, taking the
  // wrong one out of the model and leaving the other stranded on this bar
  // under a name from the far screen.
  //
  // So the compositor is asked directly for the one thing the ids can move:
  // which workspaces exist, what they are called, where they are, and what is
  // on them. Quickshell is still trusted for screens, which are keyed by
  // connector and cannot drift this way.
  property var workspaces: []
  property var activeByMonitor: ({})
  property string focusedMonitorName: ""

  Process {
    id: truth
    command: ["sh", "-c", "hyprctl -j monitors; printf '\\036'; hyprctl -j workspaces"]
    stdout: StdioCollector {
      onStreamFinished: {
        var parts = String(this.text).split("\u001e")
        if (parts.length < 2) return

        var monitors, list
        try {
          monitors = JSON.parse(parts[0])
          list = JSON.parse(parts[1])
        } catch (error) {
          return
        }

        var active = ({})
        var focused = ""
        for (var i = 0; i < monitors.length; i++) {
          var monitor = monitors[i]
          active[String(monitor.name)] =
            monitor.activeWorkspace ? String(monitor.activeWorkspace.name) : ""
          if (monitor.focused) focused = String(monitor.name)
        }

        var found = []
        for (var j = 0; j < list.length; j++) {
          found.push({
            name: String(list[j].name),
            monitor: String(list[j].monitor || ""),
            windows: Number(list[j].windows) || 0
          })
        }

        root.activeByMonitor = active
        root.focusedMonitorName = focused
        root.workspaces = found
      }
    }
  }

  // One read per burst. A swap alone is a dozen events, and every one of them
  // would otherwise be its own hyprctl.
  Timer {
    id: truthDefer
    interval: 40
    onTriggered: truth.running = true
  }

  // Everything that can change which workspaces exist, what they are called,
  // where they are, or what is on them. Focus included: the active workspace
  // per screen is read from the same snapshot.
  readonly property var truthEvents: ({
    "workspace": true, "workspacev2": true, "focusedmon": true, "focusedmonv2": true,
    "createworkspace": true, "createworkspacev2": true,
    "destroyworkspace": true, "destroyworkspacev2": true,
    "moveworkspace": true, "moveworkspacev2": true,
    "renameworkspace": true, "changeworkspaceid": true,
    "openwindow": true, "closewindow": true, "movewindow": true, "movewindowv2": true,
    // A screen coming or going moves workspaces without any of the events
    // above firing for all of them, and adoption reads this snapshot to decide
    // what to bring home.
    "monitoradded": true, "monitoraddedv2": true,
    "monitorremoved": true, "monitorremovedv2": true
  })

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (root.truthEvents[event.name]) truthDefer.restart()
      if (event.name === "monitorremoved" || event.name === "monitorremovedv2"
        || event.name === "monitoradded" || event.name === "monitoraddedv2")
        adoptSettle.restart()
    }
  }

  function workspaceByName(name) {
    var values = root.workspaces
    for (var i = 0; i < values.length; i++) {
      if (root.baseName(values[i].name) === name) return values[i]
    }

    return null
  }

  // ---------------------------------------------------------------- entries

  // A parked workspace carries another screen's key, so its trailing number is
  // that screen's slot, not a position in this bar. Printing it puts a "4"
  // after this monitor's "5" and reads as a broken sequence, so the dot gets a
  // display glyph and the name goes in the tooltip.
  function parkedTooltip(name) {
    var separator = name.lastIndexOf(":")
    if (separator <= 0) return name
    return name.substring(0, separator) + " · slot " + name.substring(separator + 1)
  }

  // Exactly the ring SUPER+TAB walks, in the same order: this monitor's own
  // slots first, then everything else living on it — workspaces parked here
  // while their screen is disconnected, and any global numbered workspace
  // something else created. Nothing that is not a workspace belongs in here.
  function buildEntries() {
    var items = []
    if (root.prefix === "") return items

    var own = ({})
    for (var slot = 1; slot <= root.effectiveCount; slot++) {
      var name = root.slotName(slot)
      own[name] = true
      items.push({ name: name, label: String(slot), tooltip: "", parked: false })
    }

    var parked = []
    var values = root.workspaces
    var here = String(root.monitor ? root.monitor.name : "")
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      var workspaceName = workspace.name
      if (workspace.monitor !== here) continue
      // hyprctl reports special workspaces in the same list, and the name is
      // the seam. The Lua half uses workspace.special for the same cut.
      if (own[root.baseName(workspaceName)] || workspaceName.indexOf("special:") === 0) continue
      parked.push(workspace)
    }
    // By screen, then by slot as a number: sorted as text, ":10" would come
    // before ":2". The ids would have ordered these before, and are no longer
    // read here.
    parked.sort(function(left, right) {
      var leftCut = left.name.lastIndexOf(":")
      var rightCut = right.name.lastIndexOf(":")
      var leftKey = leftCut > 0 ? left.name.substring(0, leftCut) : left.name
      var rightKey = rightCut > 0 ? right.name.substring(0, rightCut) : right.name
      if (leftKey !== rightKey) return leftKey < rightKey ? -1 : 1

      var leftSlot = Number(left.name.substring(leftCut + 1))
      var rightSlot = Number(right.name.substring(rightCut + 1))
      if (isNaN(leftSlot) || isNaN(rightSlot)) return left.name < right.name ? -1 : 1
      return leftSlot - rightSlot
    })

    for (var p = 0; p < parked.length; p++) {
      var parkedName = parked[p].name
      items.push({
        name: parkedName,
        label: root.parkedGlyph,
        tooltip: root.parkedTooltip(parkedName),
        parked: true
      })
    }

    return items
  }

  readonly property var entries: root.buildEntries()

  // ------------------------------------------------------------- bindings
  //
  // The Hyprland half cannot install itself -- Omarchy's plugin installer
  // deliberately runs no code from a plugin -- so the warning offers to add the
  // line instead, on a click. The click is the consent: the popup shows the
  // exact text and the exact file before anything is written, and the write
  // only ever appends.
  readonly property string bindingsPath: home ? home + "/.config/hypr/bindings.lua" : ""
  readonly property string bindingsLine:
    'pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/' + root.moduleName + '/hypr/init.lua")'

  property string bindingsText: ""
  property string installError: ""

  // Read the file and look for the line, rather than asking the Lua half to
  // announce itself. Direct, needs no handshake, and it correctly reports
  // "absent" for a line that is present but commented out -- which an
  // announcement cannot, because a file written before the comment went in
  // stays on disk looking perfectly current.
  //
  // Matched on the plugin directory rather than the whole line, so a
  // hand-placed variant with different quoting still counts.
  readonly property bool bindingsLinePresent: {
    if (root.bindingsText === "") return false

    var lines = root.bindingsText.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+/, "")
      if (line.indexOf("--") === 0) continue
      if (line.indexOf(root.moduleName + "/hypr/init.lua") !== -1) return true
    }
    return false
  }

  // Asked once. Someone who declines has declined, and the widget works without
  // the shortcuts -- it just cannot give you keys.
  readonly property string dismissPath:
    stateDir ? stateDir + "/" + root.moduleName + ".offer-dismissed" : ""
  property bool offerDismissed: true

  FileView {
    id: dismissFile
    path: root.dismissPath
    atomicWrites: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.offerDismissed = true
    onLoadFailed: root.offerDismissed = false
  }

  // Answering on one screen answers for all of them. Add and Not now also
  // change something every instance watches -- bindings.lua, the dismissal
  // marker -- but Copy changes nothing shared, so without this the other
  // screens would sit there still asking a question you already answered.
  function closeOffer() {
    root.offerOpen = false
  }

  function dismissOffer() {
    root.offerDismissed = true
    if (root.dismissPath !== "") dismissFile.setText("dismissed\n")
    root.broadcast("closeOffer")
  }

  // Every screen asks, so the answer is wherever you happen to be looking.
  // Answering on one settles all of them: the dismissal file and bindings.lua
  // are both watched, so the other bars close themselves.
  readonly property bool showOffer: !root.bindingsLinePresent && !root.offerDismissed

  FileView {
    id: bindingsFile
    path: root.bindingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.bindingsText = text()
    onLoadFailed: root.bindingsText = ""
    onFileChanged: reload()
  }

  // Keeps the previous contents next to the original before appending, so a
  // bad outcome is one `mv` away from undone.
  // Blocking, so the backup is on disk before the append is issued. setText is
  // otherwise fire-and-forget, and the popup promises this file exists.
  FileView {
    id: bindingsBackup
    path: root.bindingsPath + ".bak"
    atomicWrites: true
    blockWrites: true
    printErrors: false
  }

  function installBindings() {
    root.installError = ""

    if (root.bindingsPath === "") { root.installError = "Cannot resolve $HOME."; return }
    if (root.bindingsText === "") {
      // Either it has not been read yet, or it genuinely cannot be. Ask for a
      // reload and say so, rather than sending someone off to edit by hand.
      bindingsFile.reload()
      root.installError = "Still reading " + root.bindingsPath + " — try again."
      return
    }
    if (root.bindingsLinePresent) { root.installError = "The line is already there."; return }

    bindingsBackup.setText(root.bindingsText)

    var body = root.bindingsText
    if (body.charAt(body.length - 1) !== "\n") body += "\n"
    bindingsFile.setText(body
      + "\n-- Per-monitor workspaces: SUPER+N acts on the focused monitor.\n"
      + "-- Added by the Per-monitor Workspaces bar widget. pcall so that removing\n"
      + "-- the plugin costs these bindings rather than everything below this line.\n"
      + root.bindingsLine + "\n")

    root.broadcast("closeOffer")
  }

  function copyBindingsLine() {
    Util.execDetached("printf %s " + Util.shellQuote(root.bindingsLine) + " | wl-copy")
    root.broadcast("closeOffer")
  }

  property bool offerOpen: false


  // Offered a moment after the bar has settled. Whether it is actually shown is
  // left to showOffer on the popup itself -- checking it here as well would
  // freeze the answer at this instant, which is before bindings.lua has
  // necessarily been read, and the offer would then never appear.
  Timer {
    interval: 1200
    running: true
    repeat: false
    onTriggered: root.offerOpen = true
  }

  // ---------------------------------------------------------------- actions

  // Hyprland's dispatch evaluates Lua source, so an action that has to happen
  // atomically — focus a monitor, then act on it — travels as one snippet.
  function quoteLua(value) {
    return "\"" + String(value)
      .replace(/\\/g, "\\\\")
      .replace(/"/g, "\\\"")
      .replace(/\n/g, "\\n")
      .replace(/\r/g, "\\r")
      + "\""
  }

  // Straight down the socket Quickshell already holds open, rather than
  // spawning a login shell and hyprctl per click.
  function runLua(body) {
    Hyprland.dispatch("function() " + body + " end")
  }

  // The selector for a workspace, as a Lua expression. A slot nobody has used
  // yet has to be created by its numbered id, and the id belongs to the
  // Hyprland half, which hands out each screen's block. Without that half
  // loaded, fall back to the name: the workspace is created named, and still
  // works, only its slide direction is arbitrary. The same goes for a half from
  // before `selector` existed, which is what Hyprland is still running for a
  // moment after an update -- see reloadStaleLua.
  function selectorLua(name) {
    var pmw = "_G.per_monitor_workspaces"
    return "(" + pmw + " and " + pmw + ".selector and " + pmw + ".selector("
      + root.quoteLua(name) + ") or " + root.quoteLua("name:" + name) + ")"
  }

  function focusMonitorLua() {
    return "hl.dispatch(hl.dsp.focus({ monitor = " + root.quoteLua(root.monitor.name) + " }));"
  }

  // Focus a workspace on this screen. Hyprland creates a missing workspace on
  // whichever monitor is focused, so focus has to travel here first -- which is
  // also what makes an unvisited slot appear on the right screen.
  function focusHereLua(name) {
    return root.focusMonitorLua()
      + " hl.dispatch(hl.dsp.focus({ workspace = " + root.selectorLua(name) + " }));"
  }

  // Do something on another screen and give focus back to where it was.
  function withOriginLua(body) {
    return "local origin = hl.get_active_monitor(); " + body
      + " if origin then hl.dispatch(hl.dsp.focus({ monitor = origin.name })) end"
  }

  // Focus the monitor first: an unvisited slot does not exist yet, and Hyprland
  // creates a missing workspace on whichever monitor is focused. Without this,
  // clicking another screen's dot would build its workspace on this one.
  function focusWorkspace(name) {
    if (!root.monitor || name === "") return

    root.runLua(root.focusHereLua(name))
  }

  // Right-click: send the focused window to this slot without following it,
  // the mouse spelling of SUPER+SHIFT+ALT+N. Same monitor-first dance, since an
  // unused slot is created wherever focus happens to be — but the window
  // travels by address, so focusing away cannot move the wrong one.
  function moveWindowTo(name) {
    if (!root.monitor || name === "") return

    root.runLua("local window = hl.get_active_window(); if not window then return end; "
      + root.withOriginLua(
          root.focusMonitorLua()
          + " hl.dispatch(hl.dsp.window.move({ workspace = " + root.selectorLua(name)
          + ", window = \"address:\" .. window.address, follow = false }));"))
  }

  // Scrolling the widget walks the same ring as SUPER+TAB, but for the screen
  // this bar is drawn on rather than the focused one. Wheel down goes forward,
  // matching Omarchy's SUPER+scroll.
  property real wheelAccumulator: 0

  function cycleBy(step) {
    var ring = root.entries
    if (ring.length < 2) return

    var active = root.baseName(root.activeHere())
    var index = Math.max(0, ring.map(function(entry) { return root.baseName(entry.name) }).indexOf(active))

    root.focusWorkspace(ring[((index + step) % ring.length + ring.length) % ring.length].name)
  }

  function onWheel(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps !== 0) root.cycleBy(wheel.steps > 0 ? -1 : 1)
  }

  // -------------------------------------------------------------- adoption
  //
  // A screen that appears lands on whatever workspace Hyprland hands it, which
  // is a global numbered one rather than anything in this screen's set. A dock
  // can also put the same panel on a different connector than last time, and
  // Hyprland restores workspaces per connector rather than per panel, so the
  // two screens end up showing each other's. Both read the same way from here:
  // a screen showing something outside its own set.
  //
  // This lives in the widget because Quickshell rides Hyprland's IPC socket,
  // which announces a returning screen reliably. One instance per screen, each
  // minding its own, so there is nothing to coordinate.

  // Slots promised earlier in this same settle tick. reclaimGuests() and
  // absorb() both hand out slots on this screen from one unrefreshed snapshot,
  // so without this the second would give away a slot the first has already
  // spoken for -- two workspaces renamed to one name, and two ids colliding on
  // the next rehome.
  property var claimedThisTick: ({})

  // The workspace this bar's screen is showing.
  function activeHere() {
    if (!root.monitor) return ""
    var name = root.activeByMonitor[String(root.monitor.name)]
    return name === undefined ? "" : name
  }

  function showsOwnSlot() {
    var name = root.activeHere()
    if (name === "") return false

    for (var slot = 1; slot <= root.effectiveCount; slot++) {
      if (root.matchesSlot(name, slot)) return true
    }
    return false
  }

  // Every slot of this screen's that is living on another monitor. Hyprland
  // parks them on a survivor when the screen goes and hands none of them back
  // when it returns, so a screen can come home to find several of its own
  // workspaces scattered -- not just the one it happens to land on. Returns
  // each workspace's real name, trailer and all, rather than the synthesized
  // bare slot name: the screen holding it may since have absorbed it as a
  // guest, and a move targeting the bare name would then name nothing and
  // silently do nothing, orphaning the workspace.
  function strandedSlots() {
    var here = String(root.monitor ? root.monitor.name : "")
    var names = []
    for (var slot = 1; slot <= root.effectiveCount; slot++) {
      var workspace = root.workspaceByName(root.slotName(slot))
      if (workspace !== null && workspace.monitor !== "" && workspace.monitor !== here)
        names.push(workspace.name)
    }
    return names
  }

  // The slot to put it on: the first that already exists, so a workspace parked
  // elsewhere while this screen was away comes home rather than being stranded.
  function homeSlot() {
    for (var slot = 1; slot <= root.effectiveCount; slot++) {
      var name = root.slotName(slot)
      if (root.workspaceByName(name) !== null) return name
    }
    return root.slotName(1)
  }

  // Two jobs, and a screen can need either without the other. Its workspaces
  // are brought home whatever it is showing -- coming back on one of its own
  // slots is the common case, and used to mean the rest were left where they
  // were parked. Focus only moves when the screen is showing something that is
  // not its own; a parked workspace someone deliberately cycled to is left
  // alone, which is why this runs on a screen appearing rather than on every
  // change of what a screen shows.
  function adopt() {
    if (!root.monitor || root.prefix === "") return

    var stranded = root.strandedSlots()
    var settled = root.showsOwnSlot()
    if (stranded.length === 0 && settled) return

    // One snippet, so the whole thing is atomic. Stranded workspaces are
    // carried over first -- focusing one would send us to where it is rather
    // than bring it where it belongs -- and a move relocates without
    // displaying, so the focus still has to follow.
    var body = ""
    for (var i = 0; i < stranded.length; i++) {
      body += "hl.dispatch(hl.dsp.workspace.move({ workspace = "
        + root.quoteLua("name:" + stranded[i])
        + ", monitor = " + root.quoteLua(root.monitor.name) + " })); "
    }
    if (!settled) body += root.focusHereLua(root.homeSlot())

    root.runLua(root.withOriginLua(body))
  }

  // Workspaces whose own screen is gone, sitting on this one. They become
  // ordinary slots here and remember where they came from in their name.
  //
  // The guard is the whole correctness of this: absorb only when the screen a
  // workspace is named for is *not connected*. Foreign workspaces also exist
  // for a moment in the middle of a swap, while both screens are attached --
  // those must be left alone, and this is what leaves them alone.
  function guestsToAbsorb() {
    var here = String(root.monitor ? root.monitor.name : "")
    if (here === "" || root.prefix === "") return []

    var connected = ({})
    var monitors = Hyprland.monitors.values
    for (var m = 0; m < monitors.length; m++) connected[root.keyForMonitor(monitors[m].name)] = true

    var found = []
    for (var i = 0; i < root.workspaces.length; i++) {
      var workspace = root.workspaces[i]
      if (workspace.monitor !== here) continue

      var base = root.baseName(workspace.name)
      if (base.indexOf("special:") === 0) continue
      var cut = base.lastIndexOf(":")
      if (cut <= 0) continue
      var key = base.substring(0, cut)
      var slot = root.parseSlot(base.substring(cut + 1))
      if (!(slot > 0) || connected[key]) continue

      // Its existing trailer wins: a guest whose host screen has now gone in
      // turn still belongs to the screen it started on, not to the one in the
      // middle.
      var origin = root.guestOrigin(workspace.name)
      if (!origin) {
        var block = root.blocks[key]
        if (!block) continue
        origin = { block: block, slot: slot }
      }
      found.push({ workspace: workspace, origin: origin })
    }

    found.sort(function(left, right) {
      return left.origin.block !== right.origin.block
        ? left.origin.block - right.origin.block
        : left.origin.slot - right.origin.slot
    })
    return found
  }

  // Guests of this screen, wherever they are living. Their trailer names this
  // screen's block, which is the only thing left that says where they belong:
  // they were renamed into their host's scheme when they were taken in, so
  // `strandedSlots` -- which looks for workspaces still carrying this screen's
  // name -- cannot see them. Two mechanisms, disjoint by construction.
  function reclaimGuests() {
    if (root.prefix === "" || root.myBlock === 0 || !root.monitor) return

    var mine = []
    for (var i = 0; i < root.workspaces.length; i++) {
      var workspace = root.workspaces[i]
      var base = root.baseName(workspace.name)
      if (base.indexOf("special:") === 0) continue
      var cut = base.lastIndexOf(":")
      if (cut <= 0) continue
      if (!(root.parseSlot(base.substring(cut + 1)) > 0)) continue

      var origin = root.guestOrigin(workspace.name)
      if (origin && origin.block === root.myBlock) mine.push({ workspace: workspace, origin: origin })
    }
    if (mine.length === 0) return

    mine.sort(function(left, right) { return left.origin.slot - right.origin.slot })

    var taken = root.occupiedSlots(root.prefix)
    for (var claimed in root.claimedThisTick) taken[claimed] = true
    var body = ""
    for (var g = 0; g < mine.length; g++) {
      var guest = mine[g]
      var target = guest.origin.slot
      if (taken[target]) {
        // Its own slot was taken while it was away. It comes home anyway, to
        // the nearest free one, and stops being a guest either way.
        target = 1
        while (taken[target]) target++
      }
      body += "pmw.relocate(" + root.quoteLua(guest.workspace.name) + ", "
        + root.quoteLua(root.slotName(target)) + ", "
        + root.quoteLua(String(root.monitor.name)) + "); "
      taken[target] = true
      root.claimedThisTick[target] = true
    }

    root.runRelocations(body)
  }

  // Moves that go through the Lua half's `relocate`, which knows the ids and
  // the layout file. A half from before `relocate` existed is still loaded for
  // a moment after an update, until reloadStaleLua's reload lands; call into it
  // and the whole batch fails, so leave the batch to the next settle instead.
  function runRelocations(body) {
    root.runLua("local pmw = _G.per_monitor_workspaces; "
      + "if not (pmw and pmw.relocate) then return end; " + body)
  }

  function absorb() {
    var guests = root.guestsToAbsorb()
    if (guests.length === 0) return

    // Append after the last slot in use, so the part of the bar you already
    // know is untouched.
    var taken = root.occupiedSlots(root.prefix)
    for (var claimed in root.claimedThisTick) taken[claimed] = true
    var next = 0
    for (var slot in taken) next = Math.max(next, Number(slot))
    next = next + 1

    var body = ""
    for (var i = 0; i < guests.length; i++) {
      while (taken[next]) next++
      var guest = guests[i]
      var to = root.slotName(next) + "#" + guest.origin.block + "." + guest.origin.slot
      body += "pmw.relocate(" + root.quoteLua(guest.workspace.name) + ", "
        + root.quoteLua(to) + ", " + root.quoteLua(String(root.monitor.name)) + "); "
      taken[next] = true
      root.claimedThisTick[next] = true
      next++
    }

    root.runRelocations(body)
  }

  // Settle first: a dock brings several screens up at once and Hyprland is
  // still placing them. Re-checked rather than assumed when the timer fires.
  Timer {
    id: adoptSettle
    interval: 700
    onTriggered: {
      root.claimedThisTick = ({})
      root.reclaimGuests()
      root.adopt()
      root.absorb()
    }
  }

  // Two facts, one action. `prefix` changes when the panel behind this bar
  // changes -- a connector swap, or this bar being new. `monitor` changes when
  // the screen itself is replaced, which is what a reconnect on the same
  // connector with the same description looks like: same name, new object.
  onPrefixChanged: adoptSettle.restart()
  onMonitorChanged: adoptSettle.restart()
  onBlocksChanged: adoptSettle.restart()

  // ----------------------------------------------------------------- layout

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.entries.length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.entries

      WidgetButton {
        required property var modelData

        readonly property var workspace: root.workspaceByName(modelData.name)
        readonly property bool occupied: workspace !== null && workspace.windows > 0
        // This monitor's active slot, not the globally focused one, so every bar
        // reports where its own screen is sitting.
        readonly property bool focused: root.baseName(root.activeHere()) === root.baseName(modelData.name)
        // The one workspace Hyprland has focused, anywhere. Every bar has a
        // `focused` slot of its own; exactly one of them is also this, and it
        // is the one SUPER+N acts on.
        readonly property bool current: focused && root.monitor !== null
          && root.focusedMonitorName === String(root.monitor.name)

        bar: root.bar
        text: focused ? root.focusedGlyph : modelData.label
        // The accent on that one, so the bars also say which screen the keys
        // will act on. The other branch restates WidgetButton's own default,
        // which is what overriding a property in QML costs. A parked slot is
        // untouched by this: `active` below puts it on `activeColor` instead.
        foreground: current ? Color.accent : (root.bar ? root.bar.barForeground : Color.foreground)
        // Parked workspaces belong to another screen and only borrow this one,
        // so they take the bar's accent rather than passing as slot N.
        active: modelData.parked
        tooltipText: modelData.tooltip
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function(button) {
          if (button === Qt.RightButton) root.moveWindowTo(modelData.name)
          else if (button === Qt.LeftButton) root.focusWorkspace(modelData.name)
        }
        onWheelMoved: function(delta) { root.onWheel(delta) }
      }
    }
  }

  // A keycap, because the thing being offered is keys. This is the one piece
  // of decoration in the card; everything around it stays quiet.
  component Keycap: Rectangle {
    property alias label: keyLabel.text

    implicitWidth: keyLabel.implicitWidth + Style.space(16)
    implicitHeight: keyLabel.implicitHeight + Style.space(10)
    radius: Math.max(3, Style.cornerRadius)
    color: Util.alpha(root.foreground, 0.06)
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.28)

    Text {
      id: keyLabel
      anchors.centerIn: parent
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  PopupCard {
    id: offerPopup
    anchorItem: root
    bar: root.bar
    owner: root
    // Passive: no focus grab, so clicking the desktop cannot dismiss this by
    // accident. It closes on an answer, and only on an answer.
    triggerMode: "hover"
    open: root.offerOpen && root.showOffer
    contentWidth: offerPopup.fittedContentWidth(Style.space(400))
    contentHeight: offerPopup.fittedContentHeight(offerColumn.implicitHeight)

    Column {
      id: offerColumn
      anchors.fill: parent
      spacing: Style.space(14)

      Text {
        text: "KEYBOARD SHORTCUTS"
        color: Util.alpha(root.foreground, 0.45)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: 1.6
      }

      Row {
        spacing: Style.space(6)

        Keycap { label: "SUPER" }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "+"
          color: Util.alpha(root.foreground, 0.45)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Keycap { label: "1" }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          leftPadding: Style.space(6)
          text: "this screen's workspace 1"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(4)

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Also cycling, and moving windows between screens."
          color: Util.alpha(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          elide: Text.ElideMiddle
          text: "Adds one line to ~/.config/hypr/bindings.lua"
          color: Util.alpha(root.foreground, 0.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        visible: root.installError !== ""
        text: root.installError
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Row {
        spacing: Style.space(4)

        Button {
          text: "Add shortcuts"
          bordered: true
          foreground: root.foreground
          accent: root.urgent
          fontFamily: root.fontFamily
          tooltipText: root.bindingsLine
          onClicked: root.installBindings()
        }

        Button {
          text: "Copy line"
          foreground: Util.alpha(root.foreground, 0.65)
          fontFamily: root.fontFamily
          onClicked: root.copyBindingsLine()
        }

        Button {
          text: "Not now"
          foreground: Util.alpha(root.foreground, 0.65)
          fontFamily: root.fontFamily
          onClicked: root.dismissOffer()
        }
      }
    }
  }
}
