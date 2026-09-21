#!/usr/bin/env python3
"""Resolve a browser window's title to the favicon of the page it is showing.

Two modes, both called by Hud.qml:

    favicons.py --discover
        prints `<family><TAB><profile dir>` for every browser profile found.
        Run once at launch, like the plugin's other index sweeps.

    favicons.py [--profile <family> <dir>]... -- <title>...
        prints `<index><TAB><mime><TAB><base64>` for every title it resolved,
        and nothing at all for the ones it did not. Indices, not titles, come
        back, so a tab or a stray character in a title cannot break the parse.
        With no --profile it discovers for itself, which is slower but keeps
        the script usable by hand.

Why a helper at all, and why this shape:

  * A browser window's title is its PAGE's title, not its URL -- unlike a
    terminal's, which shell integration sets to the command as typed. There is
    no URL anywhere on the Wayland toplevel, so the only join available is
    title -> the browser's own history DB -> URL -> its favicon DB.
  * Those are SQLite, so it cannot be done in QML: Quickshell has no SQL type
    of any kind (its whole Io module is FileView, Process, Socket, SocketServer,
    DataStream, IpcHandler, JsonAdapter, StdioCollector, SplitParser), and
    QtQuick.LocalStorage only opens a database keyed by an md5 of a NAME, under
    the engine's own path, read-write. Neither can be pointed at a profile.
  * It is read-only throughout: the URIs carry mode=ro and immutable=1, which
    opens O_RDONLY, takes no lock, and writes nothing -- not even a journal --
    so it cannot disturb a running browser. The cost of immutable=1 is that a
    read racing a write can come back inconsistent; that lands as a miss, which
    is already a state this handles.
  * It reads ONLY the titles it was handed. It never enumerates history, and
    nothing it reads is written anywhere: the image goes back over stdout as
    base64 and lives in the shell's memory as a data: URL. The plugin still
    writes no files.

Everything here degrades to silence. No profile, no `sqlite3` module, a locked
database, an unreadable row: stdout is empty and every tile keeps the icon it
would have had.
"""

import base64
import os
import sys

try:
    import sqlite3
except ImportError:
    # python's sqlite3 module is an OPTIONAL dependency on Arch ("sqlite: for a
    # default database integration"), so this import is not guaranteed even
    # where python is. Silence is the documented degradation.
    sys.exit(0)


# -- The only browser-specific knowledge in this file ------------------------
#
# A family is four facts: the two filenames that identify one of its profiles,
# and the two queries. Everything below is family-agnostic, so supporting
# another browser is a row here rather than a code path -- which is the whole
# reason this is a table and not an if/else.
#
# Both families genuinely have the same shape: a history database holding
# (title, url) and a separate favicon database mapping page URLs to image
# blobs. That is not a coincidence to rely on for a third family, but where it
# holds, the row is four strings.
#
# `{}` in an icon query is filled with `= ?` or `like ? escape '\'`; see
# icon_for. Nothing else is ever interpolated -- every value is a bound
# parameter, because every value here ultimately comes from a window title,
# which is a string a remote web page chose.
FAMILIES = {
    # Chromium, Chrome, Brave, Vivaldi, Edge, Helium -- one row covers the
    # whole fork tree, since they all inherit this layout unchanged.
    "chromium": {
        "history": "History",
        "icons": "Favicons",
        "url_sql": "select url from urls where title = ?"
                   " order by last_visit_time desc limit 1",
        "icon_sql": "select fb.image_data from icon_mapping im"
                    " join favicon_bitmaps fb on fb.icon_id = im.icon_id"
                    " where im.page_url {} and fb.image_data is not null"
                    " order by fb.width desc limit 1",
    },
    # Firefox, LibreWolf, Zen, Waterfox, Floorp -- likewise.
    "firefox": {
        "history": "places.sqlite",
        "icons": "favicons.sqlite",
        "url_sql": "select url from moz_places where title = ?"
                   " order by last_visit_date desc limit 1",
        "icon_sql": "select i.data from moz_pages_w_icons p"
                    " join moz_icons_to_pages ip on ip.page_id = p.id"
                    " join moz_icons i on i.id = ip.icon_id"
                    " where p.page_url {} and i.data is not null"
                    " order by i.width desc limit 1",
    },
}


