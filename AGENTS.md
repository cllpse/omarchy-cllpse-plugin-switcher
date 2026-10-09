# Working on the icons

`icons/` holds 100 marks — app icons and CLI/agent logos, including Ghostty's own.

**Five are theme-dependent and it is known.** `cups`, `gh` and `jq` are
near-black and barely register on a dark card; `mise` is near-white and `grok`
pure white, and those two barely register on a light one. They were authored as
silhouettes for a surface that repaints them, and nothing here recolours.
Measured, not guessed: compositing each over #1E1E1E (the black three) or
#FFFFFF (the white two) shifts the card by under 0.02 — 0.010 at most (`jq`),
0 for `grok` and `mise`. Giving them a colour means editing artwork, which is a
decision, not a fix.

`grok` was listed with the black ones while it carried a full-canvas `#0a0a0a`
rect behind its white slash. That rect was a bug, not artwork: the repainting
surface it was authored for rewrote rect and slash to one colour and drew a
solid square. It was deleted on 2026-10-09 and the `viewBox` tightened to the
slash, in this copy and the dotfiles repo's alike, which is what moved it to
the white side.

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

**One icon is deliberately not, and it is the only one.** `pi` is inset to
74% × 74% of its box, because a solid blocky mark reads heavier than the
thin-stroked marks beside it. The measurement below prints a `viewBox` for it
exactly as it does for a mark that was padded by accident, so that line is the
script working rather than a finding: `19.8187 19.8187 111.3625 111.3625`, the
file's own `20 20 111 111` plus one rasterised pixel of antialiasing a side.
The file says so itself, in an XML comment above its `<svg>` tag — the one
thing in an icon file that is neither artwork nor `viewBox`. **A comment must not contain `--`**: XML forbids a double hyphen
inside one, and both QtSvg and rsvg then reject the whole document, which here
means a tile that silently keeps its Nerd Font glyph.

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
s = re.sub(r'<!--.*?-->', '', s, flags=re.S)   # a comment can quote a viewBox: pi's does
# The ROOT's viewBox, not the first in the file. Quote-agnostic: Inkscape single-quotes.
m = re.search(r'''<svg\b[^>]*?\bviewBox\s*=\s*["']([^"']+)["']''', s, re.S)
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

It reads the **root `<svg>` element's** `viewBox`, with comments stripped
first. It used to take the first `viewBox=` anywhere in the file, and `pi`'s
comment quotes one, so for `pi` it printed `34.5688 34.5688 81.8625 81.8625` —
a box from the wrong origin and scale. The other 99 marks read the same either
way.

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

Name the file after what it identifies: for an app tile, the `Icon=` of the
desktop entry that names the window's class (`co.anysphere.cursor.svg`), or the
class itself where no entry names it; the **command** for a terminal's process
icon (`gh.svg`).

`iconFor()` tries the class against the drop-in index first, but then follows
`classIndex` — entries keyed by `StartupWMClass` and file id — to the entry's
`Icon=` before it tries the class anywhere else. So with Cursor installed, its
tile (class `cursor`, `cursor.desktop`: `StartupWMClass=Cursor`,
`Icon=co.anysphere.cursor`) draws whatever `co.anysphere.cursor` resolves to —
the dotfiles repo's copy under `~/.icons/cllpse-color/apps/` on that machine
(verified live, 2026-10-09), the vendor's own
`/usr/share/pixmaps/co.anysphere.cursor.png` on one without it, since installed
icons outrank `icons/` here — and `cursor.svg` is never what it draws. That file
is reached as a process icon for a terminal titled `cursor`, or where no
installed entry names the class.

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
soft — Chromium caches nothing above 32px and the badge draws at 21px
(`processIconSize`, at text size 13), 42 device px at a pixel ratio of 2; it
was 36 before the tile icon moved to the `display` token.

**The constraint that matters more than any other: this reads a browsing-history
database.** Three rules keep that defensible, and each is a real limit on what
may be changed here:

- **Read-only, permanently, and it writes nothing into a profile.** Not the
  database, not a journal, not a WAL, and not the read-mark an ordinary
  read-only SQLite connection leaves in a `-shm`. A change needing a lock, a
  copy or a writable handle is the wrong change. The cost is that a read racing
  a write can be inconsistent, which lands as a miss, already a handled state.

  Two URIs get there and `ro()` picks between them on one fact — whether a
  `-shm` exists beside the database, i.e. whether some process has it open.
  **Neither URI is safe alone, so do not simplify this to one.**
  `immutable=1` takes no lock, which is the only way to read a **running
  Chromium** (it holds History and Favicons `locking_mode = EXCLUSIVE`;
  measured, a plain `mode=ro` gets SQLITE_BUSY and nothing else) — but it
  ignores the `-wal` by design, so on **Firefox** it silently returns the
  database as of the last checkpoint: 1 row of 399 against a live writer.
  `readonly_shm=1` reads the WAL and, unlike a bare `mode=ro`, leaves the
  `-shm` byte-identical. It is gated on the `-shm` rather than preferred,
  because with none present it cannot open the database at all and — if there
  is no `-wal` either — **creates a zero-byte one in the profile** before
  failing. That gate is the only thing standing between this and a write.

  `timeout=0` is part of the same rule: Python's default is a five **second**
  busy timeout, and the locked-Chromium path walks into it — 5008ms against
  0.17ms. Never open one of these without it.
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
100k rows). The one place that frugality is deliberately relaxed is the retry:
a browser commits a visit ~10s after the navigation (measured 10.07s on
Chromium — it is `kCommitIntervalSeconds`), so a title gets up to three looks
12s apart before being given up on. Without it the first look is the only look
and it always misses, which is what made most pages carry no badge at all. Not worth doing: C-module imports (`posix`, `binascii`, `_sqlite3`)
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
