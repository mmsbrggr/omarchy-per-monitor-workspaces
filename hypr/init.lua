-- Per-monitor workspaces: SUPER+N is always "this screen's Nth workspace".
--
-- Omarchy's defaults bind SUPER+1..0 to global workspaces, so on a multi-head
-- setup the key silently drags focus to whichever monitor already owns that
-- workspace. Here the target is resolved at press time from the focused
-- monitor, so each screen gets its own independent set of workspaces.
--
-- Deliberately monitor-agnostic: workspaces are named "<monitor>:<slot>", so
-- nothing is hardcoded and no workspace rules are needed. Any monitor gets its
-- own set the first time a slot key is pressed on it, whether one screen is
-- connected or five.
--
-- Load it from ~/.config/hypr/bindings.lua, after Omarchy's defaults:
--
--   per_monitor_workspaces_count = 5  -- optional, defaults to 5
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.mmsbrggr.per-monitor-workspaces/hypr/init.lua")
--
-- Keep the count in step with the bar widget's "count" setting, which decides
-- how many slots each bar draws.

local COUNT = math.max(1, math.floor(tonumber(_G.per_monitor_workspaces_count) or 5))

-- Description, not connector name: DP-2/DP-3 can swap on replug, which would
-- swap two monitors' workspaces along with them.
--
-- Two panels of the same model that report no serial describe themselves
-- identically, and one key for both would mean one shared set of workspaces --
-- the exact thing this file exists to prevent. Only the ambiguous ones pay the
-- connector-name tax, so a monitor that describes itself uniquely keeps a key
-- that survives a replug.
local function monitor_key(monitor)
  local description = monitor.description
  if not description or description == "" then return monitor.name end

  for _, other in ipairs(hl.get_monitors()) do
    if other.id ~= monitor.id and other.description == description then
      return description .. "@" .. monitor.name
    end
  end

  return description
end

-- The naming scheme, in one place. Everything that builds or recognises a
-- workspace name goes through these, so the scheme cannot drift between the
-- keybindings, the cycle ring and the screen-adoption pass.
local function slot_name(key, slot)
  return key .. ":" .. slot
end

local function slot_names(key)
  local names = {}
  for slot = 1, COUNT do names[slot] = slot_name(key, slot) end
  return names
end

local function slot_selector(slot)
  local monitor = hl.get_active_monitor()
  if not monitor then return nil end
  return "name:" .. slot_name(monitor_key(monitor), slot)
end

local function focus_slot(slot)
  return function()
    local selector = slot_selector(slot)
    if selector then
      hl.dispatch(hl.dsp.focus({ workspace = selector }))
    end
  end
end

local function move_to_slot(slot, follow)
  return function()
    local selector = slot_selector(slot)
    if selector then
      hl.dispatch(hl.dsp.window.move({ workspace = selector, follow = follow }))
    end
  end
end

