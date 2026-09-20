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
- **Terminal tiles badge what is running in them** — a Claude session, a diff
  viewer, `btop` — as a small mark over the terminal's own icon.

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

## Terminal badges

A terminal tile carries a second mark for what is running inside it. The window
**title** is the only per-window signal available: a terminal running as a
single process reports the same pid for every one of its windows, so nothing
compositor-side can say which process belongs to which window. Shell integration
sets the title to the command as typed, which is the better signal anyway.

Marks are resolved by name against your installed icon themes, so a program with
no icon simply gets no badge. Claude Code is recognised by the status marker it
writes into the title.

**The alias table is opinionated.** A command is looked up by its own name, so
`btop`, `git`, `docker`, `nvim`, `npm` and most others need nothing. A handful
are mapped in `badgeFor`'s `badgeAliases` in `Hud.qml`, and some of those encode
*one particular* shell's aliases:

| title | resolves to | why |
|---|---|---|
| `diff`, `log` | `hunk` | shell aliases to the `hunk` diff viewer |
| `dash` | `gh` | alias to `gh dash` |
| `edit` | `msedit`, `ls` → `lsd` | tool aliases |
| `claude` | `claude-code` | icons are named for a desktop entry's `Icon=`, not for the command |
| `node`, `psql`, `python3`, `sqlite3`, `ytm` | `nodejs`, `postgresql`, `python`, `sqlite`, `youtube-music` | same |

If you do not alias `diff` to `hunk`, a real `diff` run gets a hunk badge. Edit
`badgeAliases` to suit your shell — it is one object near the top of `Hud.qml`.

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
