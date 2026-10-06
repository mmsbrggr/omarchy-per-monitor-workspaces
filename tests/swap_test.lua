-- Run: lua tests/swap_test.lua
--
-- Loads hypr/actions.lua against a small fake of Hyprland's Lua API: enough
-- workspaces, monitors and dispatchers for swap_workspaces to run end to end.
local here = debug.getinfo(1, "S").source:match("@(.*/)") or ""

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
  end
end

-- No state files: point HOME somewhere empty, and refuse every write.
local getenv = os.getenv
os.getenv = function(name)
  if name == "HOME" then return "/nonexistent-per-monitor-workspaces-test" end
  return getenv(name)
end
io.open = function() return nil end

local left = { id = 1, name = "DP-1", description = "Left" }
local right = { id = 2, name = "DP-2", description = "Right" }

local leftover = { id = -1337, name = "__per-monitor-workspaces-swap", monitor = left }
local mine = { id = -1338, name = "Left:1", monitor = left }
local theirs = { id = -1339, name = "Right:1", monitor = right }
-- The leftover first, so a "name:" lookup that matches two picks the wrong one.
local workspaces = { leftover, mine, theirs }
left.active_workspace, right.active_workspace = mine, theirs

-- "name:" and plain-id selectors, first match wins.
local function resolve(selector)
  local name = selector:match("^name:(.*)$")
  for _, workspace in ipairs(workspaces) do
    if (name and workspace.name == name) or (not name and tostring(workspace.id) == selector) then
      return workspace
    end
  end
end

local function action(kind) return function(args) return { kind = kind, args = args } end end

hl = {
  get_monitors = function() return { left, right } end,
  get_monitor = function(selector) return (selector == "r") and right or nil end,
  get_active_monitor = function() return left end,
  get_workspaces = function() return workspaces end,
  workspace_rule = function() end,
  dsp = {
    focus = action("focus"),
    exec_cmd = action("exec_cmd"),
    window = { move = action("window.move") },
    workspace = {
      swap_monitors = action("swap_monitors"),
      rename = action("rename"),
      change_id = action("change_id"),
      move = action("workspace.move"),
    },
  },
  dispatch = function(dispatched)
    local args = dispatched.args
    if dispatched.kind == "swap_monitors" then
      left.active_workspace, right.active_workspace = right.active_workspace, left.active_workspace
      left.active_workspace.monitor, right.active_workspace.monitor = left, right
    elseif dispatched.kind == "rename" then
      local workspace = resolve(args.workspace)
      if workspace then workspace.name = args.name end
    elseif dispatched.kind == "change_id" then
      local workspace = resolve(args.workspace)
      if workspace then workspace.id = args.id end
    end
  end,
}

local actions = dofile(here .. "../hypr/actions.lua")
actions.swap_workspaces("r")()

check("leftover keeps its name", leftover.name, "__per-monitor-workspaces-swap")
check("leftover stays put", leftover.monitor, left)
check("mine renamed for its new screen", mine.name, "Right:1")
check("mine on the right", mine.monitor, right)
check("theirs renamed for its new screen", theirs.name, "Left:1")
check("theirs on the left", theirs.monitor, left)

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("ok")
