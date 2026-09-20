# Working on the marks

How to add, source and fit the icons this plugin uses. The rest of the plugin is
one file, `Hud.qml`; this document is only about the marks, because they are the
part with non-obvious rules and a history of being got wrong.

```
icons/color/   drawn verbatim      claude-code  crush  gemini  hunk  opencode
icons/flat/    recoloured to theme codex  copilot  deno  gh  jq  mise
badge-aliases.json                 command name -> icon name, when they differ
```

## Where a mark can live

Three places, searched in this order. The first that answers wins.

1. **The user's own directory**, `~/.config/omarchy/cllpse.window-switcher/icons/`,
   with the same `flat/` and `color/` split. Outside this repository on purpose,
   so `omarchy plugin update` cannot conflict with it. This is where a user
   should put anything of their own — tell them this before telling them to edit
   the repo.
2. **Their installed icon themes**, via a sweep of `~/.icons`,
   `~/.local/share/icons`, the XDG data dirs and `/usr/share/pixmaps`.
3. **`icons/` here**, last. A gap-filler, never an override.

That ordering is the rule for what belongs in `icons/`: **would a normal machine
find this icon anyway?** If yes, leave it out. Measured on a machine carrying
1364 themed icon names, `claude-code`, `codex` and `opencode` all still resolved
to the user's own copies — so what is worth shipping is agent CLIs and young dev
tools, the things no icon theme carries yet. `docker`, `git` and `python` would
be dead weight.

## Why there is no theme hook

Understand this before changing anything here, because it is what lets these
live in a plugin at all.

A mark in `flat/` is recoloured **at draw time** by the `MultiEffect` the tiles
already use, from `Color.menu.text` / `Color.menu.selectedText`. Those are live
theme roles, so a theme change is picked up immediately — no hook, no sync step,
no restart.

The configuration this plugin was extracted from does it the other way: a
`theme-set` hook rewrites every fill to the theme's `foreground` and writes a
copy under `~/.icons`. That is necessary *there* because the Omarchy menu draws
a plain image and cannot recolour anything — but it bakes a colour into a file,
so it must re-run per theme and needs the shell restart `omarchy theme set`
performs to drop Qt's image cache before the new colour lands.

Nothing here is baked. **Do not add a build step, a sync script or a hook.**

## Sourcing an SVG

**Where to look, in order of how little work it leaves you:**

1. **[simple-icons](https://simpleicons.org)** — one bare `<path>`, square
   `viewBox`, no background, no gradients. Ideal for `flat/`: it is already a
   silhouette. Ships no colour, which does not matter because `flat/` is
   recoloured anyway.
2. **The project's own repository** — usually `assets/`, `docs/` or a brand page.
   Best fidelity for `color/`, and the only source for a mark whose identity is
   its colours.
3. **An installed icon theme on your own machine**, as a last resort:
   `find /usr/share/icons -name '*<name>*.svg'`. Usually a generic stand-in
   rather than the real mark.

**Never a raster.** A PNG has to be scaled to every size and goes soft; Qt
rasterises a vector at whatever size is asked for. The index only reads `.svg`,
so a `.png` dropped in is silently ignored.

**What to check before using a file.** None of this is done for you:

```bash
# 1. Does it even render?
rsvg-convert -w 96 -h 96 new.svg -o /tmp/check.png

# 2. Is there a background hiding in it? (see "Which directory")
magick /tmp/check.png -alpha extract -format "%[fx:minima]\n" info:

# 3. What paints does it carry? One, or none, means it suits flat/.
grep -oE 'fill="[^"]*"' new.svg | sort -u
```

- **Export artefacts.** Design tools emit invisible bounding rectangles —
  `<rect … fill-opacity="0">` spanning the canvas. They draw nothing today, and
  they are one edit away from becoming a solid block. Delete them.
- **Gradients and `<style>` blocks** are fine in `color/` and meaningless in
  `flat/`, where everything becomes one colour anyway.
- **Licensing is yours to check.** These are third-party brand marks. Shipping
  one in a published plugin is not the same as keeping one in a dotfiles repo.

## Which directory

- **`flat/`** — a silhouette. One paint, or none. It is flattened to a single
  theme colour, so any internal tone is lost.
- **`color/`** — the mark's own colours are the point (a brand mark, or anything
  two-tone that stops making sense in one colour).

**A `flat/` mark must not have a background.** A full-bleed rect is recoloured
along with the mark and the whole thing renders as a solid block. Not
hypothetical: `grok` is excluded from this set for exactly that, measured rather
than eyeballed.

```bash
rsvg-convert -w 200 -h 200 icons/flat/<name>.svg -o /tmp/c.png
magick /tmp/c.png -alpha extract -format "%[fx:minima]\n" info:
# 0    -> has transparency, safe for flat/
# ~1   -> full bleed: it has a background. Use color/, or delete the background.
```

