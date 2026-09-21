# Working on the icons

`icons/` holds 75 marks — app icons and CLI/agent logos, including Ghostty's own.
`icon-aliases.json` maps a command name to an icon name when the two differ.

**An icon is the source of truth for its own appearance.** The plugin draws it
exactly as it is: no recolouring, no tinting, no theme adaptation, nothing
stripped. Whoever placed the file decided how it should look, and on which
themes it works.

**The only thing you may change in a file is its `viewBox`.** Everything below
the `<svg>` tag is untouchable.

## Scaling a new icon

A mark is drawn with `PreserveAspectFit`, so **it renders at exactly the
fraction of its own `viewBox` that its ink fills.** A mark inset inside its
canvas comes out visibly smaller than its neighbours. There is no compensation
at draw time and there must not be — a ratio baked into the drawing code is a
bug that took two rounds to remove.

The reference is Ghostty's own icon, `viewBox="0 0 27 32"`, ink filling
99% × 100% of it. Every icon here matches that: ink edge-to-edge in its own box,
so all of them render at the same size.

**Measure the alpha extent, never a colour trim.** `magick -trim` trims whatever
colour the corner pixel happens to be, so on a mark with a background it eats the
background and reports the inner shape — and "tightening" to that crops the
background away. That is how `hunk` lost its cream box once. Its box is part of
the logo.

