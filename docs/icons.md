# Terminal icons

Part of the [Window Switcher](../README.md).

A terminal tile carries a second icon for what is running inside it. The window
**title** is the only per-window signal available: a terminal running as a
single process reports the same pid for every one of its windows, so nothing
compositor-side can say which process belongs to which window. Shell integration
sets the title to the command as typed, which is the better signal anyway.

Icons are resolved by name against your installed icon themes, and the plugin
ships [102 of its own](../icons) — app marks and CLI/agent logos, including
Ghostty's — so both the tiles and the process icons do something out of the box.
Those resolve **last**, after your own and after every installed theme, so they
only ever fill a gap. A program with no icon anywhere simply gets none. Claude
Code is recognised by the status marker it writes into the title.

**An icon is drawn exactly as it is.** No recolouring, no tinting, no theme
adaptation — the file is the source of truth for its own appearance, and the only
thing the plugin ever changes about one is its `viewBox`, so that an icon fills
its box the way Ghostty's does and they render at the same size. One shipped
mark, `pi`, is inset to 74% of its box instead, deliberately: a solid blocky mark
reads heavier than the thin-stroked ones beside it.

**Where icons are looked up**, in order — first hit wins:

1. `~/.config/omarchy/cllpse.window-switcher/icons/` — yours.
2. `~/.icons/cllpse-flat/apps/` — **optional, and almost certainly not on your
   machine.** It is where [omarchy-cllpse-macos](https://github.com/cllpse/omarchy-cllpse-macos),
   the configuration this plugin was extracted from, syncs app marks for the
   Omarchy menu; reading it means that setup shows one mark in both places. If
   the directory does not exist — the normal case — the plugin simply builds its
   index without it. Nothing else here reaches outside the plugin.
3. Your installed icon themes.
4. [`icons/`](../icons) here, last.

**To add your own**, drop an SVG into
`~/.config/omarchy/cllpse.window-switcher/icons/` — outside the plugin, so an
update cannot conflict with it — and restart the shell. Name it after the window
class or the command; if the name and the icon differ, add a line to
[`icon-aliases.json`](../icon-aliases.json). [`AGENTS.md`](../AGENTS.md) has the
details, including how to scale a new one to match.

**The alias table is opinionated, and it is yours to edit.** It lives in
[`icon-aliases.json`](../icon-aliases.json) at the root of this repository, not
in the QML. A command is looked up by its own name, so `btop`, `git`, `docker`,
`nvim`, `npm` and most others need nothing at all. The file exists for the two
cases where the name and the mark disagree.

**1. Your shell aliases it.** The title carries what you *typed*, not what ran:
if `diff` runs `hunk diff`, the title says `diff` while the icon is called
`hunk`. The shipped entries of this kind encode *one particular* shell's
aliases — edit them to match yours, or delete the ones you do not use. If you
do not alias `diff` to `hunk`, a real `diff` run gets hunk's icon until you
remove that line.

**2. The icon is named for something else.** Icons are named for a desktop
entry's `Icon=` value rather than for a command, so a Claude session's mark is
`claude-code.svg` and `claude` has to be pointed at it.

**3. The program writes its own title.** A TUI can overwrite the title with a
marker of its own, and then the first word is not a command at all. Pi titles its
window `π - <directory>` — one OSC 0 write at startup, measured rather than
assumed — so the key looked up is literally `π`. Claude Code does the same thing
and is deliberately *not* in this file: its marker tracks session state and
changes, so the QML recognises the whole family of markers at once instead.

All 18 shipped entries, which is the whole file:

| title | resolves to | why |
|---|---|---|
| `diff`, `log` | `hunk` | shell aliases to the `hunk` diff viewer |
| `dash` | `gh` | alias to `gh dash` |
| `edit` | `msedit` | tool alias |
| `claude` | `claude-code` | named for the desktop entry, not the command |
| `convert`, `magick` | `imagemagick` | same |
| `ffprobe` | `ffmpeg` | same |
| `node`, `psql`, `python3`, `redis-cli`, `sqlite3`, `ytm` | `nodejs`, `postgresql`, `python`, `redis`, `sqlite`, `youtube-music` | same |
| `brew`, `pacman` | `homebrew`, `arch-pacman` | named for the project, not the command; both marks shipped for a while with no alias, so nothing looked them up. `sudo pacman` still titles itself `sudo` and gets no icon |
| `youtuimusic` | `youtube-music` | a YouTube Music TUI with no mark of its own; it borrows the service's |
| `π` | `pi` | Pi overwrites the title with `π - <directory>`, so its marker is the first word |

**The format is strict JSON** — one object of `"command": "icon-name"`, and
nothing else. It carries no comments, because JSON has none; this table is
where the entries are explained instead. Trailing commas are rejected too.

**Saved edits apply immediately**: the file is watched, so no restart is needed.
An edit that does not parse leaves the previous mappings in force and logs a
warning rather than silently dropping every icon — and the warning says the file
is strict JSON, since a stray comment is the likeliest way to land there.

One caveat, since the file is tracked: `omarchy plugin update` pulls this
repository, so local edits can conflict. `git checkout icon-aliases.json`
inside the plugin directory takes the shipped version back if that happens.
