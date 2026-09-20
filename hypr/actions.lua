-- Per-monitor workspaces: the actions, without any keys attached.
--
-- Every action is a factory returning a nullary function, which is what
-- `o.bind` wants as a dispatcher. Bind them yourself:
--
--   local pmw = dofile(os.getenv("HOME") ..
--     "/.config/omarchy/plugins/mmsbrggr.per-monitor-workspaces/hypr/actions.lua")
--
--   o.bind("SUPER + code:10", "Workspace 1", pmw.focus_slot(1))
--   o.bind("SUPER + TAB",     "Next",        pmw.cycle(1))
--   o.bind("SUPER + L",       "Toggle layout", pmw.toggle_layout())
--   o.bind("SUPER + CTRL + ALT + LEFT", "Focus left", pmw.focus_monitor("l"))
--
-- Or load hypr/init.lua instead, which binds a full default set for you.
--
-- The bar widget is what actually provides per-monitor workspaces; these are
-- the verbs that act on them, and the slot count comes from the widget -- which
-- can change it while Hyprland is running. Anything you bind that depends on
-- how many slots there are goes inside `pmw.on_count(function(count) ... end)`,
-- which runs now and again on every change; hypr/bindings.lua is the worked
-- example.

-- The bar widget owns the slot count -- it is a setting on its shell.json
-- entry, which is where Omarchy keeps plugin settings -- and projects it into
-- ~/.local/state/omarchy as a Lua table for this file to read. dofile rather
-- than require, because Hyprland's reload only clears the require cache for a
-- few known prefixes and a cached count would go stale.
--
-- `per_monitor_workspaces_count` still wins where it is set, for anyone running
-- these bindings without the widget. Setting both makes the keys and the dots
-- disagree, and nothing can warn you.
local function configured_count()
  if _G.per_monitor_workspaces_count then return tonumber(_G.per_monitor_workspaces_count) end

  local home = os.getenv("HOME")
  if not home then return nil end

  local ok, config = pcall(dofile,
    home .. "/.local/state/omarchy/mmsbrggr.per-monitor-workspaces.lua")

  return ok and type(config) == "table" and tonumber(config.count) or nil
end

local function whole_count(value)
  local number = tonumber(value)
  return number and math.max(1, math.floor(number)) or nil
end

-- The public surface, declared here because the count sits on it and can change
-- while Hyprland is running. The verbs are attached at the bottom.
--
-- Read `actions.count` where it is used rather than copying it into an upvalue,
-- and register with `on_count` for anything that has to be rebuilt when it
-- moves. The file above is only read at config-parse time; the widget pushes a
-- later change straight in, so a snapshot goes stale within the session.
local actions = { count = whole_count(configured_count()) or 5 }

local count_listeners = {}

