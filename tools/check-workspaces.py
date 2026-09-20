#!/usr/bin/env python3
"""Check every workspace against the plugin's own rules.

  1. the name parses as <key>:<slot> with an optional #<block>.<slot> trailer
  2. it sits on the screen its name calls for -- a guest included, since it
     carries its host's key
  3. its id is block * 100 + slot, for the block its host key owns
"""
import json, os, re, subprocess, sys

STRIDE = 100
TRAILER = re.compile(r"#(\d+)\.(\d+)$")
BLOCKS = os.path.expanduser(
    "~/.local/state/omarchy/mmsbrggr.per-monitor-workspaces.blocks.lua")


def hypr(what):
    return json.loads(subprocess.check_output(["hyprctl", "-j", what]))


def blocks():
    out = {}
    if not os.path.exists(BLOCKS):
        return out
    for line in open(BLOCKS, encoding="utf-8"):
        m = re.match(r'\s*\["(.+)"\]\s*=\s*(\d+),', line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def monitor_key(mon, mons):
    d = mon.get("description") or ""
    if not d:
        return mon["name"]
    twins = [o for o in mons if o["id"] != mon["id"] and (o.get("description") or "") == d]
    return d + "@" + mon["name"] if twins else d


def parse(name):
    """-> (key, slot, origin_block, origin_slot) or (None, ...) if not ours."""
    base, ob, os_ = name, None, None
    m = TRAILER.search(name)
    if m:
        base, ob, os_ = name[:m.start()], int(m.group(1)), int(m.group(2))
    m = re.match(r"^(.*):(\d+)$", base)
    if not m or not m.group(1):
        return None, None, None, None
    return m.group(1), int(m.group(2)), ob, os_


def main():
    mons, wss, blk = hypr("monitors"), hypr("workspaces"), blocks()
    key_of = {m["name"]: monitor_key(m, mons) for m in mons}

    print("blocks:")
    for k, v in sorted(blk.items(), key=lambda kv: kv[1]):
        live = [n for n, kk in key_of.items() if kk == k]
        print(f"  {v}  {k}" + (f"  -> {live[0]}" if live else "  (not attached)"))

    print("\nworkspaces:")
    problems = []
    for w in sorted(wss, key=lambda w: w["id"]):
        name, wid, on = w["name"], w["id"], w.get("monitor", "")
        if name.startswith("special"):
            continue
        key, slot, ob, os_ = parse(name)
        notes = []
        if key is None:
            notes.append("NOT-A-SLOT")
        else:
            if key_of.get(on) != key:
                notes.append(f"WRONG SCREEN (named for {key!r}, on {on})")
            if key in blk:
                want = blk[key] * STRIDE + slot
                if want != wid:
                    notes.append(f"WRONG ID (is {wid}, want {want})")
            else:
                notes.append("key has no block")
            if ob is not None and ob not in blk.values():
                notes.append(f"trailer names block {ob}, which does not exist")
        guest = "" if ob is None else f"  guest of block {ob} slot {os_}"
        flag = "  <-- " + "; ".join(notes) if notes else ""
        print(f"  id={wid:<8} {name:<46} on {on:<7}{guest}{flag}")
        if notes:
            problems.append((name, notes))

    print()
    if problems:
        print(f"{len(problems)} PROBLEM(S):")
        for n, notes in problems:
            print(f"  {n}: {'; '.join(notes)}")
        sys.exit(1)
    print("all workspaces consistent")


main()