Two-tone marks are the other trap. `jq` (`#111`/`#444`) and `copilot`
(`#000000`) flatten harmlessly; `opencode` carries white as a *shape*, so it is
in `color/` because flattening would fill those holes in.

## Aligning a new mark with the others

A mark is drawn at `iconDrawn` with `PreserveAspectFit`, so **it renders at
exactly the fraction of its own `viewBox` that its ink fills.** A mark inset
inside its canvas comes out visibly smaller than its neighbours. There is no
compensation at draw time and there must not be — a ratio baked into the drawing
code is a bug that took two rounds to remove. **Fix the file.**

**Measure the alpha extent, never a colour trim.** `magick -trim` trims whatever
colour the corner pixel happens to be, so on a mark with a background it eats the
background and reports the inner shape — and "tightening" to that crops the
background away. This is how `hunk` lost its box once.

```bash
python3 - icons/flat/new.svg <<'PY'
import re, subprocess, sys
p = sys.argv[1]
s = open(p, encoding="utf-8", errors="replace").read()
m = re.search(r'''viewBox\s*=\s*["']([^"']+)["']''', s)   # quote-agnostic: Inkscape single-quotes
minx, miny, w, h = [float(x) for x in re.split(r'[\s,]+', m.group(1).strip())]
S = max(1.0, 800.0 / max(w, h)); W, H = round(w*S), round(h*S)
subprocess.run(["rsvg-convert","-w",str(W),"-h",str(H),p,"-o","/tmp/_i.png"], check=True)
mn = subprocess.run(["magick","/tmp/_i.png","-alpha","extract","-format","%[fx:minima]","info:"],
                    capture_output=True, text=True).stdout.strip()
if float(mn) > 0.99:
    print("FULL BLEED - nothing transparent. Leave the viewBox alone."); raise SystemExit
bb = subprocess.run(["magick","/tmp/_i.png","-alpha","extract","-format","%@","info:"],
                    capture_output=True, text=True).stdout.strip()
iw, ih, ix, iy = [float(x) for x in re.match(r'(\d+)x(\d+)\+(-?\d+)\+(-?\d+)', bb).groups()]
f = lambda v: ("%.4f" % v).rstrip("0").rstrip(".") or "0"
print("fills %.0f%% x %.0f%% of its canvas" % (iw/W*100, ih/H*100))
if max(iw/W, ih/H) < 0.99:
    print('viewBox="%s %s %s %s"  width="%s" height="%s"'
          % (f(minx+ix/S), f(miny+iy/S), f(iw/S), f(ih/S), f(iw/S), f(ih/S)))
else:
    print("already edge-to-edge on its long axis - leave it")
PY
```

Apply the printed `viewBox` **and the `width`/`height` with it** — if they
disagree with the new canvas, rsvg reintroduces the original aspect and the
change does nothing.

**Two guards, and a mark with a background needs both.** The full-bleed test
catches a background reaching the canvas edge. It does *not* catch one with
**rounded corners** — `hunk`'s box has `rx="2"`, so it reads as 0 min-alpha. The
99%-coverage test is what stops that one: its visible extent is still 100% × 100%,
so there is nothing to tighten. Never drop one check on the grounds that the
other covers it.

**Reference points.** Every mark in `icons/` fills ≥99% of its long axis; the
check above reports 0 failures across all eleven. `deno`, `gh` and `mise` were
tightened to get there. For comparison, on the configuration this came from
Ghostty filled 99% × 100% while Figma filled 52% × 78% — which is exactly how
much smaller Figma looked.

A wide wordmark correctly fills its long axis and stays short — `jq` is 99% × 55%.
That is the logo, not padding. Do not stretch it.

## Naming, and the alias file

Name the file after the **command**, not the vendor: `badgeFor` looks up what
the terminal title says, so `gh.svg` is found by running `gh`.

Where the two differ, the mapping lives in
[`badge-aliases.json`](badge-aliases.json) — `claude` → `claude-code` is there,
which is why the file is `claude-code.svg`. **Adding a mark whose command name
differs means adding the alias too**, or nothing will ever look it up.

That file is watched, so an added mapping applies on save. A new *icon* still
needs a restart, because the index is built once at launch — deliberate, since
adding an icon is a rare act and watching three directories to catch it would be
machinery for nothing.

## Verify

```bash
omarchy-restart-shell
```

Then open the strip over a terminal running that command. A name that resolves to
nothing draws nothing, and a file that fails to parse is skipped silently — in
both cases the tile keeps its Nerd Font glyph, with no error anywhere. So "no
badge appeared" means one of: wrong filename, missing alias, malformed SVG, or no
restart.
