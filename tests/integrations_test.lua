local create = dofile("hypr/integrations.lua")
local api = create(function(name) return "resolved:" .. name end)
assert(api.version == 1 and api.resolve_workspace("Left:1") == "resolved:Left:1")
api.notify_remap({ ["Left:1"] = "Right:1" }) -- no consumers installed
local calls = 0
api.register("example.consumer", { workspaces_remapped = function() error("old callback") end })
api.register("example.consumer", { workspaces_remapped = function(mapping)
  assert(mapping["Left:1"] == "Right:1")
  calls = calls + 1
  mapping["Left:1"] = "mutated"
end })
api.register("broken", { workspaces_remapped = function() error("adapter failed") end })
local original = { ["Left:1"] = "Right:1" }
api.notify_remap(original)
assert(calls == 1 and original["Left:1"] == "Right:1")
assert(api.errors.broken:match("adapter failed") and not api.errors["example.consumer"])
api.notify_remap({})
assert(calls == 1)
api.unregister("example.consumer")
api.unregister("broken")
api.notify_remap(original)
assert(calls == 1 and not next(api.errors))
assert(not pcall(api.register, "", {}))
assert(not pcall(api.register, "bad", {}))
print("optional integrations: standalone, reload replacement, failure isolation and removal passed")
assert(api.resolve_workspace("3") == "3" and api.resolve_workspace(7) == "7")
print("optional integrations: numeric names resolve to global workspace ids")
