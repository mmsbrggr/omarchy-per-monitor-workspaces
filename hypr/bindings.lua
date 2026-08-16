-- Per-monitor workspaces: the default key bindings.
--
-- Nothing here is required. If you would rather choose your own keys, load
-- hypr/actions.lua instead of hypr/init.lua and bind what you like -- the
-- actions are the part that matters, these are one opinionated arrangement of
-- them. See the header of actions.lua for how.

local pmw = _G.per_monitor_workspaces
  or dofile((debug.getinfo(1, "S").source:match("@(.*/)") or "") .. "actions.lua")

local COUNT = pmw.count

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
  o.bind("SUPER + " .. key, "Switch to workspace " .. slot, pmw.focus_slot(slot))
  o.bind("SUPER + SHIFT + " .. key, "Move window to workspace " .. slot, pmw.move_to_slot(slot))
  o.bind(
    "SUPER + SHIFT + ALT + " .. key,
    "Move window silently to workspace " .. slot,
    pmw.move_to_slot_silently(slot)
  )
end

-- Omarchy cycles with the e+1/e-1 selectors, which walk workspaces across every
-- monitor and cannot order named ones anyway. Cycle within this monitor instead.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
hl.unbind("SUPER + mouse_down")
hl.unbind("SUPER + mouse_up")

o.bind("SUPER + TAB", "Next workspace", pmw.cycle(1))
o.bind("SUPER + SHIFT + TAB", "Previous workspace", pmw.cycle(-1))
o.bind("SUPER + mouse_down", "Scroll active workspace forward", pmw.cycle(1))
o.bind("SUPER + mouse_up", "Scroll active workspace backward", pmw.cycle(-1))

-- Omarchy's "Former workspace" uses the global `previous` selector, which
-- returns to the last workspace focused anywhere -- so from a second screen it
-- drags focus to whichever monitor that was, the same jump SUPER+N exists to
-- prevent. Hyprland's per-monitor variant does what the key reads like.
hl.unbind("SUPER + CTRL + TAB")
o.bind("SUPER + CTRL + TAB", "Former workspace", hl.dsp.focus({ workspace = "previous_per_monitor" }))

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
    pmw.focus_monitor(direction.selector)
  )
  o.bind(
    "SUPER + CTRL + SHIFT + " .. direction.key,
    "Move window to " .. direction.label .. " monitor",
    pmw.send_window(direction.selector)
  )

  hl.unbind("SUPER + SHIFT + ALT + " .. direction.key)
  o.bind(
    "SUPER + SHIFT + ALT + " .. direction.key,
    "Move workspace to " .. direction.label .. " monitor",
    pmw.send_workspace(direction.selector)
  )

  o.bind(
    "SUPER + CTRL + ALT + SHIFT + " .. direction.key,
    "Swap workspace with " .. direction.label .. " monitor",
    pmw.swap_workspaces(direction.selector)
  )
end