def _mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def discover():
    """Every browser profile under $HOME, as (family, dir) pairs.

    Found by its marker files rather than by its name. A directory holding
    `History` and `Favicons` is a Chromium profile whatever the fork is called;
    one holding `places.sqlite` and `favicons.sqlite` is a Firefox profile. So
    ~/.config/chromium/Default, ~/.mozilla/firefox/x.default, ~/.librewolf/x
    and ~/.zen/x are all found with no list of browsers anywhere in this file.

    Two bounds keep it cheap, both measured rather than guessed:

      * Only HIDDEN top-level directories of $HOME are entered. Every browser
        profile on Linux lives under one, and the visible half of a home
        directory is where the large trees are.
      * Depth 2 below each. That reaches .config/chromium/Default and
        .mozilla/firefox/x.default, which is every native install. A flatpak
        profile at .var/app/<id>/.mozilla/firefox/x sits deeper and is missed;
        depth 4 finds it and costs 4x, which is not a trade to make silently.

    ONE scandir per directory, reused for both the marker test and the descent
    -- measured at 10.5ms against 23.4ms for the obvious version that stats the
    two markers and then lists the directory again in order to recurse.
    """
    found = []

    def sweep(base, depth):
        try:
            entries = list(os.scandir(base))
        except OSError:
            return
        names = {e.name for e in entries}
        for family, spec in FAMILIES.items():
            if spec["history"] in names and spec["icons"] in names:
                found.append((family, base + "/"))
                return          # a profile is not a container for profiles
        if not depth:
            return
        for e in entries:
            if e.is_dir(follow_symlinks=False):
                sweep(e.path, depth - 1)

    home = os.path.expanduser("~")
    try:
        top = list(os.scandir(home))
    except OSError:
        return found
    for e in top:
        if e.name.startswith(".") and e.is_dir(follow_symlinks=False):
            sweep(e.path, 2)
    # Most recently written history first, so the profile actually being
    # browsed in answers before a stale one. A miss there falls through to the
    # next, so the order is a preference rather than a decision.
    found.sort(key=lambda fp: _mtime(fp[1] + FAMILIES[fp[0]]["history"]),
               reverse=True)
    return found


def ro(path):
    return sqlite3.connect("file:" + path + "?mode=ro&immutable=1", uri=True)


def like_escape(s):
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def strip_count(t):
    """Drop a leading unread-count badge: "(12) Inbox" -> "Inbox".

    Gmail, YouTube and most chat apps put a live counter in front of the title,
    and history holds whatever it was at the last visit. Left alone, an exact
    match fails for precisely the sites someone is most likely to keep a window
    on.
    """
    if not t.startswith("("):
        return t
    close = t.find(") ")
    if close < 0:
        return t
    inner = t[1:close]
    # Digits and the separators a formatted count uses -- "(2,125)", "(1.2k)".
    if inner and all(c.isdigit() or c in ",.k+" for c in inner):
        return t[close + 2:]
    return t


def url_for(hist, sql, title):
    """The most recently visited URL whose page title is `title`."""
    bare = strip_count(title)
    attempts = [(sql, title)]
    if bare != title:
        attempts.append((sql, bare))
    # The LIKE exists only for the count badge: it matches a recorded
    # "(9) Inbox" against a live "(12) Inbox". It runs LAST because "(%) " is a
    # wildcard and the exact forms above are not.
    attempts.append((sql.replace("title = ?", "title like ? escape '\\'"),
                     "(%) " + like_escape(bare)))
    for q, arg in attempts:
        row = hist.execute(q, (arg,)).fetchone()
        if row and row[0]:
            return row[0]
    return None


