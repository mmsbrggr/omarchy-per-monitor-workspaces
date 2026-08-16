-- Per-monitor workspaces: actions plus the default keys.
--
-- This is the convenience entry point, and what the README tells you to load:
--
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.mmsbrggr.per-monitor-workspaces/hypr/init.lua")
--
-- It is two halves, and you can take just the first. hypr/actions.lua defines
-- what can be done and binds nothing; hypr/bindings.lua is one opinionated set
-- of keys for those actions. To keep your own keys, load actions.lua alone --
-- its header shows how.
--
-- The bar widget is what actually provides per-monitor workspaces; this file
-- only puts keys on them, and takes its slot count from the widget.

local here = debug.getinfo(1, "S").source:match("@(.*/)") or ""

dofile(here .. "actions.lua")
dofile(here .. "bindings.lua")
