#!/usr/bin/env python3
"""Color iTerm tabs by worktree group, and keep them colored across tmux reattaches.

iTerm's Tab Groups don't survive a `tmux -CC` reattach (iTerm never stores them in
tmux), so this colors tabs instead: every tab working in the same "group" of
worktrees gets the same color, recomputed from where its panes are — nothing to
remember, so nothing to lose on a reconnect.

Group of a worktree dir name (branches/<name> or .claude/worktrees/<name>):
  DUP-1234-fix-thing   → DUP-1234     (Linear ticket key)
  fragblitz-replay     → fragblitz    (first dash-separated word)
  haiku55              → haiku55
  main                 → no group (tab left alone)

Colors come from a fixed palette by hashing the group name, so a group usually keeps
its color; two groups open at once never share one (it steps to the next free slot). Override in ~/.config/iterm-tab-colors.json:
  {
    "colors":  {"fragblitz": "#ff8c00"},            # pin a group's color
    "aliases": {"frag": "fragblitz", "DUP-1234": "fragblitz"},  # merge groups
    "paths":   {"/Users/ramin/Work/dupe-mobile-app": "mobile"}, # non-worktree dirs
    "ignore":  ["main"]                              # never color these groups
  }

Runs as an iTerm AutoLaunch script (see install-iterm-tab-colors.sh). `--dry-run`
prints what it would do once and exits. `--group <dirname>` just prints a group.
"""
import asyncio
import hashlib
import json
import os
import re
import sys

CONFIG_PATH = os.path.expanduser("~/.config/iterm-tab-colors.json")
POLL_SECONDS = 3
WORKTREE_RE = re.compile(r"/(?:branches|\.claude/worktrees)/([^/]+)")
TICKET_RE = re.compile(r"^([A-Za-z][A-Za-z0-9]*-\d+)(?:-|$)")
DEFAULT_IGNORE = {"main", "master"}

# Distinct, saturated enough to read on a dark tab bar.
PALETTE = [
    "#e5534b", "#e0823d", "#c69026", "#57ab5a", "#2fa4a0",
    "#539bf5", "#6d6af0", "#b083f0", "#d46bb0", "#8ca34a",
]


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {}
    return {
        "colors": cfg.get("colors", {}),
        "aliases": cfg.get("aliases", {}),
        "paths": cfg.get("paths", {}),
        "ignore": set(cfg.get("ignore", [])) | DEFAULT_IGNORE,
    }


def group_of_name(name):
    m = TICKET_RE.match(name)
    if m:
        return m.group(1).upper()
    return name.split("-", 1)[0]


def group_of_path(path, cfg):
    if not path:
        return None
    for prefix, group in cfg["paths"].items():
        if path == prefix or path.startswith(prefix.rstrip("/") + "/"):
            return group
    m = WORKTREE_RE.search(path)
    if not m:
        return None
    group = group_of_name(m.group(1))
    group = cfg["aliases"].get(group, group)
    return None if group in cfg["ignore"] else group


def hex_to_rgb(hexcolor):
    hexcolor = hexcolor.lstrip("#")
    return tuple(int(hexcolor[i:i + 2], 16) for i in (0, 2, 4))


def palette_slot(group):
    return hashlib.sha1(group.lower().encode()).digest()[0] % len(PALETTE)


def assign_colors(groups, cfg, previous=None):
    """group → rgb. Pinned colors first, then whatever each group had last time
    (so opening a new group never recolors existing tabs); new groups take their
    hashed palette slot, stepping to the next free one when an open group already
    has it, so two groups on screen never share a color (while slots last)."""
    colors, taken = {}, set()
    for group in sorted(groups):
        if group in cfg["colors"]:
            colors[group] = hex_to_rgb(cfg["colors"][group])
            taken.add(colors[group])
    for group in sorted(groups):
        if group not in colors and (previous or {}).get(group) not in (None, *taken):
            colors[group] = previous[group]
            taken.add(colors[group])
    for group in sorted(g for g in groups if g not in colors):
        slot = palette_slot(group)
        for step in range(len(PALETTE)):
            rgb = hex_to_rgb(PALETTE[(slot + step) % len(PALETTE)])
            if rgb not in taken:
                break
        else:
            rgb = hex_to_rgb(PALETTE[slot])
        colors[group] = rgb
        taken.add(rgb)
    return colors


