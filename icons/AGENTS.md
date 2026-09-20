# The marks this plugin ships

Eleven CLI and agent marks, so the terminal badges do something on a machine
that has installed nothing but this plugin. Not a general icon set — see
"What belongs here" before adding anything.

```
icons/color/   drawn verbatim      claude-code  crush  gemini  hunk  opencode
icons/flat/    recoloured to theme codex  copilot  deno  gh  jq  mise
```

## Why there is no theme hook

This is the thing to understand before changing anything here, because it is
what lets these live in a plugin at all.

A mark in `flat/` is recoloured **at draw time** by the `MultiEffect` the tiles
already use, from `Color.menu.text` / `Color.menu.selectedText`. Those are live
theme roles, so a theme change is picked up immediately, with no hook, no sync
step and no restart.

The configuration this plugin came from does it the other way: a `theme-set`
hook rewrites every fill in the file to the theme's `foreground` and writes a
copy under `~/.icons`. That works for the Omarchy *menu*, which draws a plain
image and cannot recolour anything — but it bakes a fixed colour into a file,
so it needs re-running per theme and needs the shell restart that `omarchy theme
set` performs to drop Qt's image cache before the new colour lands.

Nothing here is baked. **Do not add a build step, a sync script or a hook.** If
a mark needs to follow the theme, it goes in `flat/` and that is the whole
mechanism.

## Which directory

- **`flat/`** — a silhouette. One paint, or none. It will be flattened to a
  single theme colour, so any internal tone is lost.
- **`color/`** — the mark's own colours are the point (a brand mark, or anything
  two-tone that stops making sense in one colour).

**A `flat/` mark must not have a background.** A full-bleed rect is recoloured
along with the mark and the whole thing renders as a solid block. This is not
hypothetical: `grok` was excluded from this set for exactly that, measured
rather than eyeballed. Check before adding:

```bash
rsvg-convert -w 200 -h 200 icons/flat/<name>.svg -o /tmp/c.png
magick /tmp/c.png -alpha extract -format "%[fx:minima]\n" info:
# 0     -> has transparency, safe for flat/
# ~1    -> full bleed: it has a background. color/, or strip the background.
```

Two-tone marks are the other trap. `jq` (`#111`/`#444`) and `copilot`
(`#000000`) flatten harmlessly; `opencode` carries white as a *shape* and is in
`color/` because flattening would fill those holes in.

## Adding a mark without touching this repository

A user's own marks go outside the plugin, so an `omarchy plugin update` cannot
conflict with them:

```
~/.config/omarchy/cllpse.window-switcher/icons/flat/    recoloured to theme
~/.config/omarchy/cllpse.window-switcher/icons/color/   drawn verbatim
```

Same two directories, same meaning, and they are searched **first** — before the
icon themes and before this repository — so a mark placed there wins. Everything
below about shape and which directory applies there too.

The index is built once at launch, so a newly added mark needs
`omarchy-restart-shell`. Deliberate: adding an icon is a rare act, and watching
three directories to catch it would be machinery for nothing.

## What belongs here

These resolve **last** — after the user's own directory above and after every
installed icon theme. Verified on a machine with 1364 themed
icon names: `claude-code`, `codex` and `opencode` all resolved to the user's
copies, not these. So a mark here can only ever fill a gap; it never overrides
something somebody chose.

That makes the test for adding one simple: **would a normal machine find this
icon anyway?** If yes, leave it out. Agent CLIs and young dev tools are the gap
worth filling — `docker`, `git`, `python` and the like are in every icon theme
already and would be dead weight.

Name the file after the **command**, not the vendor. `badgeFor` looks up what
the terminal title says, so `gh.svg` is found by running `gh`. Where the two
differ, the mapping lives in [`../badge-aliases.json`](../badge-aliases.json) —
`claude` → `claude-code` is there, which is why the file is `claude-code.svg`.
**Adding a mark whose command name differs means adding the alias too**, or
nothing will ever look it up. That file is watched, so an added mapping applies
on save; a new icon still needs a restart, because the icon index is built once
at launch.

## Shape

Square-ish `viewBox`, art edge-to-edge inside it, no padding. The image is drawn
with `PreserveAspectFit`, so a mark inset in its own canvas is scaled to that
canvas and renders visibly smaller than its neighbours — there is no
compensation at draw time and there must not be. Measure the **alpha** extent,
never `magick -trim`: trim removes whatever colour the corner pixel is, so on a
mark with a background it reports the inner shape and "tightening" to that crops
the background away.

## Verify

```bash
omarchy-restart-shell     # the index is built once, at launch
```

Then open the strip over a terminal running that command. A name that resolves
to nothing draws nothing, and a file that fails to parse is skipped silently —
in both cases the tile simply keeps its Nerd Font glyph, with no error anywhere.
