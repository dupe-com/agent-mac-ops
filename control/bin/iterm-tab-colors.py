#!/usr/bin/env python3
"""Color iTerm tabs by worktree group, and keep them colored across tmux reattaches.

iTerm's Tab Groups don't survive a `tmux -CC` reattach (iTerm never stores them in
tmux, and its API can't create them), so this colors tabs instead: every tab in the
same "group" gets the same color, recomputed from what tmux already keeps — nothing
to remember, so nothing to lose on a reconnect.

A tab's group is the first word of its name, ignoring a leading emoji (tab names
live in tmux, so they survive a reattach). Nothing to configure per workstream:
  frag-quiz-mix, 🌸 frag-ask-holds, Frag Coordinator   → frag
  perfume-ranker, Perfume Coordinator                  → perfume
A group is colored once 2+ tabs share it (or one tab starts with an emoji), so plain
lone tabs stay plain. If any tab in a group starts with an emoji, the group takes that
emoji's color (EMOJI_COLORS: 🌸 pink, 🧊 ice blue, ⭐ yellow, ...); otherwise it gets a
palette slot. Only names you chose count: tmux window names, and titles you set on
non-tmux tabs, never the automatic ones (shell, process, Claude Code's status title).

Tabs whose name gives no group fall back to their worktree dir
(branches/<name> or .claude/worktrees/<name>):
  DUP-1234-fix-thing   → DUP-1234     (Linear ticket key)
  fragblitz-replay     → fragblitz    (first dash-separated word)
  haiku55              → haiku55
  main                 → no group (tab left alone)

Colors come from a fixed palette by hashing the group name, so a group usually keeps
its color; two groups open at once never share one (it steps to the next free slot). Override in ~/.config/iterm-tab-colors.json:
  {
    "colors":  {"fragblitz": "#ff8c00", "frag": "#ff8fb1"},  # pin a group's color
    "aliases": {"fragrance": "frag", "DUP-1234": "fragblitz"},  # merge groups
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
# main/master, plus names tmux's automatic-rename gives a window (its running command).
DEFAULT_IGNORE = {"main", "master", "zsh", "bash", "fish", "sh", "ssh", "tmux", "login",
                  "node", "bun", "python", "claude", "codex", "vim", "nvim"}

# Distinct, saturated enough to read on a dark tab bar.
PALETTE = [
    "#e5534b", "#e0823d", "#c69026", "#57ab5a", "#2fa4a0",
    "#539bf5", "#6d6af0", "#b083f0", "#d46bb0", "#8ca34a",
]

# Default colors for emoji group markers, so a 🌸 group comes up pink, not a random slot.
EMOJI_COLORS = {
    "🌸": "#e86aa6", "🌷": "#e86aa6", "💖": "#e86aa6", "🩷": "#e86aa6",
    "🧊": "#5cc8e6", "💧": "#539bf5", "🌊": "#539bf5", "💙": "#539bf5", "🔵": "#539bf5", "🟦": "#539bf5",
    "⭐": "#e5c03a", "🌟": "#e5c03a", "💛": "#e5c03a", "🟡": "#e5c03a", "🟨": "#e5c03a", "🍋": "#e5c03a",
    "🔥": "#e5534b", "❤": "#e5534b", "🔴": "#e5534b", "🟥": "#e5534b", "🍎": "#e5534b",
    "🍊": "#e0823d", "🧡": "#e0823d", "🟠": "#e0823d", "🟧": "#e0823d",
    "🌿": "#57ab5a", "🍀": "#57ab5a", "🌱": "#57ab5a", "💚": "#57ab5a", "🟢": "#57ab5a", "🟩": "#57ab5a",
    "🔮": "#b083f0", "💜": "#b083f0", "🍇": "#b083f0", "🟣": "#b083f0", "🟪": "#b083f0",
}


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


def emoji_of_title(title):
    """The emoji a tab name starts with ("🌸 frag-quiz" → "🌸"), or None."""
    token = (title or "").strip().split(" ", 1)[0].replace("\ufe0f", "")
    if not token or token.isascii() or any(c.isalnum() for c in token):
        return None
    # Real emoji only: Claude Code prefixes titles with symbols like ✳ ◐ ⠂ while it works.
    if token not in EMOJI_COLORS and not any(ord(c) >= 0x1F000 for c in token):
        return None
    return token


def group_of_title(title, cfg):
    """First word of the tab name, after any leading emoji ("🌸 Frag-quiz" → "frag")."""
    title = (title or "").strip()
    first = title.split(" ", 1)[0]
    if first and not first.isascii() and not any(c.isalnum() for c in first):
        if emoji_of_title(title) is None:
            return None  # a status symbol (Claude Code's ✳ ◐ ...), not a name we chose
        title = title[len(first):].strip()
    word = re.split(r"[\s\-_:/.]", title.lower(), maxsplit=1)[0]
    if len(word) < 2 or not any(c.isalpha() for c in word):
        return None
    group = cfg["aliases"].get(word, word)
    return None if group in cfg["ignore"] else group


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


def assign_colors(groups, cfg, previous=None, emoji=None):
    """group → rgb. Pinned colors first, then whatever each group had last time
    (so opening a new group never recolors existing tabs); new groups take their
    hashed palette slot, stepping to the next free one when an open group already
    has it, so two groups on screen never share a color (while slots last)."""
    colors, taken = {}, set()
    pinned = {g: EMOJI_COLORS[e] for g, e in (emoji or {}).items() if e in EMOJI_COLORS}
    pinned.update(cfg["colors"])
    for group in sorted(groups):
        if group in pinned:
            colors[group] = hex_to_rgb(pinned[group])
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


async def tmux_window_names(iterm2, connection):
    """window id (no @) → window name, across every tmux connection."""
    names = {}
    for tmux in await iterm2.async_get_tmux_connections(connection):
        try:
            out = await tmux.async_send_command("list-windows -a -F '#{window_id}\t#{window_name}'")
        except Exception:
            continue
        for line in out.splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                names[parts[0].lstrip("@")] = parts[1]
    return names


async def tab_title(tab, tmux_names):
    if tab.tmux_window_id not in (None, "-1") and str(tab.tmux_window_id) in tmux_names:
        return tmux_names[str(tab.tmux_window_id)]
    return await tab.async_get_variable("titleOverride")  # only a title you set by hand


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


async def session_color(session):
    profile = await session.async_get_profile()
    if not profile.use_tab_color or profile.tab_color is None:
        return None
    c = profile.tab_color
    return (round(c.red), round(c.green), round(c.blue))


async def set_tab_color(iterm2, tab, rgb):
    """Checks each pane's actual color rather than trusting what we set last time:
    Automatic Profile Switching (the Studio profile kicking in a few seconds after a
    reattach) swaps the pane's profile and silently drops our color."""
    profile = iterm2.LocalWriteOnlyProfile()
    if rgb is None:
        profile.set_use_tab_color(False)
    else:
        profile.set_tab_color(iterm2.Color(*rgb))
        profile.set_use_tab_color(True)
    for session in tab.sessions:
        if await session_color(session) != rgb:
            await session.async_set_profile_properties(profile)


async def run(connection, dry_run=False):
    import iterm2
    app = await iterm2.async_get_app(connection)
    applied = {}  # tab_id → color we last set (None = we cleared it)
    group_colors = {}  # group → color, sticky for the life of the script
    while True:
        cfg = load_config()
        tmux_panes = await tmux_pane_paths(iterm2, connection)
        tmux_names = await tmux_window_names(iterm2, connection)
        tab_groups = []
        group_emoji = {}
        for window in app.terminal_windows:
            for tab in window.tabs:
                paths = await session_paths(tab, tmux_panes)
                title = await tab_title(tab, tmux_names)
                group = group_of_title(title, cfg) or group_of_tab(paths, cfg)
                tab_groups.append((tab, group, paths))
                if group and emoji_of_title(title):
                    group_emoji.setdefault(group, emoji_of_title(title))
        counts = {}
        for _, group, _ in tab_groups:
            if group:
                counts[group] = counts.get(group, 0) + 1
        # A lone tab isn't a group yet, unless you marked it with an emoji or pinned it.
        groups = {g for g, n in counts.items()
                  if n >= 2 or g in cfg["colors"] or g in group_emoji}
        colors = assign_colors(groups, cfg, group_colors, group_emoji)
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
            else:
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