-- The ring SUPER+TAB walks, as workspace names: this monitor's own slots
-- first, in slot order, then everything else living on it.
--
-- Slots are listed whether or not they exist yet. Hyprland deletes a workspace
-- the moment its last window closes, so a ring built only from live workspaces
-- is a ring of one on any screen whose windows all sit on one slot -- which is
-- to say, almost always. Empty slots have to be in the ring for TAB to mean
-- anything, and focusing one just creates it here.
--
-- The tail catches what the slots do not: workspaces parked here by a
-- disconnected monitor, and any global numbered workspace something else made.
-- They keep their own identity and stay reachable until their screen returns.
local function monitor_ring()
  local monitor = hl.get_active_monitor()
  if not monitor then return {}, nil end

  local ring = slot_names(monitor_key(monitor))
  local own = {}
  for _, name in ipairs(ring) do own[name] = true end

  local parked = {}
  for _, workspace in ipairs(hl.get_workspaces()) do
    if not workspace.special and workspace.monitor and workspace.monitor.id == monitor.id
      and not own[workspace.name] then
      parked[#parked + 1] = workspace
    end
  end
  table.sort(parked, function(left, right) return left.id < right.id end)
  for _, workspace in ipairs(parked) do ring[#ring + 1] = workspace.name end

  local active = monitor.active_workspace
  return ring, active and active.name or nil
end

local function cycle(step)
  return function()
    local ring, active = monitor_ring()
    if #ring < 2 then return end

    local index = 1
    for i, name in ipairs(ring) do
      if name == active then
        index = i
        break
      end
    end

    -- A "name:" selector, never the HL.Workspace object: hl.dsp.focus accepts
    -- the object and then resolves it to the wrong target, landing you on
    -- global workspace 1.
    hl.dispatch(hl.dsp.focus({ workspace = "name:" .. ring[((index - 1 + step) % #ring) + 1] }))
  end
end

-- Cross-monitor actions carry windows, never workspaces. A workspace named for
-- one screen while living on another is the parked state -- Hyprland's answer
-- to an unplugged monitor, fine as a temporary fact and wrong as something a
-- keybinding does on purpose. Omarchy's "move workspace to monitor" does
-- exactly that, so it is rebound below to move what is on the workspace and
-- leave every workspace on the screen it is named for.

-- The monitor in that direction and the one we are on, or nothing when there
-- is no screen that way. Returning both keeps callers from asking the
-- compositor for the active monitor a second time.
local function target_monitor(selector)
  local monitor = hl.get_monitor(selector)
  local active = hl.get_active_monitor()
  if not monitor or not active or monitor.id == active.id then return nil end
  return monitor, active
end

-- Both sides of a cross-monitor action: the screen we are on and the one we
-- are aiming at, plus what each is showing.
local function active_workspaces(selector)
  local monitor, origin = target_monitor(selector)
  if not monitor then return nil end

  local from, to = origin.active_workspace, monitor.active_workspace
  if not from or not to then return nil end
  return monitor, origin, from, to
end

-- Moving a window does not take keyboard focus with it, and focusing a monitor
-- does nothing while Hyprland already believes that monitor is focused. So
-- after shuffling windows around, the only way to land somewhere defined is to
-- name the window. Without this you end up typing into a screen you are not
-- looking at.
local function focus_window(address)
  hl.dispatch(hl.dsp.focus({ window = "address:" .. address }))
end

local function focus_monitor(selector)
  return function()
    local monitor = target_monitor(selector)
    if monitor then
      hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
    end
  end
end

local function send_workspace(selector)
  return function()
    local monitor, _, from, to = active_workspaces(selector)
    if not monitor then return end

    -- Snapshot the addresses first: each move mutates the list we are reading.
    local moving = {}
    for _, window in ipairs(from:get_windows()) do moving[#moving + 1] = window.address end

    if #moving == 0 then
      hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
      return
    end

    local active = hl.get_active_window()
    local target, landed = "name:" .. to.name, moving[1]
    for _, address in ipairs(moving) do
      hl.dispatch(hl.dsp.window.move({ workspace = target, window = "address:" .. address, follow = false }))
      if active and address == active.address then landed = address end
    end

    -- Follow what you sent, landing on the window you were already using rather
    -- than on whatever happened to be sitting on that screen.
    focus_window(landed)
  end
end

-- A name no workspace of ours will ever have, borrowed for a moment mid-swap.
local SWAP_SCRATCH = "__per-monitor-workspaces-swap"

local function swap_workspaces(selector)
  return function()
    local monitor, origin, from, to = active_workspaces(selector)
    if not monitor then return end

    -- Swap the workspaces themselves rather than their windows. Carrying
    -- windows across one at a time drops each one wherever the far layout
    -- happens to put it, so a master-and-stack arrives as an arbitrary pile;
    -- swapping the workspaces keeps both arrangements exactly as they were,
    -- and is one compositor operation rather than one per window.
    --
    -- That leaves each workspace on the screen the other one is named for, so
    -- trade the names back. Both names are still taken at that point, hence the
    -- third one in the middle.
    local here, there = from.name, to.name
    hl.dispatch(hl.dsp.workspace.swap_monitors({ monitor1 = origin.name, monitor2 = monitor.name }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. here, name = SWAP_SCRATCH }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. there, name = here }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. SWAP_SCRATCH, name = there }))

    -- Follow the windows you just sent over.
    hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
  end
end

local DIRECTIONS = {
  { key = "LEFT", selector = "l", label = "left" },
  { key = "RIGHT", selector = "r", label = "right" },
  { key = "UP", selector = "u", label = "up" },
  { key = "DOWN", selector = "d", label = "down" },
}

for _, direction in ipairs(DIRECTIONS) do
  -- Omarchy only cycles monitors (CTRL+ALT+TAB); nothing aims at one.
  o.bind(
    "SUPER + CTRL + ALT + " .. direction.key,
    "Focus " .. direction.label .. " monitor",
    focus_monitor(direction.selector)
  )
  -- Hyprland's own "move to monitor" already lands on whatever that screen is
  -- showing, which is where you were looking when you threw the window at it.
  o.bind(
    "SUPER + CTRL + SHIFT + " .. direction.key,
    "Move window to " .. direction.label .. " monitor",
    hl.dsp.window.move({ monitor = direction.selector, follow = true })
  )

  hl.unbind("SUPER + SHIFT + ALT + " .. direction.key)
  o.bind(
    "SUPER + SHIFT + ALT + " .. direction.key,
    "Move workspace to " .. direction.label .. " monitor",
    send_workspace(direction.selector)
  )

  o.bind(
    "SUPER + CTRL + ALT + SHIFT + " .. direction.key,
    "Swap workspace with " .. direction.label .. " monitor",
    swap_workspaces(direction.selector)
  )
end

-- Drop all ten of Omarchy's global workspace bindings, not just the first
-- COUNT: a leftover SUPER+7 would still jump to another monitor.
for number = 1, 10 do
  local key = "code:" .. tostring(number + 9)
  hl.unbind("SUPER + " .. key)
  hl.unbind("SUPER + SHIFT + " .. key)
  hl.unbind("SUPER + SHIFT + ALT + " .. key)
end

-- Ten digits is all there is, whatever COUNT says. Slots past the tenth still
-- exist and stay reachable by TAB, scroll and click -- they just have no key,
-- because there is not one to give them.
for slot = 1, math.min(COUNT, 10) do
  local key = "code:" .. tostring(slot + 9)
  o.bind("SUPER + " .. key, "Switch to workspace " .. slot, focus_slot(slot))
  o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. slot, move_to_slot(slot, true))
  o.bind(
    "SUPER + SHIFT + ALT + " .. key,
    "Move window silently to workspace " .. slot,
    move_to_slot(slot, false)
  )
end

-- Omarchy cycles with the e+1/e-1 selectors, which walk workspaces across every
-- monitor and cannot order named ones anyway. Cycle within this monitor instead.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
hl.unbind("SUPER + mouse_down")
hl.unbind("SUPER + mouse_up")

o.bind("SUPER + TAB", "Next workspace", cycle(1))
o.bind("SUPER + SHIFT + TAB", "Previous workspace", cycle(-1))
o.bind("SUPER + mouse_down", "Scroll active workspace forward", cycle(1))
o.bind("SUPER + mouse_up", "Scroll active workspace backward", cycle(-1))

-- Omarchy's "Former workspace" uses the global `previous` selector, which
-- returns to the last workspace focused anywhere -- so from a second screen it
-- drags focus to whichever monitor that was, the same jump SUPER+N exists to
-- prevent. Hyprland's per-monitor variant does what the key reads like.
hl.unbind("SUPER + CTRL + TAB")
o.bind("SUPER + CTRL + TAB", "Former workspace", hl.dsp.focus({ workspace = "previous_per_monitor" }))

-- A screen that appears lands on whatever workspace Hyprland hands it, which
-- is a global numbered one rather than anything in this screen's set. Undock
-- and redock and every external comes back sitting on a throwaway workspace
-- outside its own slots. Put each new screen on one of its own instead.
--
-- Prefer a slot that already exists: while the screen was away its workspaces
-- were parked on a surviving one, so focusing a parked slot here is also what
-- brings it home, windows and all.
-- Put a screen on one of its own slots, preferring one that already exists --
-- while the screen was away its workspaces were parked on a survivor, so
-- preferring the live one is also what brings it home, windows and all.
-- Returns whether anything was actually moved.
local function adopt_monitor(monitor, key)
  local names = slot_names(key)
  local active = monitor.active_workspace

  -- Any of its own slots will do. Only a screen showing something outside its
  -- set gets moved, so this never drags you off a slot you chose.
  for _, name in ipairs(names) do
    if active and active.name == name then return false end
  end

  local target, workspace = names[1], nil
  for _, name in ipairs(names) do
    local existing = hl.get_workspace("name:" .. name)
    if existing then target, workspace = name, existing break end
  end

  -- Alive but on the wrong screen: parked on a survivor while this one was
  -- away, or left behind on the connector this panel used to sit on. Bring the
  -- workspace across first -- focusing it would send us to where it is instead
  -- of bringing it to where it belongs.
  if workspace and workspace.monitor and workspace.monitor.id ~= monitor.id then
    hl.dispatch(hl.dsp.workspace.move({ workspace = "name:" .. target, monitor = monitor.name }))
  end

  -- Then put it on screen. A move relocates a workspace without displaying it,
  -- and a slot that does not exist yet has to be focused into being -- Hyprland
  -- creates a missing workspace on whichever monitor is focused, so focus has
  -- to travel there.
  hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
  hl.dispatch(hl.dsp.focus({ workspace = "name:" .. target }))
  return true
end

-- Two things go wrong when a screen comes back. It lands on whatever Hyprland
-- hands it, which is a global numbered workspace; and a dock can put the same
-- panel on a different connector than last time, which leaves the two screens
-- showing each other's workspaces, because Hyprland restores them per connector
-- rather than per panel. Both read the same way from here -- a screen showing
-- something outside its own set -- and both are fixed the same way.
local function adopt_all()
  local origin = hl.get_active_monitor()
  local moved = false

  for _, monitor in ipairs(hl.get_monitors()) do
    if adopt_monitor(monitor, monitor_key(monitor)) then moved = true end
  end

  -- Hand focus back once for the whole pass rather than after each screen: a
  -- dock brings several up at once, and every focus change wakes every bar.
  if moved and origin then hl.dispatch(hl.dsp.focus({ monitor = origin.name })) end
end

-- Deferred because a reload that got us here may still be applying the monitor
-- rules that say where these screens are, and a dock brings several up at once.
local function reconcile()
  hl.timer(adopt_all, { timeout = 500, type = "oneshot" })
end

-- Two triggers for two different facts. monitor.added is "a screen appeared",
-- and it is the one that does the work on a dock -- it fires for a reconnected
-- connector, not just a brand new output. Running on load covers "this file
-- just loaded, reconcile whatever is true now": a fresh login, or a session
-- that was already wrong when the line was first added to bindings.lua.
reconcile()
hl.on("monitor.added", reconcile)

-- Tell the bar widget that this file is loaded, and how many slots it bound.
-- The widget reads the count from here rather than carrying its own, so the
-- two halves cannot drift; and its absence is how the widget knows to warn.
-- A bar drawing per-monitor slots while SUPER+N still switches globally is the
-- one broken state that looks like a bug in the widget rather than a missing
-- line in bindings.lua.
--
-- The runtime dir goes away with the session, and the instance signature
-- stamps which Hyprland wrote it, so a file left behind by an earlier login
-- cannot pass for this one.
local function write_state()
  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if not runtime or runtime == "" then return end

  local file = io.open(runtime .. "/omarchy-per-monitor-workspaces.json", "w")
  if not file then return end

  local instance = (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""):gsub('[\\"]', "\\%0")
  file:write(string.format('{"count":%d,"instance":"%s"}\n', COUNT, instance))
  file:close()
end

write_state()
