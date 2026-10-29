# Site favicons

Part of the [Window Switcher](../README.md).

A browser tile carries the favicon of the site it is showing, in the corner slot
a terminal's process icon uses.

> **This gives the switcher read access to your browsing history database.**
> There is no way to do this without it. A browser window exposes no URL — not
> in its class, not in its title, not on the Wayland handle — so the only way
> to know which site it is on is the page title, joined against the browser's
> own history. The favicon then comes from the browser's favicon cache. Both
> are SQLite files in your profile, which is why the plugin ships
> [`favicons.py`](../favicons.py); QML cannot read them.
>
> What it does with that access: opens both databases read-only, looks up
> **only the page titles currently on screen**, and returns an image over a
> pipe. It never enumerates history, and with no browser window open it does
> not run at all — not even the sweep that looks for profiles.
>
> **It writes nothing into your profile**: no database, no journal, no WAL, and
> not even the read-mark an ordinary read-only SQLite connection leaves behind
> in a `-shm`. Which URI achieves that depends on whether a browser currently
> has the file open — `mode=ro&immutable=1` where none does, since it takes no
> lock at all and that is the only way to read a running Chromium;
> `mode=ro&readonly_shm=1` where one does and a WAL may hold rows the main file
> does not. [`favicons.py`](../favicons.py)'s `ro()` carries the measurements
> behind that choice.
>
> **How often it reads:** once for each page title that appears on screen, and
> up to three times for one it cannot resolve. A browser does not write a visit
> to its history when it happens — Chromium commits about 10s later — so the
> first look at a page you have just opened finds nothing, and a retry 12s
> after that is what makes the badge appear at all. A title that resolves is
> never asked about again, and one that has failed three times is dropped.
>
> But the access is broader than the use, and only the code keeps it narrow: if
> you would rather not grant it, delete `favicons.py` and browser tiles fall
> back to their own icon.

**Which browsers.** Both families, found by the two database files in a
profile rather than by name — `History`+`Favicons` for Chromium, Chrome, Brave,
Vivaldi, Edge, Helium; `places.sqlite`+`favicons.sqlite` for Firefox, LibreWolf,
Zen, Waterfox, Floorp. That is the only browser-specific knowledge in the file:
a table of two rows, four strings each. A third family is a row, not a code
path. The sweep descends three levels below a hidden top-level directory of
`$HOME`, which reaches `.config/chromium/Default` and
`.mozilla/firefox/x.default` as well as Brave's deeper
`.config/BraveSoftware/Brave-Browser/Default`. A flatpak profile sits two levels
deeper still and is deliberately not found.

**What it cannot do**, each ending as no badge rather than a wrong one: an
incognito window, a local file or a `chrome://` page, a profile the sweep does
not reach, and a fork whose title suffix is unknown. A page you have only just
opened is a fifth case but a passing one — it has no badge until the browser
commits the visit, and the retry above is what picks it up. Installed web apps
are excluded on purpose — their class already carries the host, so the tile is
already the site's icon.

**Accuracy is a property of your history.** Over the 200 most recent pages in
the profile this was built against, every one resolved and 145 resolved the
byte-identical icon the true URL would have; the 55 that differed were one
session of CDN-hosted images sharing titles with their origin site, where the
origin's mark is the better answer. Unread-count prefixes (`(12) Inbox`) are
stripped on both sides. Firefox is verified against a reconstructed profile
rather than a real one, its WAL included: with a live writer holding 398 of 399
rows uncheckpointed, all 399 are read and not one byte of the profile changes.
