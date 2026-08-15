import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Per-monitor workspace indicator. Each bar shows only its own screen's slots,
// numbered 1..slotCount, matching this plugin's hypr/init.lua: that file binds
// SUPER+N to the workspace named "<monitor key>:N" on the focused monitor.
// Omarchy's built-in widget cannot show these — it lists global ids 1-10, and
// per-monitor workspaces are named, so their ids are negative.
BarWidget {
  id: root
  moduleName: "io.github.mmsbrggr.per-monitor-workspaces"

  readonly property string warningGlyph: "\uF071"
  readonly property string parkedGlyph: "\uF108"
  readonly property string focusedGlyph: "\uDB85\uDCFB"

  // ------------------------------------------------------------------ state
  //
  // hypr/init.lua writes this when it loads, with the slot count it bound. The
  // widget follows that count rather than keeping its own, so the two halves
  // cannot drift; the `count` setting below is only the fallback for a bar
  // whose keybindings were never installed.
  readonly property string stateDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string statePath: stateDir ? stateDir + "/omarchy-per-monitor-workspaces.json" : ""
  readonly property string hyprlandInstance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

  property var luaState: null

  // Stamped with the Hyprland instance that wrote it, so a file left behind by
  // an earlier login cannot pass for this session. When either side cannot say
  // which instance it is, take the file at its word rather than cry wolf.
  //
  // The instance alone is not enough. Comment the line out of bindings.lua and
  // reload, and Hyprland drops everything the file bound while the file it
  // wrote stays on disk, stamped with this very session -- so the bar would
  // keep claiming all is well. Every reload is therefore treated as a question:
  // the state file has to be rewritten to answer it, and `staleSinceReload`
  // stands in for "the reload came and went without an answer".
  property bool staleSinceReload: false

  readonly property bool luaLoaded: {
    if (!root.luaState || root.staleSinceReload) return false
    var stamped = String(root.luaState.instance || "")
    if (stamped === "" || root.hyprlandInstance === "") return true
    return stamped === root.hyprlandInstance
  }

  property real reloadAt: 0

  // A file with no stamp at all is one an older version of the plugin wrote, so
  // it answers nothing. Zero rather than NaN, because every comparison against
  // NaN is false and a missing answer would silently read as a fresh one.
  function stateLoadedAt() {
    var stamp = root.luaState ? Number(root.luaState.loaded) : Number.NaN
    return isFinite(stamp) ? stamp : 0
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "configreloaded") return
      // Whole seconds: the Lua side stamps with os.time(), so a fractional
      // reading here would make a file written in the same second look older
      // than the reload that prompted it.
      root.reloadAt = Math.floor(Date.now() / 1000)
      reloadGrace.restart()
    }
  }

  // Long enough for the config to finish and rewrite the file; short enough
  // that a bar left claiming per-monitor workspaces corrects itself promptly.
  Timer {
    id: reloadGrace
    interval: 2500
    onTriggered: root.staleSinceReload = root.stateLoadedAt() < root.reloadAt
  }

  function parseState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      return Util.isPlainObject(parsed) ? parsed : null
    } catch (e) {
      return null
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.luaState = root.parseState(text())
      // A rewrite at or after the reload is the answer that reload asked for.
      if (root.stateLoadedAt() >= root.reloadAt) root.staleSinceReload = false
    }
    onLoadFailed: root.luaState = null
    onFileChanged: reload()
  }

  // FileView cannot watch a path that does not exist yet, which is the case
  // when the bindings.lua line is added while the shell is already running.
  // Watch the directory instead — the same trick the bar uses for its own
  // toggle flags — rather than polling for a file that usually never appears.
  //
  // Only until it does appear: this is $XDG_RUNTIME_DIR, a busy directory
  // shared with every socket on the system, and there is one of these per
  // screen. Once the file is read, stateFile watches it directly.
  FileView {
    path: root.stateDir
    watchChanges: root.luaState === null
    printErrors: false
    onFileChanged: stateFile.reload()
  }

  // Clamped: a count of 0, null, or a non-number would leave a bar with an
  // invalid column count and no dots to click.
  readonly property int slotCount: {
    var count = root.luaLoaded ? Number(root.luaState.count) : Number(root.setting("count", 5))
    return count > 0 ? Math.max(1, Math.floor(count)) : 5
  }

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

  function workspaceByName(name) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name) === name) return values[i]
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
    for (var slot = 1; slot <= root.slotCount; slot++) {
      var name = root.slotName(slot)
      own[name] = true
      items.push({ name: name, label: String(slot), tooltip: "", parked: false })
    }

    var parked = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      var workspaceName = String(workspace.name || "")
      if (workspace.monitor !== root.monitor) continue
      // Quickshell's HyprlandWorkspace exposes no `special` flag, so the name
      // is the only seam. The Lua half uses workspace.special for the same cut.
      if (own[workspaceName] || workspaceName.indexOf("special:") === 0) continue
      parked.push(workspace)
    }
    parked.sort(function(left, right) { return left.id - right.id })

    for (var p = 0; p < parked.length; p++) {
      var parkedName = String(parked[p].name)
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
  readonly property string bindingsPath: {
    var home = Quickshell.env("HOME")
    return home ? home + "/.config/hypr/bindings.lua" : ""
  }
  readonly property string pluginDir: {
    var home = Quickshell.env("HOME")
    return home ? home + "/.config/omarchy/plugins/" + root.moduleName : ""
  }
  readonly property string bindingsLine:
    'pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/' + root.moduleName + '/hypr/init.lua")'

  property string bindingsText: ""
  property string installError: ""

  // Present already? Match on the plugin directory rather than the whole line,
  // so a hand-placed variant (plain dofile, different quoting) still counts.
  readonly property bool bindingsLinePresent:
    root.bindingsText !== "" && root.bindingsText.indexOf(root.moduleName + "/hypr/init.lua") !== -1

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
  FileView {
    id: bindingsBackup
    path: root.bindingsPath + ".bak"
    atomicWrites: true
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

    root.warningOpen = false
  }

  function copyBindingsLine() {
    if (!root.bar) return
    root.bar.run("printf %s " + Util.shellQuote(root.bindingsLine) + " | wl-copy")
    root.warningOpen = false
  }

  property bool warningOpen: false

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

  function focusMonitorLua() {
    return "hl.dispatch(hl.dsp.focus({ monitor = " + root.quoteLua(root.monitor.name) + " }));"
  }

  // Focus the monitor first: an unvisited slot does not exist yet, and Hyprland
  // creates a missing workspace on whichever monitor is focused. Without this,
  // clicking another screen's dot would build its workspace on this one.
  function focusWorkspace(name) {
    if (!root.monitor || name === "") return

    root.runLua(root.focusMonitorLua()
      + " hl.dispatch(hl.dsp.focus({ workspace = " + root.quoteLua("name:" + name) + " }))")
  }

  // Right-click: send the focused window to this slot without following it,
  // the mouse spelling of SUPER+SHIFT+ALT+N. Same monitor-first dance, since an
  // unused slot is created wherever focus happens to be — but the window
  // travels by address, so focusing away cannot move the wrong one.
  function moveWindowTo(name) {
    if (!root.monitor || name === "") return

    root.runLua(
      "local window = hl.get_active_window(); if not window then return end;"
      + " local origin = hl.get_active_monitor();"
      + " " + root.focusMonitorLua()
      + " hl.dispatch(hl.dsp.window.move({ workspace = " + root.quoteLua("name:" + name)
      + ", window = \"address:\" .. window.address, follow = false }));"
      + " if origin then hl.dispatch(hl.dsp.focus({ monitor = origin.name })) end")
  }

  // Scrolling the widget walks the same ring as SUPER+TAB, but for the screen
  // this bar is drawn on rather than the focused one. Wheel down goes forward,
  // matching Omarchy's SUPER+scroll.
  property real wheelAccumulator: 0

  function cycleBy(step) {
    var ring = root.entries
    if (ring.length < 2) return

    var active = root.monitor && root.monitor.activeWorkspace
      ? String(root.monitor.activeWorkspace.name) : ""
    var index = Math.max(0, ring.map(function(entry) { return entry.name }).indexOf(active))

    root.focusWorkspace(ring[((index + step) % ring.length + ring.length) % ring.length].name)
  }

  function onWheel(delta) {
    var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
    root.wheelAccumulator = wheel.remainder
    if (wheel.steps !== 0) root.cycleBy(wheel.steps > 0 ? -1 : 1)
  }

  // ----------------------------------------------------------------- layout

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.entries.length + (root.luaLoaded ? 0 : 1))
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    // Not a workspace, so not in the ring — a sibling the layout skips while
    // the keybindings are in place.
    WidgetButton {
      id: warningButton
      visible: !root.luaLoaded
      bar: root.bar
      text: root.warningGlyph
      active: true
      tooltipText: "Per-monitor workspaces are not active — click to fix"
      horizontalMargin: 6
      verticalPadding: 6
      fixedWidth: root.vertical ? root.barSize : Style.space(20)
      fixedHeight: root.barSize
      onPressed: function(button) {
        if (button === Qt.LeftButton) root.warningOpen = !root.warningOpen
      }
    }

    Repeater {
      model: root.entries

      WidgetButton {
        required property var modelData

        readonly property var workspace: root.workspaceByName(modelData.name)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        // This monitor's active slot, not the globally focused one, so every bar
        // reports where its own screen is sitting.
        readonly property bool focused: root.monitor !== null && root.monitor.activeWorkspace !== null
          && String(root.monitor.activeWorkspace.name) === modelData.name

        bar: root.bar
        text: focused ? root.focusedGlyph : modelData.label
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

  PopupCard {
    id: warningPopup
    anchorItem: warningButton
    bar: root.bar
    owner: root
    open: root.warningOpen && !root.luaLoaded
    contentWidth: warningPopup.fittedContentWidth(Style.space(380))
    contentHeight: warningPopup.fittedContentHeight(warningColumn.implicitHeight)

    Column {
      id: warningColumn
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        text: "This bar is drawing per-monitor workspaces, but the half that "
          + "makes them work is not loaded. That file is what gives each screen a "
          + "set of its own — it creates the workspaces, keeps them on the right "
          + "screen when you dock, and points SUPER+N at them. Until it runs, "
          + "these dots are just dots and SUPER+N still switches Omarchy's global "
          + "workspaces."
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        opacity: 0.7
        text: "Appends to " + root.bindingsPath + ":"
      }

      Text {
        width: parent.width
        wrapMode: Text.WrapAnywhere
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: root.bindingsLine
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        visible: root.installError !== ""
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: root.installError
      }

      Row {
        spacing: Style.space(8)

        Button {
          text: "Add it for me"
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.installBindings()
        }

        Button {
          text: "Copy the line"
          bordered: true
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.copyBindingsLine()
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        color: root.bar ? root.bar.foreground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        opacity: 0.7
        text: "Hyprland reloads on save, and this warning disappears on its own. "
          + "The previous file is kept as bindings.lua.bak."
      }
    }
  }
}
