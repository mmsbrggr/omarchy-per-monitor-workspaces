-- Exercise the real actions with an isolated compositor and state-file model.
local function fixture(extra, duplicate_description)
  local left = { id = 1, name = "DP-1", description = "Left" }
  local right = { id = 2, name = "DP-2", description = "Right" }
  if duplicate_description then left.description, right.description = "Same", "Same" end
  local lk = duplicate_description and "Same@DP-1" or "Left"
  local rk = duplicate_description and "Same@DP-2" or "Right"
  local workspaces = {}
  local function add(name, id, monitor, layout)
    local w = { name = name, id = id, monitor = monitor, tiled_layout = layout or "dwindle",
      windows = { { grouped = true, floating = false }, { fullscreen = true } } }
    workspaces[#workspaces + 1] = w
    return w
  end
  local a = add(lk .. ":1", 101, left, "scrolling")
  local hidden = add(lk .. ":3", 103, left)
  local b = add(rk .. ":2", 202, right)
  local global = add("9", 9, left)
  local third = add("Third:1", 301, right)
  local special = add(lk .. ":8", -99, left)
  special.special = true
  left.active_workspace, right.active_workspace = a, b
  local window = { workspace = a, address = "abc" }
  local active, calls = left, 0
  local saved = { [lk .. ":1"] = "scrolling", [lk .. ":5"] = "master",
    [rk .. ":2"] = "dwindle", ["Third:1"] = "master" }
  local blocks = { [lk] = 1, [rk] = 2, Third = 3 }
  local function find(selector)
    for _, w in ipairs(workspaces) do
      if selector == "name:" .. w.name or selector == tostring(w.id) then return w end
    end
    error("missing workspace " .. tostring(selector))
  end
  local rules = {}
  local hl = {
    get_monitors = function() return { left, right } end,
    get_monitor = function(s) if s == "r" then return right elseif s == "self" then return left end end,
    get_active_monitor = function() return active end,
    get_active_window = function() return window end,
    get_workspaces = function() return workspaces end,
    workspace_rule = function(rule) rules[rule.workspace] = rule.layout end,
    dispatch = function(action) calls = calls + 1; action() end,
    dsp = { workspace = {} },
  }
  hl.dsp.workspace.rename = function(args) return function()
    local w = find(args.workspace)
    for _, other in ipairs(workspaces) do assert(other == w or other.name ~= args.name, "name collision") end
    w.name = args.name
  end end
  hl.dsp.workspace.move = function(args) return function()
    local w = find(args.workspace)
    w.monitor = args.monitor == left.name and left or right
  end end
  hl.dsp.workspace.swap_monitors = function() return function()
    local from, to = left.active_workspace, right.active_workspace
    from.monitor, to.monitor = right, left
    left.active_workspace, right.active_workspace = to, from
  end end
  hl.dsp.workspace.change_id = function(args) return function()
    local w = find(args.workspace)
    for _, other in ipairs(workspaces) do assert(other == w or other.id ~= args.id, "id collision") end
    w.id = args.id
  end end
  hl.dsp.focus = function(args) return function()
    if args.workspace then
      local w = find(args.workspace)
      active = w.monitor; active.active_workspace = w
    elseif args.window then assert(args.window == "address:abc"); active = window.workspace.monitor
    elseif args.monitor then active = args.monitor == left.name and left or right end
  end end
  local env = setmetatable({ hl = hl, os = { getenv = function() return "/mock" end } }, { __index = _G })
  env._G = env
  env.dofile = function(path)
    if path:match("/names.lua$") or path:match("/integrations.lua$") then
      return assert(loadfile(path, "t", env))()
    end
    if path:match("%.blocks.lua$") then return blocks end
    if path:match("%.layouts.lua$") then return saved end
    return { count = 5, slots = 5 }
  end
  env.io = { open = function(path)
    local chunks = {}
    return {
      write = function(_, text) chunks[#chunks + 1] = text end,
      close = function()
        local value = assert(load(table.concat(chunks), "state", "t", {}))()
        if path:match("%.layouts.lua$") then saved = value end
      end,
    }
  end }
  if extra then extra(add, a, b, left, right, blocks) end
  local actions = assert(loadfile("hypr/actions.lua", "t", env))()
  return { actions = actions, a = a, b = b, hidden = hidden, global = global, third = third,
    special = special, left = left, right = right, lk = lk, rk = rk, add = add,
    saved = function() return saved end, active = function() return active end,
    calls = function() return calls end, rules = rules }
end

local f = fixture()
local windows = f.a.windows
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Right:1" and f.a.monitor == f.right and f.a.id == 201)
assert(f.b.name == "Left:2" and f.b.monitor == f.left and f.b.id == 102)
assert(f.hidden.name == "Right:3" and f.hidden.id == 203)
assert(f.a.windows == windows and f.a.windows[1].grouped and f.a.windows[2].fullscreen)
assert(f.a.tiled_layout == "scrolling" and f.rules["name:Right:1"] == "scrolling")
assert(f.saved()["Right:5"] == "master" and not f.saved()["Left:5"])
assert(f.global.name == "9" and f.third.name == "Third:1" and f.special.name == "Left:8")
assert(f.active() == f.right and f.left.active_workspace == f.b and f.right.active_workspace == f.a)
print("ok: hidden slots, unequal sets, layouts, groups, focus and unrelated workspaces")

f = fixture(function(_, a) a.name = "Left:1#1.1" end)
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Right:1")
print("ok: deliberate swap clears guest status")

f = fixture(nil, true)
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Same@DP-2:1" and f.b.name == "Same@DP-1:2")
print("ok: identical monitor descriptions")

for _, selector in ipairs({ "missing", "self" }) do
  f = fixture(); f.actions.swap_workspace_sets(selector)()
  assert(f.calls() == 0 and f.a.name == "Left:1")
end
print("ok: absent and same monitor do nothing")

f = fixture(function(add, _, _, left) add("Left:1#1.1", 104, left) end)
f.actions.swap_workspace_sets("r")()
assert(f.calls() == 0)
print("ok: duplicate recovering slots do nothing")

f = fixture(function(add, _, _, left) add("__per-monitor-workspaces-swap-set-1", 888, left) end)
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Right:1")
print("ok: scratch names avoid existing workspaces")

f = fixture(function(add, _, _, left) add("occupied", 201, left) end)
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Right:1" and f.a.id == 101)
print("ok: occupied foreign ids remain intact")

f = fixture()
local remap, completed
f.actions.integration.register("example.consumer", { workspaces_remapped = function(mapping)
  remap = mapping
  completed = f.a.name == "Right:1" and f.a.id == 201 and f.active() == f.right
end })
f.actions.swap_workspace_sets("r")()
assert(completed and remap["Left:1"] == "Right:1" and remap["Right:2"] == "Left:2")
assert(remap["Left:5"] == "Right:5") -- an adopted home's slot may currently be empty
assert(not remap["9"] and not remap["Left:8"])
f.actions.relocate("Right:1", "Left:4", "DP-1")
assert(remap["Right:1"] == "Left:4")
print("ok: optional consumer receives final batch and hotplug relocation")

f = fixture()
f.actions.integration.register("example.consumer", { workspaces_remapped = function(mapping)
  remap = mapping
end })
f.actions.swap_workspaces("r")()
assert(remap["Left:1"] == "Right:2" and remap["Right:2"] == "Left:1")
assert(f.a.name == "Right:2" and f.b.name == "Left:1")
print("ok: existing visible swap emits final names too")

f = fixture(function(_, _, _, _, _, blocks) blocks.Right = nil end)
f.actions.swap_workspace_sets("r")()
assert(f.a.name == "Right:1" and f.a.id == 401 and f.hidden.id == 403)
assert(f.b.name == "Left:2" and f.b.id == 102)
print("ok: a screen with no id block gets one before moved slots are rehomed")

f = fixture()
f.actions.swap_workspace_sets("r")()
assert(not f.saved()["Right:3"] and not f.saved()["Left:1"] and f.saved()["Right:1"] == "scrolling")
assert(f.rules["name:Left:1"] == "dwindle" and f.rules["name:Left:5"] == "dwindle")
print("ok: defaults are not pinned and cleared slots drop their stale rule")