```bash
python3 - icons/new.svg <<'PY'
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
    print("FULL BLEED - already edge to edge. Leave the viewBox alone."); raise SystemExit
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

Rewrite **only the `<svg>` tag** with what it prints, and take the `width`/`height`
with the `viewBox` — if they disagree with the new canvas, rsvg reintroduces the
original aspect and the change does nothing.

Two guards, and a mark with a background needs both. The full-bleed test catches
a background reaching the canvas edge. It does *not* catch one with **rounded
corners** — `hunk`'s box has `rx="2"`, so it reads as 0 min-alpha; the
99%-coverage test is what stops that one. Never drop one on the grounds that the
other covers it.

A wide wordmark correctly fills its long axis and stays short — that is the
logo, not padding. Do not stretch it.

## Sourcing an SVG

1. **The project's own repository** — usually `assets/`, `docs/` or a brand page.
   Best fidelity, and the only source for a mark whose identity is its colours.
2. **[simple-icons](https://simpleicons.org)** — one bare `<path>`, square
   `viewBox`, no background. Note it declares **no colour at all**, and SVG's
   default fill is black: that is invisible on a dark card. Give it an explicit
   fill that works on the themes you care about before shipping it.
3. **An installed icon theme**, as a last resort:
   `find /usr/share/icons -name '*<name>*.svg'`. Usually a generic stand-in.

**Never a raster.** The index reads only `.svg`, so a `.png` dropped in is
silently ignored.

Check before using a file:

```bash
rsvg-convert -w 96 -h 96 new.svg -o /tmp/check.png     # does it render?
magick /tmp/check.png -alpha extract -format "%[fx:minima]\n" info:   # background?
```

- **Export artefacts.** Design tools emit invisible bounding rectangles —
  `<rect … fill-opacity="0">` spanning the canvas. They draw nothing, and they
  defeat the scaling measurement above by making the ink look edge-to-edge.
  Delete them; this is the one exception to leaving artwork alone.
- **It has to work on the themes you use.** Nothing recolours it. A pure-black
  mark disappears on a dark card and a pure-white one on a light card — that is
  the file's problem to solve, not the plugin's.

## Where an icon can live

Searched in order; first hit wins.

1. `~/.config/omarchy/cllpse.window-switcher/icons/` — the user's own, outside
   this repository so an `omarchy plugin update` cannot conflict with it.
2. `~/.icons/cllpse-flat/apps/` — an **optional integration**, not a
   dependency: the dotfiles repo this plugin came from syncs marks there for the
   Omarchy menu. Missing on any other machine, which costs nothing — `find`
   writes one stderr line and the index is built from what remains. It is the
   only path in the plugin that points outside itself; do not add another.
3. Their installed icon themes.
4. `icons/` here, last. A gap-filler, never an override.

## Naming, and the alias file

Name the file after what it identifies: a window's **class** for an app tile
(`cursor.svg`), or the **command** for a terminal's process icon (`gh.svg`).

Where the name and the icon disagree, the mapping lives in
[`icon-aliases.json`](icon-aliases.json) — `claude` → `claude-code` is there,
which is why the file is `claude-code.svg`. **Adding an icon whose command name
differs means adding the alias too**, or nothing will ever look it up.

That file is **strict JSON** — an object of `"command": "icon-name"` and nothing
else. It has no comments, because JSON has none, so a mapping cannot explain
itself in place: the table in [`README.md`](README.md) is where the shipped
entries are documented, and **a mapping you add belongs in that table too**, or
the next person has no way to know what it is for or whether it is safe to
delete.

That file is watched, so an added mapping applies on save. A new *icon* needs a
restart: the index is built once at launch.

## Verify

```bash
omarchy-restart-shell
```

A name that resolves to nothing draws nothing, and a file that fails to parse is
skipped silently — in both cases the tile keeps its Nerd Font glyph, with no
error anywhere. So "no icon appeared" means one of: wrong filename, missing
alias, malformed SVG, or no restart.

## Favicons are not icons, and nothing above applies to them

A browser tile's badge is the site's favicon, pulled from the browser's own
profile by [`favicons.py`](favicons.py). It shares the corner slot and the
draw-it-as-it-comes rule with a process icon and **nothing else in this
document**: it comes from a database rather than a file, it is never on disk
(it reaches QML as a `data:` URL), it has no name to alias, and there is no
`viewBox` to scale. Do not add one to `icons/`. Do not "fix" one that looks
soft — Chromium caches nothing above 32px and the badge draws at 36 device px.

**The constraint that matters more than any other: this reads a browsing-history
database.** Three rules keep that defensible, and each is a real limit on what
may be changed here:

- **Read-only, permanently.** Both databases open `mode=ro&immutable=1` —
  `O_RDONLY`, no lock, no journal, no writes — against files a running browser
  owns. A change needing a lock, a copy or a writable handle is the wrong
  change. The cost is that a read racing a write can be inconsistent, which
  lands as a miss, already a handled state.
- **Only the titles it is handed.** It must never enumerate history. The
  difference between "reads the page titles of the windows on screen" and
  "reads your browsing history" is the entire reason this is acceptable in a
  plugin, and only this code keeps the two apart.
- **Every value is a bound parameter.** They all originate in a window title,
  which is a string a remote web page chose.

**Adding a browser is a row in `FAMILIES`** — two filenames that identify a
profile, and two queries. Discovery finds profiles by those filenames, so no
browser is named anywhere else and every fork works for free. An `if family ==`
branch below that table is what this design exists to avoid.

**On performance, since the obvious answers are wrong.** A query is ~17ms and
the SQL in it is 0.43ms; the rest is Python starting. Already done: `-S`,
`import glob` removed (7.5ms), the profile sweep hoisted out of the query into
a once-per-session scan in `Hud.qml` whose result is passed in with `--profile`
(leaving it per-query made the generic version *slower* than the Chromium-only
one it replaced — 31.2ms against 25.6), and the
QML asks only about titles it has **no answer for** (safe because the title is
the key, and necessary because `urls.title` has no index: 5.2ms per title at
100k rows). Not worth doing: C-module imports (`posix`, `binascii`, `_sqlite3`)
save 2.1ms for private APIs; the `sqlite3` CLI starts in 1ms but cannot bind a
parameter; a persistent helper answers in 0.40ms but costs 13.8MB resident.

That sweep is started on **first sight of a browser window**, not in
`Component.onCompleted` like the other three scans: a session with no browser
open then never pays the 28ms, and never has its home directory walked at all.
Activating the switcher spawns nothing — a lookup is triggered by a page title
changing.

Everything degrades to silence — no profile, no `sqlite3` module, a locked
database, an unparseable row. Empty stdout means every tile keeps the icon it
would have had.
