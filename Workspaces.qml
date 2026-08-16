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
    onSaved: root.publishedCount = root.slotCount
    onSaveFailed: publishDefer.restart()
  }

  // Written once per shell session, and again whenever the setting changes.
  // Confirmed on the way out rather than assumed on the way in.
  property int publishedCount: 0

  function publishCount() {
    if (root.configPath === "" || root.slotCount === root.publishedCount) return
    configFile.setText("-- Written by the Per-monitor Workspaces bar widget.\n"
      + "-- Derived from its `count` setting in shell.json; edit it there.\n"
      + "return { count = " + root.slotCount + " }\n")
  }

  onSlotCountChanged: publishDefer.restart()
  Component.onCompleted: publishDefer.restart()

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

  function focusMonitorLua() {
    return "hl.dispatch(hl.dsp.focus({ monitor = " + root.quoteLua(root.monitor.name) + " }));"
  }

  // Focus a workspace on this screen. Hyprland creates a missing workspace on
  // whichever monitor is focused, so focus has to travel here first -- which is
  // also what makes an unvisited slot appear on the right screen.
  function focusHereLua(name) {
    return root.focusMonitorLua()
      + " hl.dispatch(hl.dsp.focus({ workspace = " + root.quoteLua("name:" + name) + " }));"
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
          + " hl.dispatch(hl.dsp.window.move({ workspace = " + root.quoteLua("name:" + name)
          + ", window = \"address:\" .. window.address, follow = false }));"))
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
  function showsOwnSlot() {
    var active = root.monitor && root.monitor.activeWorkspace
    if (!active) return false

    var name = String(active.name)
    for (var slot = 1; slot <= root.slotCount; slot++) {
      if (name === root.slotName(slot)) return true
    }
    return false
  }

  // The slot to put it on: the first that already exists, so a workspace parked
  // elsewhere while this screen was away comes home rather than being stranded.
  function homeSlot() {
    for (var slot = 1; slot <= root.slotCount; slot++) {
      var name = root.slotName(slot)
      if (root.workspaceByName(name) !== null) return name
    }
    return root.slotName(1)
  }

  function adopt() {
    if (!root.monitor || root.prefix === "" || root.showsOwnSlot()) return

    var name = root.homeSlot()
    var workspace = root.workspaceByName(name)
    var stranded = workspace !== null && workspace.monitor !== null
      && workspace.monitor !== root.monitor

    // One snippet, so the whole thing is atomic. A stranded workspace is
    // carried over first -- focusing it would send us to where it is rather
    // than bring it where it belongs -- and a move relocates without
    // displaying, so the focus still has to follow.
    root.runLua(root.withOriginLua(
      (stranded
        ? "hl.dispatch(hl.dsp.workspace.move({ workspace = " + root.quoteLua("name:" + name)
          + ", monitor = " + root.quoteLua(root.monitor.name) + " })); "
        : "")
      + root.focusHereLua(name)))
  }

  // Settle first: a dock brings several screens up at once and Hyprland is
  // still placing them. Re-checked rather than assumed when the timer fires.
  Timer {
    id: adoptSettle
    interval: 700
    onTriggered: root.adopt()
  }

  // Two facts, one action. `prefix` changes when the panel behind this bar
  // changes -- a connector swap, or this bar being new. `monitor` changes when
  // the screen itself is replaced, which is what a reconnect on the same
  // connector with the same description looks like: same name, new object.
  onPrefixChanged: adoptSettle.restart()
  onMonitorChanged: adoptSettle.restart()

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
