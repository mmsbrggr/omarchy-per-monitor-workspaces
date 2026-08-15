# Per-monitor Workspaces for Omarchy

Independent workspaces per monitor, the way dwm and awesome do it: `SUPER+3`
always means *this screen's third workspace*, never "jump to whichever monitor
happens to own workspace 3".

![Two bars, each showing its own screen's workspaces](docs/bar.png)

Omarchy's defaults bind `SUPER+1..0` to global workspaces. On a multi-head setup
that means pressing `SUPER+1` on your external screen silently moves focus to
the laptop, and the screen you were looking at appears to do nothing. This
plugin replaces that with one independent set of workspaces per monitor, plus a
bar indicator that shows only the workspaces of the screen it is drawn on.

Nothing is hardcoded: no monitor names, no workspace rules, no ids. Every
monitor gets its own set the first time you press a slot key on it — one screen
or five, docked or not, including monitors the config has never seen.

## Requirements

- Omarchy 4 (Quattro), with the built-in bar
- Hyprland with the Lua config (tested on 0.56.2)

## Install

```sh
omarchy plugin add https://github.com/mmsbrggr/omarchy-per-monitor-workspaces.git --enable
```

The widget takes the built-in `omarchy.workspaces` slot in your bar, at exactly
the position it already sat in, and gives it back if you ever disable this one.

Then add the keybindings by appending one line to `~/.config/hypr/bindings.lua`:

```lua
pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.mmsbrggr.per-monitor-workspaces/hypr/init.lua")
```

Hyprland reloads on save. `dofile` rather than `require` because plugin
directories are named `<author>.<name>` and the dot breaks Lua module paths, and
`pcall` so that removing the plugin without editing this file costs you the
per-monitor bindings rather than the rest of your config.

Omarchy's plugin installer deliberately runs no install hooks — it only clones
files — so the keybinding half cannot install itself. That is also why it is one
explicit line you can read before running it.

## Keys

| Key | Does |
| --- | --- |
| `SUPER + 1..5` | Focus this monitor's workspace 1..5 |
| `SUPER + SHIFT + 1..5` | Move the window there and follow it |
| `SUPER + SHIFT + ALT + 1..5` | Move the window there, keep focus |
| `SUPER + TAB` / `SUPER + SHIFT + TAB` | Cycle workspaces on this monitor |
| `SUPER + scroll` | Same, with the wheel |
| `SUPER + CTRL + TAB` | Back to this monitor's previous workspace |

### Across monitors

| Key | Does |
| --- | --- |
| `SUPER + CTRL + ALT + ←↑↓→` | Focus the monitor in that direction |
| `SUPER + CTRL + SHIFT + ←↑↓→` | Send the window to that monitor and follow |
| `SUPER + SHIFT + ALT + ←↑↓→` | Send everything on this workspace to that monitor |
| `SUPER + CTRL + ALT + SHIFT + ←↑↓→` | Swap this screen's windows with that monitor's |

These move **windows, never workspaces**. A workspace named for one screen while
living on another is the parked state — Hyprland's answer to an unplugged
monitor, fine as a temporary fact and wrong as something a keybinding does on
purpose. So every workspace stays on the screen it is named for, and what
travels is what is on it. Windows land on whatever the target screen is
currently showing, which is where you were looking when you decided to throw
them over there.

`SUPER + SHIFT + ALT + ←↑↓→` is Omarchy's own "move workspace to monitor"
binding, rebound for that reason: stock, it relocates the container and leaves
the target screen permanently displaying another screen's workspace.

Directions are physical, so there is nothing to identify and no monitor numbers
anywhere — you already know which screen is on your left. Omarchy's
`CTRL + ALT + TAB` still cycles monitors if you prefer that.

### On the bar

Left-click a slot to focus it, right-click to send the focused window there
without following, scroll to cycle. The bar acts on the screen it is drawn on,
so scrolling the second monitor's bar moves that screen, not the focused one.

Cycling walks this monitor's slots in order, `1 → 2 → … → 5 → 1`, whether or not
a slot has been used yet — Hyprland deletes a workspace the moment its last
window closes, so a cycle over only the live ones would usually be a cycle of
one.

Omarchy's `SUPER + 6..0` bindings are removed: with per-monitor slots they could
only pull you to another screen. `SUPER + CTRL + TAB` is rebound for the same
reason — Omarchy points it at Hyprland's global `previous` selector, which
returns to the last workspace focused *anywhere*, so from a second screen it
drags focus to whichever monitor that was. It now uses the per-monitor variant.

Everything else — scratchpad, moving a workspace to another monitor, the bar
panels on `SUPER + CTRL + 1..9` — is left untouched.

## Configuration

Slot count lives in one place:

```lua
per_monitor_workspaces_count = 8  -- before the dofile line, defaults to 5
```

`hypr/init.lua` publishes the count it bound, and the bar follows it, so the
keys and the dots cannot disagree. If you run the widget without the
keybindings, it falls back to its own `count` setting:

```sh
omarchy bar set io.github.mmsbrggr.per-monitor-workspaces count 8 --json
```

(`--json` matters — without it the value is stored as a string.) Omarchy 4 has
no settings UI for plugin widgets yet, so that or editing the `count` key on the
widget's `shell.json` entry are the way in.

## How it works

Workspaces are named `<monitor>:<slot>`, and the target is resolved when the key
is pressed, from `hl.get_active_monitor()`. So the same key means a different
workspace on each screen, and Hyprland creates a missing one on the monitor you
are looking at.

Monitors are keyed by description rather than connector name: `DP-2` and `DP-3`
can swap on replug, which would swap two monitors' workspaces along with them.
Two panels of the same model that report no serial describe themselves
identically, and one key for both would mean one shared set; those get the
connector name appended to break the tie. Only the ambiguous ones pay that
price, so a monitor that describes itself uniquely keeps a key that survives a
replug. The trade-off is that plugging in an identical twin renames both, and
the workspaces they had keep the old name — still on screen, still reachable,
just parked (see below).

The widget resolves its own screen through the bar window it is drawn in — bar
surfaces are built per monitor — and shows the slots for that screen only,
labelled by position, so the underlying names never surface. It marks that
monitor's active workspace rather than the globally focused one, so every bar
reports where its own screen is sitting.

### Parked workspaces

Disconnecting a monitor is Hyprland's normal behaviour: its workspaces are
parked on a surviving screen, each keeping its own identity. Those show up in
the bar after the numbered slots, in the accent colour, as a display glyph
rather than a number — the slot number they carry belongs to the screen they
came from, and printing it would put a second "4" after this screen's "5".
Hover names the screen and the slot. `SUPER + TAB` reaches them too, so nothing
on the monitor is unreachable while its own screen is away. When the screen
comes back, Hyprland takes them with it and the extra dots disappear.

Any global numbered workspace that something else created on the monitor shows
up the same way.

### When the keybindings are missing

Installing the widget without the `bindings.lua` line leaves the one state you
cannot diagnose from the bar: per-monitor slots drawn while `SUPER+N` still
switches global workspaces. `hypr/init.lua` writes a marker into
`$XDG_RUNTIME_DIR` when it loads, stamped with the Hyprland instance, and the
widget shows a warning glyph when it is missing. Hover it for what to do.

## Uninstall

```sh
omarchy plugin remove io.github.mmsbrggr.per-monitor-workspaces
```

That puts `omarchy.workspaces` back where this widget was sitting. Then remove
the `pcall(dofile, ...)` line from `~/.config/hypr/bindings.lua`.

## License

MIT. The bar widget is derived from Omarchy's built-in workspace widget.
