# Dragging

Part of the [Window Switcher](../README.md). Drag a tile onto a workspace group, onto another window's tile, or drag a workspace's handle.

## Moving a window

Drag a tile onto a workspace group to move that window there, landing at whichever
boundary you drop on: before the group's first window, after its last, or
between any two. Dropping on a tile's own group re-arranges it in place.

Dragging shows a caret at the boundary the window would land on. Drop outside
the card and nothing happens. The strip auto-scrolls when you drag against
either edge.

Arranging works on a workspace laid out as one row or one column. A workspace
mixing horizontal and vertical splits has no ordering a single strip of tiles
could point at, and none is invented — the move simply stops when the layout
declines it. Dropped onto a window instead, there is a second offer that needs
no ordering, below.

## Splitting a window

Over another window's tile, a drop is aimed at that window rather than at a
boundary. The tile is cut into thirds: the top one puts the dragged window above
it, the bottom one below it, and the middle one beside it, on whichever half of
the tile the pointer is over. A bar along the tile's top or bottom edge, at the
weight of the rule between workspace groups, or the caret at its side, marks
where the window will go. The dragged chip turns translucent so it does not hide
that bar. The window takes half of the one it splits, which is how dwindle opens
any window, and it can come from any workspace and go to any workspace.

Hyprland has nothing that says "open this window against that one", so the
plugin arranges for the path a window takes into the layout to pick the target
and the side, then floats the dragged window and tiles it again to send it
through. That path works differently on the workspace you are looking at and on
the others, so there are two ways in, both one `hyprctl eval` chunk:

- **On screen**, a new window splits the focused one, on the side `preselect`
  names. So the target is focused for the moment, the side preselected, and
  focus handed back to the window that had it. `preselect` reaches only the
  visible workspace, which is why this one cannot be used elsewhere.
- **Off screen**, it splits the window nearest the pointer, and with dwindle's
  `smart_split` on, the pointer's place relative to that window's centre picks
  the side. So `smart_split` is switched on for the moment and the pointer put
  inside the target on that side, then both go back as they were. Nothing is
  focused and the workspace you are on does not change.

Hyprland runs a chunk in one pass, so nothing is drawn with the target focused,
the window floating or the pointer moved. With `cursor:no_warps` off, focusing a
window warps the pointer to it, and the chunk puts the pointer back either way.
Floating windows have no split to join, so their tiles keep the boundary drop,
as do workspaces with a fullscreen window and workspaces using a layout other
than dwindle, whose splits neither way can steer.

## Where each window sits

While a drag is over a workspace, a blue dot on each of its tiles marks where
that window is on it, and no other tile shows one: in a corner for a quarter, at
the middle of an edge for a half — top, bottom, left, right. It is measured
against the area the workspace's tiled windows cover between them, so gaps and
the bar drop out. A window whose dot would fall in the centre of the tile gets
none — one alone on its workspace, or in the middle of both axes — and nor does
a floating or fullscreen one. The colour is the theme's accent.

## Re-arranging workspaces

The workspace under the pointer shows a handle: a small blue pill floating under
the card, centred on that workspace's tiles. It fades in as the pointer reaches
a workspace and out as it leaves, as quickly as the strip's own fades but on
Omarchy's gentler OutCubic curve so that it reads as a fade (60ms), and
pointing below
the card counts, so the pointer can travel down from the tiles to it. Carry it
along the row and let go between two other groups, and that workspace moves
there; the ones in between shift one place along to make room.
The rule between the groups where it would land lights up in the accent, or a
mark at the card's edge before the first group or after the last. The places
either side of the group you are carrying would put it back where it is, so
they show nothing. While it is carried, the group's tiles fade the way a
dragged tile does. An empty workspace is a place like any other: drag one to
the front and every workspace before it moves up a number.

**Using a handle never switches.** From the moment one is pressed, releasing
`SUPER` closes the strip without focusing anything, so you stay on the window
and the workspace you were on. A strip opened with `SUPER+TAB` starts on the
window you came from, and without this the release would go there. The
highlight moves to where you are and hover leaves it alone, so the strip shows
what the release will do. A `TAB`, a click on a tile, or picking up a tile
makes it a choice again. The workspace on screen stays on screen through a
re-arrange; only its number changes if it moved.

**The places keep their numbers, and the workspaces move between them.**
Whatever lands in the third place becomes workspace 3, so `SUPER+3` and the
bar's third pip go to it. On a strip of 1 to 5 plus an 8, the last place is 8,
so dragging 8 to the front makes the old 5 the new 8.

**Nothing about a workspace changes but its number**: not its windows, not its
layout or its split sizes, not whether it is the one on screen. No window moves.
Hyprland 0.56 can renumber a workspace in place (`hl.dsp.workspace.change_id`),
and the plugin renumbers every workspace that changes place in one
`hyprctl eval` chunk. Each goes to a temporary number first, since Hyprland
refuses a number another workspace holds and in a re-arrange every target is
held by a workspace that is itself moving. Everything is checked before
anything changes, and if any step is refused the chunk puts every number back.

Two things have to be carried along by hand:

- **The layout.** Omarchy's layout toggle (`omarchy-hyprland-workspace-layout-toggle`,
  `SUPER+L` by default) keeps dwindle or scrolling per workspace *number*, as a
  Hyprland rule and as a file in `~/.local/state/omarchy/workspace-layouts/`.
  A renumbered workspace would take its new number's layout, and a layout
  change rebuilds a workspace's tiling from scratch. So the plugin sets each
  workspace's layout on its new number where that differs, and moves the files
  to match, written in the toggle's own format, so a config reload keeps the
  layout too. This is the only file the plugin writes, and only when one of
  those files is involved or a layout differs from `general:layout`.
- **Omarchy's bar.** Quickshell 0.3.1 ignores Hyprland's `changeworkspaceid`
  event, so on its own the bar would go on showing the old numbers occupied and
  the wrong one lit. After each renumbering the plugin refreshes Quickshell's
  windows, workspaces and monitors, which is what the bar reads. What it cannot
  do is remove a workspace that stopped existing — Quickshell only does that on
  a destroy event or a config reload — so a pip above 5 for a workspace the
  re-arrange emptied stays in the bar, dimmed, until the next reload or the next
  visit to it. Pips 1 to 5 are drawn regardless, so nothing shows there.
