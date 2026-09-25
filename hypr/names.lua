-- The naming scheme, and nothing else.
--
-- No dependency on `hl`, so a plain Lua interpreter can load this and
-- tests/names_test.lua can exercise it. Everything that builds or recognises a
-- workspace name goes through here, so the scheme cannot drift between the
-- keybindings, the cycle ring and the screen handling.
--
--   native := <key> ":" <slot>
--   guest  := <key> ":" <slot> "#" <origin-block> "." <origin-slot>
--
-- A guest is a workspace from an unplugged screen, living as an ordinary slot
-- on whichever screen took it in. Its <key>:<slot> is where it is now; the
-- trailer is where it came back to.
--
-- The trailer carries the origin's *block*, not its key, so its shape is
-- rigidly numeric and anchored at the end. A key may contain anything --
-- `monitor_key` already produces `<description>@<connector>` for two identical
-- panels, and descriptions contain colons -- and a native name always ends
-- ":<digits>", never ".<digits>", so nothing a key can hold is mistaken for a
-- trailer.
local names = {}

names.STRIDE = 100

function names.slot(key, slot)
  return key .. ":" .. slot
end

function names.guest(key, slot, origin_block, origin_slot)
  return names.slot(key, slot) .. "#" .. origin_block .. "." .. origin_slot
end

-- base, origin block, origin slot. The origins are nil for a native name.
function names.strip(name)
  local base, block, slot = string.match(name, "^(.*)#(%d+)%.(%d+)$")
  if not base then return name, nil, nil end
  return base, tonumber(block), tonumber(slot)
end

-- The key and slot a name was built from, ignoring any trailer, or nothing for
-- a name that is not one of ours.
function names.split(name)
  local base = names.strip(name)
  local key, slot = string.match(base, "^(.*):(%d+)$")
  if not key or key == "" then return nil, nil end
  return key, tonumber(slot)
end

-- Whether a workspace name is this key's slot N, guest or not. Always asked
-- with a key already in hand, never by splitting an unknown name into parts,
-- so the key's contents cannot make it ambiguous.
function names.matches(name, key, slot)
  return (names.strip(name)) == names.slot(key, slot)
end

-- Slot N of the screen holding block B is workspace B * STRIDE + N. Past the
-- stride there is no id to give, and the caller falls back to a plain named
-- workspace.
function names.id(block, slot)
  if not block or not slot or slot < 1 or slot >= names.STRIDE then return nil end
  return block * names.STRIDE + slot
end

return names