def icon_for(fav, sql, url):
    """The largest stored image for `url`, as bytes.

    Two steps, and the second does most of the work: a browser maps a favicon
    to the page URLs it was seen on, so an exact hit needs that exact page to
    have been visited before. Falling back to any page on the same host is what
    makes a first visit to a known site resolve -- measured over the 200 most
    recent history entries in a real Chromium profile, 11 hit exactly and 189
    through the host.
    """
    row = fav.execute(sql.format("= ?"), (url,)).fetchone()
    if row:
        return row[0]
    parts = url.split("/")
    host = parts[2] if len(parts) > 2 else ""
    if not host:
        return None
    # Bounded on both sides so "a.com" cannot match "evil-a.com" or
    # "a.com.evil.net": the scheme separator anchors the left, the path the
    # right.
    like = "%://" + like_escape(host) + "/%"
    row = fav.execute(sql.format("like ? escape '\\'"), (like,)).fetchone()
    return row[0] if row else None


def mime_of(blob):
    """The media type of a stored favicon, by magic bytes, or None.

    Sniffed rather than assumed, because the two families differ: Chromium
    re-encodes every favicon to PNG, while Firefox stores what the site served
    -- ICO and SVG both turn up. A data: URL carries its own type, so guessing
    wrong means Qt refuses the image with nothing in the log to say why.
    Unknown returns None and the icon is dropped, which is the honest outcome:
    a mislabelled image would not render either.
    """
    if not blob:
        return None
    b = bytes(blob[:16])
    if b.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if b.startswith(b"\x00\x00\x01\x00"):
        return "image/vnd.microsoft.icon"
    if b.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if b.startswith(b"GIF87a") or b.startswith(b"GIF89a"):
        return "image/gif"
    if b.startswith(b"RIFF") and bytes(blob[8:12]) == b"WEBP":
        return "image/webp"
    head = bytes(blob[:512]).lstrip()
    if head.startswith(b"<svg") or head.startswith(b"<?xml"):
        return "image/svg+xml"
    return None


def resolve(family, prof, pending):
    """Resolve what it can from one profile.

    Returns (resolved, still_pending). An unresolved title is handed on rather
    than dropped: the window may belong to a different browser than the one
    whose history happened to be written most recently.
    """
    spec = FAMILIES.get(family)
    if spec is None:
        return [], pending
    resolved, still = [], []
    try:
        hist = ro(prof + spec["history"])
        fav = ro(prof + spec["icons"])
    except sqlite3.Error:
        return [], pending
    try:
        for i, (idx, title) in enumerate(pending):
            try:
                url = url_for(hist, spec["url_sql"], title)
                blob = icon_for(fav, spec["icon_sql"], url) if url else None
                mime = mime_of(blob)
            except sqlite3.Error:
                # A locked or mid-write database gives up on this profile
                # wholesale rather than row by row, and the rest go to the next.
                still.extend(pending[i:])
                break
            if mime:
                resolved.append((idx, mime, blob))
            else:
                still.append((idx, title))
    finally:
        hist.close()
        fav.close()
    return resolved, still


def parse_args(argv):
    """--profile <family> <dir> pairs, then --, then the titles."""
    profiles, titles, i = [], [], 0
    while i < len(argv):
        if argv[i] == "--profile" and i + 2 < len(argv):
            profiles.append((argv[i + 1], argv[i + 2]))
            i += 3
        elif argv[i] == "--":
            titles = argv[i + 1:]
            break
        else:
            titles = argv[i:]
            break
    return profiles, titles


def main():
    argv = sys.argv[1:]
    if argv[:1] == ["--discover"]:
        for family, path in discover():
            sys.stdout.write("%s\t%s\n" % (family, path))
        return

    profiles, titles = parse_args(argv)
    pending = list(enumerate(titles))
    if not pending:
        return
    # No --profile means this was run by hand; pay for discovery rather than
    # answer nothing. Hud.qml always passes them, having swept once at launch.
    if not profiles:
        profiles = discover()

    out = []
    for family, prof in profiles:
        if not pending:
            break
        got, pending = resolve(family, prof, pending)
        out.extend(got)
    for idx, mime, blob in out:
        sys.stdout.write("%d\t%s\t%s\n"
                         % (idx, mime, base64.b64encode(blob).decode("ascii")))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Nothing here is worth failing a shell over, and stderr from a Process
        # this plugin spawns has nowhere to go. A miss is already handled.
        sys.exit(0)
