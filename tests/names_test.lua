-- Run: lua tests/names_test.lua
local here = debug.getinfo(1, "S").source:match("@(.*/)") or ""
local names = dofile(here .. "../hypr/names.lua")

local failures = 0
local function check(label, got, want)
  if got ~= want then
    failures = failures + 1
    print(string.format("FAIL %s: got %s, want %s", label, tostring(got), tostring(want)))
  end
end

check("slot", names.slot("BOE", 3), "BOE:3")
check("guest", names.guest("BOE", 11, 2, 2), "BOE:11#2.2")

local base, block, slot = names.strip("BOE:3")
check("strip plain base", base, "BOE:3")
check("strip plain block", block, nil)

base, block, slot = names.strip("BOE:11#2.2")
check("strip guest base", base, "BOE:11")
check("strip guest block", block, 2)
check("strip guest slot", slot, 2)

-- A key that itself ends in something trailer-shaped must not be eaten.
base, block = names.strip("weird#1.2:3")
check("strip false positive", base, "weird#1.2:3")
check("strip false positive block", block, nil)

local key, n = names.split("BOE:3")
check("split plain key", key, "BOE")
check("split plain slot", n, 3)

-- The critical one: a guest splits to the HOST, not to its origin.
key, n = names.split("BOE:11#2.2")
check("split guest key", key, "BOE")
check("split guest slot", n, 11)

key, n = names.split("Dell Inc: X@DP-1:4")
check("split key with colon and at", key, "Dell Inc: X@DP-1")
check("split key with colon and at slot", n, 4)

key, n = names.split("3")
check("split global key", key, nil)
check("split global slot", n, nil)

key, n = names.split(":3")
check("split empty key key", key, nil)
check("split empty key slot", n, nil)

check("matches host", names.matches("BOE:11#2.2", "BOE", 11), true)
check("matches not origin", names.matches("BOE:11#2.2", "BOE", 2), false)
check("matches plain", names.matches("BOE:3", "BOE", 3), true)

check("id", names.id(2, 5), 205)
check("id low", names.id(2, 0), nil)
check("id high", names.id(2, 100), nil)

if failures == 0 then print("all names tests passed") else os.exit(1) end
