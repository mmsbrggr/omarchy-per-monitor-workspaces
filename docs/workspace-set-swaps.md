# Swap complete workspace sets

`swap_workspace_sets` exchanges all existing slots between two monitors,
including hidden slots: left slot 1 becomes right slot 1, left slot 2 becomes
right slot 2, and the reverse. Whole workspaces move, preserving their tiling
arrangements, groups and window state. Layout preferences for unused slots
also exchange. Focus follows the workspace set sent from the focused monitor.

With the Lua actions loaded, bind it in your own configuration, for example:

```lua
o.bind("SUPER + CTRL + ALT + SHIFT + PAGEDOWN", "Swap all workspaces with right monitor",
  per_monitor_workspaces.swap_workspace_sets("r"))
o.bind("SUPER + CTRL + ALT + SHIFT + PAGEUP", "Swap all workspaces with left monitor",
  per_monitor_workspaces.swap_workspace_sets("l"))
```

The existing arrow shortcut still swaps only the visible workspaces. Unequal
sets exchange the slots that exist without creating every unused slot. Guest
workspaces keep their host slot number and stop returning to their former
monitor, because this is an intentional move. Global and special workspaces
are excluded. A missing target monitor or duplicate slots during hotplug
recovery leave everything in place.

## Tests

```sh
lua tests/names_test.lua
lua tests/swap_sets_test.lua
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=generic QT_QUICK_BACKEND=software \
  /usr/lib/qt6/bin/qmltestrunner -input tests
```

The Lua swap checks simulate the compositor. Native tiling, focus and
hotplug behavior were also checked live on two monitors.
