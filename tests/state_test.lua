-- Run: lua tests/state_test.lua
--
-- The state files under ~/.local/state/omarchy: a missing one starts empty, an
-- unreadable one is never written over, and a write replaces the file whole.
-- Loads hypr/actions.lua against a scratch HOME and just enough of `hl` for
-- creating a slot and toggling a layout.
local here = debug.getinfo(1, "S").source:match("@(.*/)") or ""

local home = os.tmpname()
os.remove(home)
local state_dir = home .. "/.local/state/omarchy"
assert(os.execute("mkdir -p '" .. state_dir .. "'"))

local real_getenv = os.getenv
os.getenv = function(name)
  if name == "HOME" then return home end
  return real_getenv(name)
end

local blocks_path = state_dir .. "/mmsbrggr.per-monitor-workspaces.blocks.lua"
local layouts_path = state_dir .. "/mmsbrggr.per-monitor-workspaces.layouts.lua"

local function read(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("a")
  file:close()
  return text
end

local function write(path, text)
  local file = assert(io.open(path, "w"))
  file:write(text)
  file:close()
end

local function exists(path)
  local file = io.open(path, "r")
  if file then file:close() end
  return file ~= nil
end

local active = { name = "BOE:1", tiled_layout = "dwindle" }
_G.hl = {
  get_workspaces = function() return {} end,
  get_monitors = function() return {} end,
  get_active_monitor = function() return { active_workspace = active } end,
  workspace_rule = function() end,
  dispatch = function() end,
}
-- Every dispatcher, nested or not -- `hl.dsp.exec_cmd(...)` and
-- `hl.dsp.workspace.rename(...)` alike -- is a no-op.
local dispatcher = setmetatable({}, { __call = function() end })
getmetatable(dispatcher).__index = function() return dispatcher end
hl.dsp = dispatcher

-- Fresh each time, the way a config parse re-reads it.
local function load_actions()
  _G.per_monitor_workspaces_count = nil
  return dofile(here .. "../hypr/actions.lua")
end

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
  end
end

-- No file yet: the first screen gets block 1, and the file is written whole.
os.remove(blocks_path)
local actions = load_actions()
check("missing file allocates", actions.selector("BOE:3"), "103")
check("missing file written", (read(blocks_path) or ""):match('%["BOE"%] = 1,') ~= nil, true)
check("no temp file left", exists(blocks_path .. ".tmp"), false)

-- A second screen keeps the first one's block, across a reload.
actions = load_actions()
check("second screen allocates", actions.selector("LG:1"), "201")
check("first screen kept", actions.selector("BOE:2"), "102")
local blocks_text = read(blocks_path) or ""
check("both blocks saved", blocks_text:match('%["BOE"%] = 1,') ~= nil and blocks_text:match('%["LG"%] = 2,') ~= nil, true)

-- Half a file, as a crash mid-write used to leave: nothing is allocated, the
-- slot falls back to its name, and the file is left exactly as it was.
local partial = '-- Written by the Per-monitor Workspaces bindings.\nreturn {\n  ["BOE"] = 1,\n  ["LG'
write(blocks_path, partial)
actions = load_actions()
check("unreadable file falls back to name", actions.selector("Dell:1"), "name:Dell:1")
check("unreadable file untouched", read(blocks_path), partial)

-- Code where data belongs does not load: the file may only return a table.
local code = 'os.exit(3)\nreturn { ["BOE"] = 1 }\n'
write(blocks_path, code)
actions = load_actions()
check("code file falls back to name", actions.selector("BOE:1"), "name:BOE:1")
check("code file untouched", read(blocks_path), code)

-- A write that cannot happen leaves the old file and no temp file behind.
write(blocks_path, 'return { ["BOE"] = 1 }\n')
assert(os.execute("chmod a-w '" .. state_dir .. "'"))
actions = load_actions()
check("unwritable dir still allocates in memory", actions.selector("LG:1"), "201")
assert(os.execute("chmod u+w '" .. state_dir .. "'"))
check("unwritable dir keeps old file", read(blocks_path), 'return { ["BOE"] = 1 }\n')
check("unwritable dir no temp file", exists(blocks_path .. ".tmp"), false)

-- Layouts: an unreadable file is not replaced by the one toggled entry.
local broken_layouts = 'return { ["LG:1"] = "scrolling",'
write(layouts_path, broken_layouts)
actions = load_actions()
actions.toggle_layout()()
check("unreadable layouts untouched", read(layouts_path), broken_layouts)

-- And a readable one gains the entry without losing the others.
write(layouts_path, 'return {\n  ["LG:1"] = "scrolling",\n}\n')
actions = load_actions()
actions.toggle_layout()()
local layouts_text = read(layouts_path) or ""
check("layouts keeps others", layouts_text:match('%["LG:1"%] = "scrolling",') ~= nil, true)
check("layouts gains toggled", layouts_text:match('%["BOE:1"%] = "scrolling",') ~= nil, true)

os.execute("rm -rf '" .. home .. "'")

if failures == 0 then print("all state tests passed") else os.exit(1) end
