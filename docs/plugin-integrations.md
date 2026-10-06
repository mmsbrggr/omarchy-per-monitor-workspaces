# Plugin integration API

Other Hyprland Lua plugins can resolve per-monitor workspaces and be notified
when this plugin moves or swaps them. The API is optional. The core imports no
other plugin, adds no dependencies or keybindings, and behaves the same when no
consumer is registered.

Each consumer owns its adapter. There is no plugin discovery service or module
installation system. The provider exposes capabilities; an installed consumer
can opt in, and falls back to its ordinary behavior when they are absent.

## Contract

`per_monitor_workspaces.integration` provides API version `1`:

* `resolve_workspace(name)` uses the same resolver as `selector(name)`, including
  guest slots. A numeric name returns that global workspace id. Otherwise it may
  allocate a block or register a default-name rule. It is not a read-only query.
* `register(id, module)` attaches a module with a `workspaces_remapped(mapping)`
  callback. Registering the same ID replaces the previous callback.
* `unregister(id)` disconnects that module.
* `errors[id]` holds the most recent callback error; a later successful callback
  clears it. A broken consumer does not interrupt other consumers or the core.

Callbacks receive a separate table mapping old workspace names to final names.
The provider sends a single batch after a workspace-set swap, a visible swap,
or a relocation through `relocate` (including the widget's hotplug recovery).
Scratch names are never published. Configured empty slots are included in a
set swap, because a consumer may reference a slot that is currently empty.
Apply each mapping once; following chained entries would undo a two-way swap.

Notifications describe actions performed through this plugin. Native workspace
renames made outside it do not emit this callback. This first version does not
provide a shared QML workspace snapshot.

```lua
local pmw = per_monitor_workspaces
local api = pmw and pmw.integration
if api and api.version == 1 then
  api.register("my.plugin", {
    workspaces_remapped = function(mapping)
      -- Update the consumer's saved workspace references once per mapping.
    end,
  })
end
```

## Load order

`per_monitor_workspaces` exists once this plugin's Lua has loaded. A consumer
that loads earlier should register again after both plugins have loaded, for
example from a function the user calls at the end of their Hyprland Lua
configuration. Registration is idempotent per ID. Repeat it on every config
reload: callbacks belong to the current Lua state.

## Verification

```sh
lua tests/names_test.lua
lua tests/integrations_test.lua
lua tests/swap_sets_test.lua
```

Offline checks cover standalone use, registration replacement, removal, callback
failure isolation, final-name batch delivery and hotplug relocation.