-- Register something that depends on the count -- the slot keys, above all.
-- Called once immediately, so the listener is the only place its thing is
-- built, and one body covers both this parse and every later change.
function actions.on_count(listener)
  count_listeners[#count_listeners + 1] = listener
  listener(actions.count)
end

-- Called from the bar widget over Hyprland's socket when its `count` setting
-- changes. Omarchy's own workspace-layout toggle works this way: apply the
-- change now, and leave the file for the next parse to read. Without it the
-- dots would move on a setting change and the keys would sit at the old count
-- until something reloaded Hyprland.
--
-- One bar per screen sends it, all with the same number, so an unchanged count
-- has to cost nothing. `per_monitor_workspaces_count` keeps winning here as it
-- does above -- an override that only held until the widget's next write would
-- be worse than one that never took.
function actions.set_count(value)
  if _G.per_monitor_workspaces_count then return end

  local count = whole_count(value)
  if not count or count == actions.count then return end

  actions.count = count
  for _, listener in ipairs(count_listeners) do listener(count) end
end

-- State the Hyprland half keeps for itself, under ~/.local/state/omarchy as
-- Lua tables like the count above. dofile, not require, for the same reason.

local function state_path(suffix)
  local home = os.getenv("HOME")
  return home and (home .. "/.local/state/omarchy/mmsbrggr.per-monitor-workspaces." .. suffix .. ".lua")
end

local function read_state(path)
  if not path then return {} end

  local ok, saved = pcall(dofile, path)
  return (ok and type(saved) == "table") and saved or {}
end

-- Sorted, so a file rewritten after a one-key change reads as a one-line diff
-- rather than a reshuffle -- pairs() order is not stable between runs.
local function write_state(path, header, entries)
  if not path then return end

  local keys = {}
  for key in pairs(entries) do keys[#keys + 1] = key end
  table.sort(keys)

  local file = io.open(path, "w")
  if not file then return end

  file:write(header)
  file:write("return {\n")
  for _, key in ipairs(keys) do
    local value = entries[key]
    file:write(string.format("  [%q] = %s,\n", key,
      type(value) == "number" and tostring(value) or string.format("%q", value)))
  end
  file:write("}\n")
  file:close()
end

-- Description, not connector name: DP-2/DP-3 can swap on replug, which would
-- swap two monitors' workspaces along with them.
--
-- Must stay identical to `prefix` in Workspaces.qml, which computes the same
-- key for the bar. They cannot share code -- different runtimes -- and if they
-- disagree the dots and the keys quietly address different workspaces.
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

-- Slots are numbered workspaces that carry a name, not named workspaces.
--
-- Hyprland picks the direction a workspace switch slides in by comparing ids.
-- A named workspace gets a negative id counting down from -1337 in creation
-- order, so between two slots the direction was arbitrary, and backwards for
-- anyone who visits them in order. Hyprland's upcoming workspace refactor drops
-- ids from named workspaces altogether, which leaves no direction at all.
--
-- So each screen gets a block of ids, handed out the first time its key is
-- seen and kept in a state file so it survives restarts: slot N of the screen
-- in block B is workspace B * ID_STRIDE + N. Ids then rise with slots on every
-- screen, and a workspace rule gives each one its slot name as it is created.
-- The name stays the identity everything else matches on.
local ID_STRIDE = 100

local blocks_path = state_path("blocks")
local blocks = read_state(blocks_path)

-- The key and slot a name was built from, or nothing for a name that is not one
-- of ours.
local function split_name(name)
  local key, slot = string.match(name, "^(.*):(%d+)$")
  return key, tonumber(slot)
end

-- The id a slot name should have. `allocate` gives an unseen screen its block;
-- without it, a key that has none yet has no id either.
local function slot_id(name, allocate)
  local key, slot = split_name(name)
  if not key or slot < 1 or slot >= ID_STRIDE then return nil end

  local block = tonumber(blocks[key])
  if not block then
    if not allocate then return nil end

    block = 0
    for _, used in pairs(blocks) do block = math.max(block, tonumber(used) or 0) end
    block = block + 1
    blocks[key] = block
    write_state(blocks_path,
      "-- Written by the Per-monitor Workspaces bindings.\n"
        .. "-- Monitor key to id block: slot N is workspace block * " .. ID_STRIDE .. " + N.\n",
      blocks)
  end

  return block * ID_STRIDE + slot
end

local function find_workspace(matches)
  for _, workspace in ipairs(hl.get_workspaces()) do
    if matches(workspace) then return workspace end
  end
  return nil
end

-- Ids no workspace of ours will ever have, borrowed for a moment while ids
-- are being shuffled.
local SCRATCH_ID = 999999000

-- Put the workspaces holding these ids back on the ids their names call for.
--
-- A slot can end up on another slot's id: a swap with a workspace that has no
-- id to trade, one created before slots had ids, carries a numbered id across
-- to the other screen's name. Left there, it breaks that screen's order, and it
-- sits on the id its own slot needs, which would then have to be created by
-- name -- one more workspace with no id, and the next swap spreads it further.
--
-- Two phases through scratch ids, so two workspaces on each other's ids can
-- trade. One whose id is held by anything that is not moving stays put.
-- Renamed afterwards, because changing the id of a workspace that was never
-- renamed resets its name to the number.
local function rehome(ids)
  local movers = {}
  for _, id in ipairs(ids) do
    local workspace = find_workspace(function(candidate) return candidate.id == id end)
    local wanted = workspace and workspace.id > 0 and slot_id(workspace.name)
    if wanted and wanted ~= workspace.id then
      movers[#movers + 1] = { id = workspace.id, wanted = wanted, name = workspace.name }
    end
  end

  -- Drop movers blocked by a workspace that stays, until nobody is blocked:
  -- dropping one can block another that was waiting for it to leave.
  local settled = false
  while not settled do
    settled = true
    local leaving = {}
    for _, mover in ipairs(movers) do leaving[mover.id] = true end

    for index, mover in ipairs(movers) do
      local holder = find_workspace(function(candidate) return candidate.id == mover.wanted end)
      if holder and not leaving[holder.id] then
        table.remove(movers, index)
        settled = false
        break
      end
    end
  end

  for index, mover in ipairs(movers) do
    hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(mover.id), id = SCRATCH_ID + index }))
  end
  for index, mover in ipairs(movers) do
    hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(SCRATCH_ID + index), id = mover.wanted }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = tostring(mover.wanted), name = mover.name }))
  end
