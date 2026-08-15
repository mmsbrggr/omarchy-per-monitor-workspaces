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

  readonly property string warningGlyph: ""
  readonly property string parkedGlyph: ""
  readonly property string focusedGlyph: "󱓻"

  // ------------------------------------------------------------------ state
  //
  // hypr/init.lua writes this when it loads, with the slot count it bound. The
  // widget follows that count rather than keeping its own, so the two halves
  // cannot drift; the `count` setting below is only the fallback for a bar
  // whose keybindings were never installed.
  readonly property string statePath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR")
    return runtime ? runtime + "/omarchy-per-monitor-workspaces.json" : ""
  }
  readonly property string hyprlandInstance: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

  property var luaState: null

  // Stamped with the Hyprland instance that wrote it, so a file left behind by
  // an earlier login cannot pass for this session. When either side cannot say
  // which instance it is, take the file at its word rather than cry wolf.
  readonly property bool luaLoaded: {
    if (!root.luaState) return false
    var stamped = String(root.luaState.instance || "")
    if (stamped === "" || root.hyprlandInstance === "") return true
    return stamped === root.hyprlandInstance
  }

  function parseState(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      return parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      return null
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.luaState = root.parseState(text())
    onLoadFailed: root.luaState = null
    onFileChanged: reload()
  }

  // A file that does not exist yet cannot be watched, so poll gently until it
  // turns up — that is the case where someone adds the bindings.lua line while
  // the shell is already running. Stops as soon as the file is read.
  Timer {
    interval: 5000
    repeat: true
    running: root.statePath !== "" && root.luaState === null
    onTriggered: stateFile.reload()
  }

  // Clamped: a count of 0, null, or a non-number would leave a bar with an
  // invalid column count and no dots to click.
  readonly property int slotCount: {
    var fromLua = root.luaLoaded && root.luaState ? Number(root.luaState.count) : NaN
    if (fromLua > 0) return Math.max(1, Math.floor(fromLua))
    return Math.max(1, Number(root.setting("count", 5)) || 5)
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

  // This monitor's own slots first, in slot order, then everything else living
  // on it: workspaces parked here while their screen is disconnected, and any
  // global numbered workspace something else created. Same ring SUPER+TAB
  // walks, so nothing TAB can reach is missing a dot.
  function buildEntries() {
    var items = []
    if (root.prefix === "") return items

    if (!root.luaLoaded) {
      items.push({
        kind: "warning",
        name: "",
        label: root.warningGlyph,
        tooltip: "Per-monitor Workspaces: keybindings not loaded. Add the plugin's "
          + "hypr/init.lua line to ~/.config/hypr/bindings.lua — until then SUPER+N "
          + "still switches global workspaces."
      })
    }

    var own = ({})
    for (var slot = 1; slot <= root.slotCount; slot++) {
      var name = root.slotName(slot)
      own[name] = true
      items.push({ kind: "slot", name: name, label: String(slot), tooltip: "" })
    }

    var parked = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var workspace = values[i]
      var workspaceName = String(workspace.name || "")
      if (workspace.monitor !== root.monitor) continue
      if (own[workspaceName] || workspaceName.indexOf("special:") === 0) continue
      parked.push(workspace)
    }
    parked.sort(function(left, right) { return left.id - right.id })

    for (var p = 0; p < parked.length; p++) {
      var parkedName = String(parked[p].name)
      items.push({
        kind: "parked",
        name: parkedName,
        label: root.parkedGlyph,
        tooltip: root.parkedTooltip(parkedName)
      })
    }

    return items
  }

  readonly property var entries: root.buildEntries()

  // ---------------------------------------------------------------- actions

  function quoteLua(value) {
    return "\"" + String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\""
  }

  // Focus the monitor first: an unvisited slot does not exist yet, and Hyprland
  // creates a missing workspace on whichever monitor is focused. Without this,
  // clicking another screen's dot would build its workspace on this one.
  function focusWorkspace(name) {
    if (!root.bar || !root.monitor || name === "") return

    var lua = "function()" +
      " hl.dispatch(hl.dsp.focus({ monitor = " + root.quoteLua(root.monitor.name) + " }));" +
      " hl.dispatch(hl.dsp.focus({ workspace = " + root.quoteLua("name:" + name) + " }))" +
      " end"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(lua))
  }

  // Right-click: send the focused window to this slot without following it,
  // the mouse spelling of SUPER+SHIFT+ALT+N. Same monitor-first dance as
  // above, since an unused slot is created wherever focus happens to be — but
  // the window travels by address, so focusing away cannot move the wrong one.
  function moveWindowTo(name) {
    if (!root.bar || !root.monitor || name === "") return

    var lua = "function()" +
      " local window = hl.get_active_window(); if not window then return end;" +
      " local origin = hl.get_active_monitor();" +
      " hl.dispatch(hl.dsp.focus({ monitor = " + root.quoteLua(root.monitor.name) + " }));" +
      " hl.dispatch(hl.dsp.window.move({ workspace = " + root.quoteLua("name:" + name) +
      ", window = \"address:\" .. window.address, follow = false }));" +
      " if origin then hl.dispatch(hl.dsp.focus({ monitor = origin.name })) end" +
      " end"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(lua))
  }

  // Scrolling the widget walks the same ring as SUPER+TAB, but for the screen
  // this bar is drawn on rather than the focused one. Wheel down goes forward,
  // matching Omarchy's SUPER+scroll.
  function cycleBy(step) {
    var ring = []
    for (var i = 0; i < root.entries.length; i++)
      if (root.entries[i].kind !== "warning") ring.push(root.entries[i].name)
    if (ring.length < 2) return

    var active = root.monitor && root.monitor.activeWorkspace
      ? String(root.monitor.activeWorkspace.name) : ""
    var index = 0
    for (var r = 0; r < ring.length; r++) {
      if (ring[r] === active) {
        index = r
        break
      }
    }

    root.focusWorkspace(ring[((index + step) % ring.length + ring.length) % ring.length])
  }

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
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        // This monitor's active slot, not the globally focused one, so every bar
        // reports where its own screen is sitting.
        readonly property bool focused: modelData.kind !== "warning"
          && root.monitor !== null && root.monitor.activeWorkspace !== null
          && String(root.monitor.activeWorkspace.name) === modelData.name

        bar: root.bar
        text: focused ? root.focusedGlyph : modelData.label
        // Parked workspaces belong to another screen and only borrow this one;
        // the warning is not a workspace at all. Both take the bar's accent so
        // neither passes as one of this monitor's slots.
        active: modelData.kind !== "slot"
        tooltipText: modelData.tooltip
        pressable: modelData.kind !== "warning"
        opacity: modelData.kind === "warning" || occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function(button) {
          if (modelData.kind === "warning") return
          if (button === Qt.RightButton) root.moveWindowTo(modelData.name)
          else if (button === Qt.LeftButton) root.focusWorkspace(modelData.name)
        }
        onWheelMoved: function(delta) { root.cycleBy(delta > 0 ? -1 : 1) }
      }
    }
  }
}
