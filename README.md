# Window Switcher

A macOS-style window switcher for the [Omarchy](https://omarchy.org) 4
(Quickshell) shell. Hold `SUPER`, tap `TAB` to cycle a horizontal strip of open
windows, release to focus the highlighted one. Click a tile to focus it, or drag
one onto another workspace to move it there.

![The switcher strip](preview.png)

- **Tiles are grouped by workspace** and sorted by on-screen position, with a
  rule between groups. Empty workspaces get a tile of their own, so a blank
  desktop is reachable without a separate keybind.
- **`SUPER+TAB` alternates**, the way every Alt-Tab does: the first tap lands on
  the window you came from, further taps in the same gesture walk the strip.
  The tiles are never reordered to do it.
- **Drag a tile onto a workspace group** to move that window there, landing at
  whichever boundary you drop on — before its first window, after its last, or
  between any two. Dropping on a tile's own group re-arranges it in place.
- **A terminal tile shows what is running in it** — a Claude session, a diff
  viewer, `btop` — as a small icon over the terminal's own.

## Requirements

- Omarchy 4 (Quattro) and its Quickshell-based shell
- Hyprland, for `hyprctl` and the global-shortcuts protocol
- A Nerd Font as the shell's menu font, for the tile glyphs

## Install

```bash
omarchy plugin add https://github.com/cllpse/omarchy-window-switcher.git --enable
```

**Then install the keybinds — the plugin does nothing without them.** It has no
input of its own: it registers three global shortcuts and waits. Append
[`hypr/window-switcher-bindings.lua`](hypr/window-switcher-bindings.lua) to
`~/.config/hypr/bindings.lua`:

```bash
cat ~/.config/omarchy/plugins/cllpse.window-switcher/hypr/window-switcher-bindings.lua \
  >> ~/.config/hypr/bindings.lua
hyprctl reload
```

That file binds `SUPER+TAB` / `SUPER+SHIFT+TAB`, polls for the release of
`SUPER` to commit, and switches Omarchy's `SUPER + mouse:272` "Move window" bind
off while the strip is up so that clicks and drags reach the switcher instead.
It unbinds Omarchy's default `SUPER+TAB` (next workspace) first.

Optionally append
[`hypr/window-switcher-looknfeel.lua`](hypr/window-switcher-looknfeel.lua) to
`~/.config/hypr/looknfeel.lua` for blur and a map fade matching Omarchy's own
panels:

```bash
cat ~/.config/omarchy/plugins/cllpse.window-switcher/hypr/window-switcher-looknfeel.lua \
  >> ~/.config/hypr/looknfeel.lua
hyprctl reload
```

## Remove

```bash
omarchy plugin remove cllpse.window-switcher
```

Then delete the blocks you appended from `~/.config/hypr/bindings.lua` and
`~/.config/hypr/looknfeel.lua` and run `hyprctl reload`. Removing the bindings
block restores Omarchy's own `SUPER+TAB` and `SUPER + mouse:272` behaviour,
since this plugin only ever *rebinds* them at the end of your config. The plugin
writes nothing else: no state files, no edits to `shell.json` beyond the entry
`omarchy plugin add --enable` makes for you.

## Using it

| | |
|---|---|
| `SUPER+TAB` | open the strip / step forward |
| `SUPER+SHIFT+TAB` | step back |
| release `SUPER` | focus the highlighted window |
| move the pointer | highlight the tile under it |
| `SUPER` + click a tile | focus that window |
| `SUPER` + click beside the card | dismiss without switching |
| `SUPER` + drag a tile | move that window to the workspace you drop on |

Dragging shows a caret at the boundary the window would land on. Drop outside
the card and nothing happens. The strip auto-scrolls when you drag against
either edge.

Arranging works on a workspace laid out as one row or one column. A workspace
mixing horizontal and vertical splits has no ordering a single strip of tiles
could point at, and none is invented — the move simply stops when the layout
declines it.

## Terminal icons

A terminal tile carries a second icon for what is running inside it. The window
**title** is the only per-window signal available: a terminal running as a
single process reports the same pid for every one of its windows, so nothing
compositor-side can say which process belongs to which window. Shell integration
sets the title to the command as typed, which is the better signal anyway.

Icons are resolved by name against your installed icon themes, and the plugin
ships [75 of its own](icons) — app marks and CLI/agent logos, including
Ghostty's — so both the tiles and the process icons do something out of the box.
Those resolve **last**, after your own and after every installed theme, so they
only ever fill a gap. A program with no icon anywhere simply gets none. Claude
Code is recognised by the status marker it writes into the title.

**An icon is drawn exactly as it is.** No recolouring, no tinting, no theme
adaptation — the file is the source of truth for its own appearance, and the only
thing the plugin ever changes about one is its `viewBox`, so that every icon
fills its box the way Ghostty's does and they all render at the same size.

**To add your own**, drop an SVG into
`~/.config/omarchy/cllpse.window-switcher/icons/` — outside the plugin, so an
update cannot conflict with it — and restart the shell. Name it after the window
class or the command; if the name and the icon differ, add a line to
[`icon-aliases.json`](icon-aliases.json). [`AGENTS.md`](AGENTS.md) has the
details, including how to scale a new one to match.

**The alias table is opinionated, and it is yours to edit.** It lives in
[`icon-aliases.json`](icon-aliases.json) at the root of this repository, not
in the QML. A command is looked up by its own name, so `btop`, `git`, `docker`,
`nvim`, `npm` and most others need nothing. What the file is for is the two
cases where the name and the mark disagree — and some of the shipped entries
encode *one particular* shell's aliases:

| title | resolves to | why |
|---|---|---|
| `diff`, `log` | `hunk` | shell aliases to the `hunk` diff viewer |
| `dash` | `gh` | alias to `gh dash` |
| `edit` | `msedit`, `ls` → `lsd` | tool aliases |
| `claude` | `claude-code` | icons are named for a desktop entry's `Icon=`, not for the command |
| `convert`, `magick` | `imagemagick` | same |
| `ffprobe` | `ffmpeg` | same |
| `node`, `psql`, `python3`, `redis-cli`, `sqlite3`, `ytm` | `nodejs`, `postgresql`, `python`, `redis`, `sqlite`, `youtube-music` | same |

That is all 15 shipped entries.

If you do not alias `diff` to `hunk`, a real `diff` run gets a hunk icon —
delete that line. The file takes whole-line `//` comments, and **saved edits
apply immediately**: it is watched, so no restart is needed. An edit that does
not parse leaves the previous mappings in force and logs a warning rather than
silently dropping every icon.

One caveat, since the file is tracked: `omarchy plugin update` pulls this
repository, so local edits can conflict. `git checkout icon-aliases.json`
inside the plugin directory takes the shipped version back if that happens.

## Theming

The card binds the active theme's menu colours and Hyprland's `decoration:rounding`,
so it tracks your theme with nothing to configure. Three sizes can be pinned
from a theme's `[spacing]` section if you want them different:

| token | default | what it sets |
|---|---|---|
| `switcher-cell-width` | 150 | tile width |
| `switcher-group-gap` | 36 | extra space between workspace groups |
| `switcher-row-height` | 104 | tile height floor |

## Notes

- The plugin runs inside the existing Omarchy shell process and starts no
  Quickshell of its own. It shells out to `hyprctl` to focus and move windows,
  and once at startup to index your icon themes.
- Windows on special workspaces (the scratchpad) are deliberately not listed.
- Live edits inside a plugin directory may not auto-reload; run
  `omarchy-restart-shell` after changing files here.

## License

MIT — see [LICENSE](LICENSE).