end

-- Rules already registered this parse. A parse starts from an empty rule set,
-- and this file is re-read with it.
local named_ids = {}

-- The selector that reaches a workspace by name, creating it if it is missing.
--
-- A workspace that exists is addressed by name, whatever its id: one parked
-- here from another screen, or one created before slots had ids, which keeps
-- working until it empties. A missing slot is created by its id, never by name
-- -- "name:" on a missing workspace makes a named one with a negative id, the
-- thing this is here to avoid. A slot squatting on the id is moved to its own
-- first. Names with no id to give them fall back to the name anyway: past
-- ID_STRIDE slots, or an id held by something that is not a slot.
local function workspace_selector(name)
  local by_name = "name:" .. name
  if find_workspace(function(workspace) return workspace.name == name end) then return by_name end

  local id = slot_id(name, true)
  if not id then return by_name end

  rehome({ id })
  if find_workspace(function(workspace) return workspace.id == id end) then return by_name end

  if not named_ids[id] then
    hl.workspace_rule({ workspace = tostring(id), default_name = name })
    named_ids[id] = true
  end
  return tostring(id)
end

local function slot_selector(slot)
  local monitor = hl.get_active_monitor()
  if not monitor then return nil end
  return workspace_selector(slot_name(monitor_key(monitor), slot))
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

  local key = monitor_key(monitor)
  local ring, own = {}, {}
  for slot = 1, actions.count do
    local name = slot_name(key, slot)
    ring[slot] = name
    own[name] = true
  end

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

    -- A selector string, never the HL.Workspace object: hl.dsp.focus accepts
    -- the object and then resolves it to the wrong target, landing you on
    -- global workspace 1.
    hl.dispatch(hl.dsp.focus({ workspace = workspace_selector(ring[((index - 1 + step) % #ring) + 1]) }))
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

local function focus_monitor(selector)
  return function()
    local monitor = target_monitor(selector)
    if monitor then
      hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
    end
  end
end

-- Hyprland's own "move to monitor" already lands on whatever that screen is
-- showing, which is where you were looking when you threw the window at it.
local function send_window(selector)
  return function()
    hl.dispatch(hl.dsp.window.move({ monitor = selector, follow = true }))
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
    -- than on whatever happened to be sitting on that screen. Naming the window
    -- is the only thing that lands anywhere defined: moving a window does not
    -- carry keyboard focus with it, and focusing a monitor does nothing while
    -- Hyprland already believes that monitor is focused.
    hl.dispatch(hl.dsp.focus({ window = "address:" .. landed }))
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
    local here_id, there_id = from.id, to.id
    hl.dispatch(hl.dsp.workspace.swap_monitors({ monitor1 = origin.name, monitor2 = monitor.name }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. here, name = SWAP_SCRATCH }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. there, name = here }))
    hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. SWAP_SCRATCH, name = there }))

    -- Ids go with names, or each screen's slots stop rising in order and the
    -- slide direction goes wrong on both. Two slots trade; a workspace with no
    -- id to trade, or a parked or global one, leaves the other slot to move to
    -- its own id alone.
    rehome({ here_id, there_id })

    -- Follow the windows you just sent over.
    hl.dispatch(hl.dsp.focus({ monitor = monitor.name }))
  end
end

-- Workspace layouts. Omarchy's SUPER+L toggles the active workspace between
-- dwindle and scrolling, and its own toggle keys the rule off the workspace
-- *id*, filing the choice under that number:
--
--   hl.workspace_rule({ workspace = "202", layout = "scrolling" })
--
-- A slot's id is whichever block its screen was handed, so a layout stored
-- against the bare number says nothing about whose slot it was -- and a slot
-- that never got an id is named-only, with a negative id no numeric rule
-- matches. Address the workspace by name, the way everything else in this file
-- does, and neither is a problem.
--
-- One asymmetry to know about: where both exist for the same workspace, an
-- id-keyed layout rule wins over a name-keyed one until the next parse. Nothing
-- here sets one -- the rule in `workspace_selector` carries only a name -- but
-- running Omarchy's toggle by hand on a slot does, and ours will look dead on
-- that workspace for the rest of the session.

local layouts_path = state_path("layouts")

local function read_layouts()
  return read_state(layouts_path)
end

local function write_layouts(layouts)
  write_state(layouts_path,
    "-- Written by the Per-monitor Workspaces SUPER+L binding.\n"
      .. "-- Workspace name to tiling layout, re-applied on every config parse.\n",
    layouts)
end

-- Ours are addressed by name, Omarchy's numbered ones by their number, and
-- `tonumber` is the whole difference: a workspace called "3" is Hyprland's
-- global third, ours is "<screen>:3". Standing on a parked workspace or a
-- global one the toggle still has to work, so it handles both.
local function apply_layout(name, layout)
  local selector = tonumber(name) and name or ("name:" .. name)
  hl.workspace_rule({ workspace = selector, layout = layout })
end

-- Re-applied on every parse, because a rule set at runtime is gone the next
-- time Hyprland reads its config -- which Omarchy does on every theme change.
-- Without this the layout you picked reverts to dwindle at the moment you
-- change your theme, which is nowhere near the moment you would blame for it.
--
-- Rules are declarative and match a workspace when it is created, so naming
-- one that does not exist yet is not a problem to work around; it is the point.
for name, layout in pairs(read_layouts()) do apply_layout(name, layout) end

local function toggle_layout()
  return function()
    local monitor = hl.get_active_monitor()
    local workspace = monitor and monitor.active_workspace
    if not workspace then return end

    -- Anything that is not dwindle toggles back to it, matching Omarchy: the
    -- other layouts are reachable by config, not by this key, and landing on
    -- dwindle is the way back to familiar ground from any of them.
    local layout = workspace.tiled_layout == "dwindle" and "scrolling" or "dwindle"
    apply_layout(workspace.name, layout)

    local layouts = read_layouts()
    layouts[workspace.name] = layout
    write_layouts(layouts)

    -- Omarchy's toggle says so too, with this icon. Silence would read as the
    -- same nothing-happened the broken key gave you.
    hl.dispatch(hl.dsp.exec_cmd(
      "omarchy-notification-send -g 󱂬 'Workspace layout set to " .. layout .. "'"))
  end
end

-- The verbs, onto the table declared at the top. Each is a factory: call it
-- with its argument and you get the nullary function that `o.bind` takes as a
-- dispatcher.

-- One screen. `slot` is 1..count.
actions.focus_slot = focus_slot
actions.move_to_slot = function(slot) return move_to_slot(slot, true) end
actions.move_to_slot_silently = function(slot) return move_to_slot(slot, false) end
actions.cycle = cycle

-- The selector for a workspace name, for the bar widget: it creates missing
-- slots, and only this file knows the id to create them with.
actions.selector = workspace_selector

-- Across screens. `selector` is a Hyprland monitor selector -- "l", "r", "u",
-- "d" for a direction, or "+1"/"-1" to step.
actions.focus_monitor = focus_monitor
actions.send_window = send_window
actions.send_workspace = send_workspace
actions.swap_workspaces = swap_workspaces

-- The workspace under you, whichever screen it is on.
actions.toggle_layout = toggle_layout

-- Also global, so hypr/bindings.lua can find it without a path, and so a
-- user's own config can reach it after hypr/init.lua has run.
_G.per_monitor_workspaces = actions

return actions