def group_of_tab(paths_active_first, cfg):
    """First pane that resolves to a group decides — the active pane wins."""
    for path in paths_active_first:
        group = group_of_path(path, cfg)
        if group:
            return group
    return None


async def tmux_pane_paths(iterm2, connection):
    """pane id (no %) → (is_active, current path), across every tmux connection."""
    panes = {}
    for tmux in await iterm2.async_get_tmux_connections(connection):
        try:
            out = await tmux.async_send_command(
                "list-panes -a -F '#{pane_id}\t#{pane_active}\t#{pane_current_path}'")
        except Exception:
            continue
        for line in out.splitlines():
            parts = line.split("\t")
            if len(parts) == 3:
                panes[parts[0].lstrip("%")] = (parts[1] == "1", parts[2])
    return panes


async def session_paths(tab, tmux_panes):
    """Current dirs of the tab's panes, active pane first."""
    active = tab.current_session
    paths = []
    for session in tab.sessions:
        path = None
        if tab.tmux_window_id not in (None, "-1"):
            pane = await session.async_get_variable("tmuxWindowPane")
            if pane is not None and str(pane) in tmux_panes:
                path = tmux_panes[str(pane)][1]
        if path is None:
            path = await session.async_get_variable("path")
        if path:
            paths.insert(0, path) if session is active else paths.append(path)
    return paths


async def set_tab_color(iterm2, tab, rgb):
    profile = iterm2.LocalWriteOnlyProfile()
    if rgb is None:
        profile.set_use_tab_color(False)
    else:
        profile.set_tab_color(iterm2.Color(*rgb))
        profile.set_use_tab_color(True)
    for session in tab.sessions:
        await session.async_set_profile_properties(profile)


async def run(connection, dry_run=False):
    import iterm2
    app = await iterm2.async_get_app(connection)
    applied = {}  # tab_id → color we last set (None = we cleared it)
    group_colors = {}  # group → color, sticky for the life of the script
    while True:
        cfg = load_config()
        tmux_panes = await tmux_pane_paths(iterm2, connection)
        tab_groups = []
        for window in app.terminal_windows:
            for tab in window.tabs:
                paths = await session_paths(tab, tmux_panes)
                tab_groups.append((tab, group_of_tab(paths, cfg), paths))
        colors = assign_colors({g for _, g, _ in tab_groups if g}, cfg, group_colors)
        group_colors.update(colors)
        for tab, group, paths in tab_groups:
            rgb = colors.get(group)
            if dry_run:
                print(f"tab {tab.tab_id} tmux={tab.tmux_window_id} group={group} color={rgb} paths={paths}")
                continue
            if rgb is None:
                # Only undo colors we set; leave hand-picked colors alone.
                if applied.get(tab.tab_id) is not None:
                    await set_tab_color(iterm2, tab, None)
                    applied[tab.tab_id] = None
            elif applied.get(tab.tab_id) != rgb:
                await set_tab_color(iterm2, tab, rgb)
                applied[tab.tab_id] = rgb
        live = {tab.tab_id for tab, _, _ in tab_groups}
        if dry_run:
            return
        for tab_id in list(applied):
            if tab_id not in live:
                del applied[tab_id]
        await asyncio.sleep(POLL_SECONDS)


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--group":
        cfg = load_config()
        for name in sys.argv[2:]:
            group = group_of_path(f"/x/branches/{name}", cfg)
            print(f"{name} → {group} {assign_colors({group}, cfg)[group] if group else ''}")
        return
    import iterm2
    dry_run = "--dry-run" in sys.argv
    iterm2.run_until_complete(lambda c: run(c, dry_run)) if dry_run \
        else iterm2.run_forever(run)


if __name__ == "__main__":
    main()
