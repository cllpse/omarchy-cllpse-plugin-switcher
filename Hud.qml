import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// A macOS-style window switcher rendered as a horizontal strip.
//
// Purely visual, keyboard-driven HUD (panel kind, no keyboard grab, fully
// click-through). All control comes from Hyprland keybinds that summon this
// plugin with a small JSON payload:
//
//   SUPER + TAB          -> summon ... '{"action":"next"}'
//   SUPER + SHIFT + TAB  -> summon ... '{"action":"prev"}'
//   SUPER (on release)   -> summon ... '{"action":"commit"}'
//
// omarchy-shell calls open(payload) on every summon, even while the panel is
// already mounted (keepLoaded), so each keypress lands here as an open() call.
Item {
  id: root

  // Injected by omarchy-shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property int index: 0
  property var wins: []
  // next/prev presses that land before the first window list has loaded, summed
  // (+1 next, -1 prev). Applied as the starting offset once the list is in, so
  // a quick double-tap during that ~10ms window isn't lost.
  property int pendingSteps: 0
  // Set when "commit" arrives while the first window list is still loading (a
  // very fast tap-and-release). Applied the moment the list is in.
  property bool pendingCommit: false
  // A first refresh is in flight and nothing is cached yet. Only ever true
  // before the first list lands -- after that the list is kept warm.
  property bool listPending: false

  // Whether the window list has ever actually landed, as opposed to merely
  // being non-empty.
  //
  // The cold-start guard used to read wins.length, on the reasoning that an
  // empty list meant Hyprland had not answered yet. Empty-workspace tiles broke
  // that: a fresh shell whose toplevels have not arrived still builds five
  // placeholders, which sailed past the `< 2` check, so the cold path never ran
  // and the strip opened showing five empty workspaces while six windows were
  // on screen. Counting entries cannot tell "nothing to show" from "nothing
  // loaded"; this flag can.
  property bool listLoaded: false

  // ── Drag a tile to another workspace ────────────────────────────────────────
  //
  // Ordinary press / move / release, which the surface only gets because the
  // "Move window" bind stands down while the strip is up -- see
  // hypr/window-switcher-bindings.lua. Hyprland resolves mouse binds
  // before handing a button to a layer surface, so for as long as SUPER +
  // mouse:272 was bound the HUD could be told a click HAPPENED (by the bind
  // dispatching into it) but never got the press itself, and a drag needs all
  // three events.
  //
  // What the pointer is carrying: an index into `wins`, which is stable for the
  // life of a drag because the list is frozen while the strip is open.
  property int dragIndex: -1
  // Past the drag threshold, i.e. this is a drag and no longer a click.
  property bool dragging: false
  // Pointer position in CARD coordinates, for the ghost to follow.
  property real dragX: 0
  property real dragY: 0
  // The workspace under the pointer, or -1 when the pointer has left the card.
  property int dropWsId: -1

  // WHERE in that workspace's group the window would land, as an insertion slot:
  // 0 before the group's first tile, m after its last, and every boundary
  // between. Counted as "tiles whose centre the pointer has passed", which is
  // the same rule any reorderable list uses and needs no special case at either
  // end.
  property int dropSlot: 0

  // Whether letting go here would do anything at all: a live drag, over a
  // group. The workspace is deliberately NOT required to differ -- dropping a
  // tile on its own group is how you send a window to the front or the back of
  // where it already is. The drop-target highlight, the caret and the drop
  // itself all share this, so what is drawn and what happens cannot disagree.
  readonly property bool dropReady: root.dragging && root.dropWsId > 0
    && root.dragIndex >= 0 && root.dragIndex < root.wins.length

  // Whether the start/end offer means anything. A workspace has to hold a window
  // OTHER than the one in the hand before there is an order to join: dropping
  // onto an empty desktop, or back onto a group whose only window is the one
  // being dragged, has exactly one outcome however it is aimed. The caret is
  // hidden in that case rather than pointing at a choice that does not exist.
  readonly property bool dropArrangeReady: {
    if (!root.dropReady) return false
    for (var i = 0; i < root.wins.length; i++) {
      if (i === root.dragIndex) continue
      if (root.wins[i].wsId !== root.dropWsId) continue
      if (root.wins[i].kind === "window") return true
    }
    return false
  }

  // The window a drop just moved, so the highlight can follow it into its new
  // group -- releasing SUPER has to still focus the thing you were dragging,
  // wherever the re-sort put it.
  property string dropFollowAddr: ""

  // Placement, deferred.
  //
  // Where a window lands inside a workspace cannot be asked for in the same
  // breath as the workspace itself: `movetoworkspacesilent` puts it wherever
  // the layout decides, and only once that has happened does the strip know
  // how far from the requested end it actually came to rest. So the drop
  // records the intent here, and the first rebuild that sees the window on the
  // workspace it asked for works out the distance and closes it.
  property bool dropPlacePending: false
  property int dropPlaceWs: -1
  // Where in the group it should end up, 0-based, once it is there.
  property int dropPlaceIndex: -1
  // Where it was when the last step was sent, and how many have gone out. A
  // step that changes nothing means the layout cannot express what was asked --
  // a workspace mixing horizontal and vertical splits, most likely -- and the
  // walk stops rather than spinning.
  property int dropPlaceLastAt: -1
  property int dropPlaceSteps: 0

  // ── Most-recently-used, for back-and-forth ──────────────────────────────────
  //
  // A single tap must return to the window you came from, and a second tap must
  // bring you back -- the alternation every Alt+Tab has. That needs the PREVIOUS
  // focus, which nothing on the compositor side keeps in a usable form here:
  // `activated` only ever says what is focused now, and `lastIpcObject`'s
  // focusHistoryID is a stale snapshot (measured: it sat at 2/1/0 across two
  // focus changes). So the history is kept here, updated from the live
  // `Hyprland.activeToplevel`.
  //
  // Deliberately NOT used for ordering. The tiles stay sorted by workspace and
  // on-screen position; this only moves where the highlight STARTS.
  property string activeAddr: ""
  property string prevAddr: ""

  // "commit" (sent the instant SUPER is released) is the only thing that
  // switches focus. This timer is a last-resort safety net: if that never
  // arrives (e.g. the Lua key poll died), dismiss the strip WITHOUT switching
  // after this long with no next/prev activity, so a stuck HUD can't linger.
  readonly property int idleTimeoutMs: 30000

  // How many empty workspaces get a tile of their own.
  //
  // Matched to what Omarchy's bar seeds: Workspaces.qml:23 starts from
  // [1, 2, 3, 4, 5] and only grows past that for workspaces that actually
  // exist. Anything above 5 that exists is occupied, so its windows already
  // put it in the strip -- padding to the same 5 keeps the two showing the
  // same set of blank desktops without a second source of truth.
  readonly property int emptyWorkspaceSlots: 5

  // ── Input path ──────────────────────────────────────────────────────────────
  //
  // The keybinds reach this plugin through Hyprland's global-shortcuts protocol
  // rather than by summoning it over IPC, because the IPC path costs a process
  // spawn per keypress. `omarchy-shell shell summon` is bash -> timeout -> `qs
  // ipc`, and `qs ipc` starts a whole Quickshell binary to deliver one message:
  // measured at 31-35ms per press on this machine, with spikes to 130-166ms.
  // That is the sluggishness -- it was paid on every single TAB.
  //
  // A GlobalShortcut is registered here and bound in
  // hypr/window-switcher-bindings.lua with hl.dsp.global(), so the
  // compositor delivers the key straight to this process over the Wayland
  // protocol. No fork, no exec, no Qt startup.
  //
  // `commit` is a shortcut too, for the same reason: hl.dsp.global is a
  // *dispatcher*, so the Lua key-release poll can dispatch it directly instead
  // of shelling out. The appid carries no dots or colons -- Hyprland parses the
  // binding as "<appid>:<name>".
  readonly property string shortcutAppid: "cllpse-switcher"

  GlobalShortcut {
    appid: root.shortcutAppid
    name: "next"
    description: "Window switcher: next"
    onPressed: root.open('{"action":"next"}')
  }

  GlobalShortcut {
    appid: root.shortcutAppid
    name: "prev"
    description: "Window switcher: previous"
    onPressed: root.open('{"action":"prev"}')
  }

  GlobalShortcut {
    appid: root.shortcutAppid
    name: "commit"
    description: "Window switcher: focus the highlighted window"
    onPressed: root.open('{"action":"commit"}')
  }

  // Must match manifest.json's `id`. The fallback is only reached if the panel
  // loader hands this plugin no manifest, and a WRONG id there fails silently:
  // shell.hide() is given a name the shell does not know, so its panel
  // bookkeeping never learns the HUD closed, while `visible: root.opened`
  // hides the window anyway and nothing looks broken.
  readonly property string pluginId: (manifest && manifest.id) || "cllpse.window-switcher"

  function open(payloadJson) {
    var action = "next"
    try {
      var p = JSON.parse(payloadJson || "{}")
      if (p && p.action) action = String(p.action)
    } catch (e) {}

    if (action === "commit") {
      // Only possible before the list is warm -- see the cold path below.
      if (!root.opened && root.listPending) { root.pendingCommit = true; return }
      root.commit()
      return
    }

    if (action !== "next" && action !== "prev") return
    var step = (action === "prev") ? -1 : 1

    if (!root.opened) {
      // Warm path: the list is already in memory, so opening is synchronous --
      // no process to spawn and nothing to wait for. The rebuild below only
      // does real work on the very first summon; after that _rebuild() finds
      // the list unchanged and leaves the model alone.
      if (!root.listLoaded) root._rebuild()
      if (root.listLoaded && root.wins.length >= 2) { root._openStepped(step); return }
      // Cold: nothing cached yet (first summon after a shell restart, or a
      // refresh still in flight). Remember the presses and let _rebuild()
      // apply them the moment the list lands, exactly as before.
      root.pendingSteps += step
      if (!root.listPending) {
        root.listPending = true
        root.pendingCommit = false
        Hyprland.refreshToplevels()
        // The rebuild has to be SCHEDULED, not waited for. refreshToplevels()
        // rewrites each lastIpcObject in place and leaves the values array
        // alone, so valuesChanged only fires when the refresh POPULATES a list
        // that was empty. The other cold shape -- values already present but
        // their lastIpcObject not yet filled, the case _rebuild()'s own comment
        // describes -- emits nothing at all, and without this timer nothing
        // ever calls _rebuild() again: listPending stays true, which blocks
        // every later press from refreshing, and the strip is dead until an
        // unrelated compositor event happens to fire refreshDebounce.
        // Same pairing refreshDebounce already uses below.
        rebuildAfterRefresh.restart()
      }
      return
    }

    var n = root.wins.length
    if (n === 0) { root.dismiss(); return }
    root.index = ((root.index + step) % n + n) % n
    idleTimer.restart()
  }

  // Called by omarchy-shell when it hides the panel.
  function close() {
    root.opened = false
    root._dragCancel()
    idleTimer.stop()
    root._rebuild() // unfreeze: catch anything that changed while it was up
  }

  function dismiss() {
    root.opened = false
    root._dragCancel()
    root.pendingSteps = 0
    root.pendingCommit = false
    idleTimer.stop()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    root._rebuild() // unfreeze: catch anything that changed while it was up
  }

  function commit() {
    // SUPER released mid-drag. Drop what is in the hand and stop there rather
    // than also focusing: the move is a hyprctl process and so is the focus,
    // and if the focus won that race Hyprland would send you to the workspace
    // the window is about to LEAVE. A drag is not a selection anyway.
    if (root.dragging) { root._dragDrop(); root.dismiss(); return }
    idleTimer.stop()
    if (root.opened && root.index >= 0 && root.index < root.wins.length) {
      var sel = root.wins[root.index]
      if (sel.kind === "workspace") {
        // Same dispatch the bar's own widget uses (Workspaces.qml:33), so a
        // blank desktop is reached exactly as clicking its bar pip would.
        focusProc.command = ["hyprctl", "dispatch",
          "hl.dsp.focus({ workspace = \"" + sel.wsId + "\" })"]
        focusProc.running = true
      } else if (sel.address) {
        focusProc.command = ["hyprctl", "dispatch",
          "hl.dsp.focus({ window = \"address:" + sel.address + "\" })"]
        focusProc.running = true
      }
    }
    root.dismiss()
  }

  // Where a USER drops icons of their own: one directory, outside this
  // repository, so an `omarchy plugin update` cannot conflict with what they put
  // there.
  readonly property string userIconRoot:
    Quickshell.env("HOME") + "/.config/omarchy/cllpse.window-switcher/icons/"

  // An optional integration, NOT a dependency. omarchy-cllpse-macos, the
  // configuration this plugin was extracted from, syncs repainted drop-ins here
  // for the Omarchy menu, and reading them means its users get the same icon in
  // both places. On any other machine the directory does not exist, `find` says
  // so on stderr, and the index is simply built without it -- every tile keeps
  // its Nerd Font glyph, which is what a machine with no drop-ins has always
  // done.
  readonly property string dotfilesIconDir: Quickshell.env("HOME") + "/.icons/cllpse-flat/apps/"

  // ── Marks the plugin ships itself ───────────────────────────────────────────
  //
  // 75 app and CLI/agent marks in ONE directory, icons/, so tiles and terminal
  // process icons both work on a machine that has done nothing but install this
  // plugin. Resolved LAST, after the user's own drop-ins and after their
  // installed icon themes, so they can only ever fill a gap -- they never
  // override a mark somebody chose.
  //
  // Every one is drawn exactly as authored. There is no flat/colour split and
  // no recolouring anywhere in this file: an icon is the source of truth for
  // its own appearance, and the only thing ever changed in a file is its
  // viewBox, so that all of them fill their box alike. That is also why no
  // theme hook is needed, and why these can live in a plugin at all -- nothing
  // is baked per theme, so nothing goes stale. See AGENTS.md before adding one.
  readonly property string pluginRoot: {
    var u = String(Qt.resolvedUrl("."))
    return u.indexOf("file://") === 0 ? u.substring(7) : u
  }
  property var pluginIconIndex: ({})

  Process {
    id: pluginIconScan
    // One find rather than an `ls`, and one Process for the whole directory. A
    // missing directory is simply no output rather than an error.
    command: ["find", root.pluginRoot + "icons", "-name", "*.svg"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._applyPluginIconIndex(text)
    }
  }

  function _applyPluginIconIndex(text) {
    var idx = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var pth = lines[i].trim()
      if (pth.length === 0) continue
      var slash = pth.lastIndexOf("/")
      var file = slash >= 0 ? pth.substring(slash + 1) : pth
      var dot = file.lastIndexOf(".")
      if (dot <= 0) continue
      var name = file.substring(0, dot)
      if (idx[name] !== undefined) continue
      idx[name] = "file://" + pth
    }
    root.pluginIconIndex = idx
  }

  // Nerd Font codepoints, built from hex so the Private-Use-Area glyphs survive
  // any editor. These render in Style.font.menuFamily -- SFProText Nerd Font
  // Propo on this machine, via OMARCHY_MENU_FONT -- so every codepoint here is
  // verified against THAT face, not against the monospace one the terminal uses.
  //
  // Keyed on the window class, which is all a switcher has. A drop-in is named
  // for a desktop entry's `Icon=` instead,
  // and the two keyspaces genuinely differ: measured on this machine, 6 of the
  // 23 entries declaring StartupWMClass use a class that is not their icon
  // name, and Chromium's is the literal unsubstituted "@@startup_wm_class". So
  // they stay two keyspaces -- but where both cover an app they MUST agree on
  // the mark, or the same program wears one in the menu and a different one
  // under SUPER+TAB.
  //
  // Order is load-bearing in two places: "obsidian" must be tested before
  // "obs" (OBS Studio) because the former contains the latter, and the
  // specific libreoffice-* classes before the bare "libreoffice".
  function glyphFor(cls) {
    var c = String(cls || "").toLowerCase()
    function has() {
      for (var i = 0; i < arguments.length; i++)
        if (c.indexOf(arguments[i]) !== -1) return true
      return false
    }
    var g = 0xf108 // desktop (generic fallback)
    if (has("ghostty", "alacritty", "kitty", "foot", "wezterm", "xterm", "konsole", "terminal")) g = 0xe795
    else if (has("firefox", "librewolf", "floorp", "zen-browser", "zen_browser", "waterfox")) g = 0xf269
    // Helium is a Chromium fork and belongs in the family bucket. It had a
    // hand-placed raster once, dropped when the indexes went SVG-only, so it
    // shows this glyph now. A vector can be dropped in at any time to take it
    // back over.
    else if (has("chromium", "chrome", "helium", "vivaldi", "brave", "edge", "opera")) g = 0xf268
    else if (has("code", "cursor", "sublime", "jetbrains", "idea", "pycharm", "webstorm", "zed", "vim", "emacs")) g = 0xf121
    else if (has("steam")) g = 0xf1b6
    else if (has("obsidian")) g = 0xf082e                                  // notebook
    else if (has("obs")) g = 0xf03d                                        // video camera
    else if (has("spotify", "cliamp")) g = 0xf001                          // music
    else if (has("vlc", "mpv", "celluloid", "kdenlive")) g = 0xf008        // film
    else if (has("gimp", "inkscape", "krita", "pinta", "figma")) g = 0xf1fc // paint brush
    else if (has("imv", "eog", "loupe", "gwenview")) g = 0xf03e            // image
    else if (has("evince", "papers", "zathura", "okular")) g = 0xf1c1      // pdf
    else if (has("libreoffice-writer")) g = 0xf1c2
    else if (has("libreoffice-calc")) g = 0xf1c3
    else if (has("libreoffice-impress")) g = 0xf1c4
    else if (has("libreoffice-draw")) g = 0xf1fc
    else if (has("libreoffice-base")) g = 0xf1c0
    else if (has("libreoffice-math")) g = 0xf1ec
    else if (has("libreoffice")) g = 0xf0219                               // document
    else if (has("omacalc", "galculator")) g = 0xf1ec                      // calculator
    else if (has("xournal", "omawrite")) g = 0xf040                        // pencil
    else if (has("localsend")) g = 0xf1e0                                  // share
    else if (has("moonlight")) g = 0xf26c                                  // monitor
    else if (has("qv4l2", "qvidcap", "cheese")) g = 0xf030                 // camera
    else if (has("docker")) g = 0xf308
    else if (has("thunderbird")) g = 0xf0e0                                // envelope
    else if (has("discord", "slack", "telegram", "signal", "beeper")) g = 0xf086 // comments
    else if (has("nautilus", "thunar", "pcmanfm", "dolphin", "nemo", "files")) g = 0xf07b // folder
    // fromCodePoint, NOT fromCharCode: the latter is 16-bit and silently
    // truncates anything above U+FFFF, so the Material Design range this map
    // now uses (0xf0219 -> U+219, 0xf082e -> U+82E) would render as unrelated
    // glyphs with no error.
    return String.fromCodePoint(g)
  }

  // A hand-placed icon for this window's app, if one exists.
  //
  // Three sources, in order: the drop-in index (the user's own directory, plus
  // the optional dotfiles one above), whatever their installed icon themes
  // carry, and the marks this plugin ships. Only the first two can override
  // anything; ours fill gaps.
  //
  // The dotfiles root is why that index has two roots at all: omarchy-cllpse-
  // macos syncs repainted drop-ins there for the Omarchy menu, which cannot
  // render a glyph and would otherwise show the vendor's colour logo. Reading
  // them means that configuration shows one mark in both surfaces. Absent
  // everywhere else, and absent is fine.
  //
  // Keyed on the window class, because that is all a switcher has, while the
  // dropped file is named for the desktop entry's `Icon=`. Those agree for most
  // apps but not all (measured: 5 of the 24 entries declaring StartupWMClass use
  // a class that is not their icon name). A drop-in whose name differs from the
  // class simply is not found here and the tile keeps its glyph -- drop a second
  // copy named for the class if you want it in both places.
  //
  // Icon index: one directory listing at launch, cached for the session.
  //
  // Existence used to be probed per tile -- two Images per mark, .svg then
  // .png, whichever reported Image.Ready won. That cost two failed opens per
  // tile on every rebuild for any app without a drop-in (the journal filled
  // with "Cannot open" from it), and it made the delegate's STRUCTURE depend on
  // Image.status.
  //
  // That dependency is what aborted the shell, four times. QQuickImageBase::
  // itemChange reloads an Image on any device-pixel-ratio change --
  // unconditionally, qquickimagebase.cpp:426, under the comment "If the screen
  // DPI changed, reload image" -- and Qt delivers that change by recursing the
  // item tree from QQuickWindow::physicalDpiChanged. So on every HUD unmap,
  // status left Ready from inside the walk; anything bound to status that owned
  // a child item tore it down while the walk still held a pointer, and the walk
  // then called a virtual on freed memory. Nothing here could defer its way out
  // of it -- the reload is Qt's, not ours (tried in eaecd58, reverted in
  // 9975332 after three more crashes).
  //
  // Resolving paths up front removes the class of problem rather than the
  // instance: a tile knows whether it has an icon before anything loads, so the
  // layer and the effect key off a cached bool that no reload can disturb.
  property var iconIndex: ({})

  // Icon resolution, in one sentence: an svg override if there is one, the
  // launcher's coloured icon otherwise, a Nerd Font glyph when there is
  // neither.
  //
  // This was briefly behind a vendorIcons flag, which added a third state --
  // overrides and glyphs, no vendor art -- that the rule above does not have.
  // The flag is gone; the rule is the behaviour.

  // Vendor icons, indexed here rather than asked for.
  //
  // Omarchy already has this resolver -- AppLibrary.iconSource() -- but it is
  // gated: shell.qml:603 hands a plugin `appLibrary` only when its manifest
  // declares the "menu" kind, and this one is a "panel". Declaring "menu" to
  // get past that would also want an entryPoints.menu (PluginRegistry.qml:120)
  // and would register the switcher as a launcher entry, which it is not.
  //
  // So the sweep runs here: the same command AppLibrary:122-137 issues, parsed
  // on the same first-hit-wins rule, so the strip and the launcher resolve the
  // same file for a given name. No manifest games, nothing gated.
  property var vendorIndex: ({})

  Process {
    id: vendorScan
    command: ["bash", "-c",
      'dirs="$HOME/.icons $HOME/.local/share/icons"; '
      + 'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS; '
      + '{ for ext in svg png; do '
      + '  for base in $dirs; do '
      // Two plain finds rather than one \( -o \) group: inside a QML string
      // the backslash is eaten by the JS lexer, so the parens reach bash bare
      // and it exits on a syntax error with an empty stdout -- a silent miss,
      // which is exactly how this failed the first time.
      + '    [ -d "$base" ] && find "$base" -path "*/apps/*" -name "*.$ext" 2>/dev/null; '
      + '    [ -d "$base" ] && find "$base" -path "*/devices/*" -name "*.$ext" 2>/dev/null; '
      + '  done; '
      + '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null; '
      + 'done; }'
      // Collapse to one line per NAME before any of it crosses into QML.
      //
      // The sweep walks ~34k files and hands back 9106 paths, of which
      // _applyVendorIndex keeps 1364 -- first hit wins, so 85% of what it
      // parsed was discarded the moment it arrived. Measured: 544KB and 9ms of
      // main-thread parse to build an index that 79KB and ~1ms produces.
      //
      // Semantics are unchanged, and that was verified rather than assumed:
      // awk keeps the FIRST path per name, walking the stream in the same order
      // the loops emit it, so the svg pass still outranks the png pass and
      // $HOME/.icons still outranks every installed theme. Both indexes were
      // built and compared key by key -- 1364 names each, identical mapping.
      //
      // `[.]` rather than an escaped dot, deliberately. A backslash in this
      // string is eaten by the JS lexer before bash ever sees it -- the same
      // trap the two plain finds above exist for -- and `sub(/.[^.]*$/...)`
      // would silently strip from the FIRST character rather than the last dot.
      + " | awk -F/ '{ f=$NF; sub(/[.][^.]*$/, \"\", f); if (!(f in seen)) { seen[f]=1; print } }'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._applyVendorIndex(text)
    }
  }

  function _applyVendorIndex(text) {
    var idx = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var pth = lines[i].trim()
      if (pth.length === 0) continue
      var slash = pth.lastIndexOf("/")
      var file = slash >= 0 ? pth.substring(slash + 1) : pth
      var dot = file.lastIndexOf(".")
      var name = dot > 0 ? file.substring(0, dot) : file
      // First hit wins and the svg pass runs first, so a scalable icon outranks
      // a raster of the same name -- AppLibrary's rule, kept deliberately.
      if (name.length > 0 && idx[name] === undefined) idx[name] = "file://" + pth
    }
    root.vendorIndex = idx
  }

  // Web apps: window class -> host -> desktop entry -> Icon= / Name=.
  //
  // An Omarchy web app is a Chromium window, and Chromium names it
  // chrome-<host><path>-Profile_N, which no icon index can match -- so Slack
  // arrived here as a Chrome glyph labelled "Chrome". The launcher never has
  // the problem because it never sees a window class: it lists desktop entries
  // and reads Icon= and Name= straight off them.
  //
  // There is nothing to join on directly -- these entries carry no
  // StartupWMClass -- so the host is the key. Slack.desktop execs
  // https://app.slack.com/... and the window class begins chrome-app.slack.com__
  // The host is the stable part; the path after it is a workspace/channel id
  // that changes, and the -Profile_N suffix is per browser profile.
  readonly property var webAppIndex: {
    var idx = ({})
    var vals = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    for (var i = 0; i < vals.length; i++) {
      var e = vals[i]
      if (!e) continue
      var icon = String(e.icon || "")
      var ex = String(e.execString || e.command || "")
      var m = ex.match(/https?:\/\/([^\/"'\s]+)/)
      if (!m) continue
      if (idx[m[1]] === undefined)
        idx[m[1]] = ({ icon: icon, name: String(e.name || "") })
    }
    return idx
  }

  // Window class -> desktop entry, for classes that are not icon names.
  //
  // Cursor is the case in point: Hyprland reports the class `cursor`, the entry
  // is cursor.desktop carrying StartupWMClass=Cursor and Icon=co.anysphere.cursor,
  // and the file on disk is /usr/share/pixmaps/co.anysphere.cursor.png. Nothing
  // joins `cursor` to that filename except the entry, which is exactly why the
  // launcher shows it and a class-keyed index cannot.
  //
  // Keyed on both StartupWMClass and the entry id, lowercased, because
  // Hyprland's class and the entry's declaration disagree on case as often as
  // not -- `cursor` against `Cursor` here.
  readonly property var classIndex: {
    var idx = ({})
    var vals = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    for (var i = 0; i < vals.length; i++) {
      var e = vals[i]
      if (!e) continue
      var rec = ({ icon: String(e.icon || ""), name: String(e.name || "") })
      var keys = [String(e.startupClass || ""), String(e.id || "").replace(/\.desktop$/, "")]
      for (var k = 0; k < keys.length; k++) {
        var key = keys[k].toLowerCase()
        if (key.length > 0 && idx[key] === undefined) idx[key] = rec
      }
    }
    return idx
  }

  // An entry's Icon= run through the same indexes a class goes through, so a
  // drop-in still outranks the vendor file.
  function _iconFromEntry(hit) {
    if (!hit) return ""
    var name = String(hit.icon || "")
    if (name.length === 0) return ""
    var flat = root.iconIndex[name]
    if (flat !== undefined) return flat
    var v = root.vendorIndex[name]
    if (v !== undefined) return v
    var own = root.pluginIconIndex[name]
    return own === undefined ? "" : own
  }

  function _webAppEntry(cls) {
    var c = String(cls || "")
    if (c.indexOf("chrome-") !== 0) return null
    var rest = c.substring(7)
    var cut = rest.indexOf("__")
    var host = cut > 0 ? rest.substring(0, cut) : rest.replace(/-Profile_\d+$/, "")
    if (host.length === 0) return null
    var hit = root.webAppIndex[host]
    return hit === undefined ? null : hit
  }

  function iconFor(cls) {
    var c = String(cls || "").trim()
    if (c.length === 0) return ""
    // Drop-ins win outright -- they are the deliberate override, and keeping
    // them first means precedence does not depend on AppLibrary's internals.
    var u = root.iconIndex[c]
    if (u !== undefined) return u
    // Then the desktop entry -- by class for a normal app, by host for a web
    // app. Both end at the same place: the Icon= the launcher reads.
    var w = root._iconFromEntry(root.classIndex[c.toLowerCase()])
    if (w.length > 0) return w
    w = root._iconFromEntry(root._webAppEntry(c))
    if (w.length > 0) return w
    var v = root.vendorIndex[c]
    if (v !== undefined) return v
    // Last: what this plugin ships. A gap-filler, never an override.
    var own = root.pluginIconIndex[c]
    return own === undefined ? "" : own
  }

  // `ls` directly rather than through a shell: Process runs the argv as given,
  // so the directory needs no quoting. A missing directory writes to stderr and
  // leaves stdout empty, which lands as an empty index -- every tile a glyph,
  // which is exactly the behaviour on a machine with no drop-ins at all.
  //
  // Once per launch, so a mark added afterwards is not seen until the shell
  // restarts. That is the honest cost of not watching the directory, and it is
  // stated in AGENTS.md rather than worked around: adding an icon is a
  // rare, deliberate act, and a watcher on three directories to catch it would
  // be machinery for nothing.
  //
  // On omarchy-cllpse-macos, the configuration this plugin came from, the
  // restart is automatic: its app-icons.sh hook restarts the shell from an EXIT
  // trap when a synced file actually changed. That is that configuration's
  // doing, not this plugin's, and worth knowing only because it is why the
  // staleness never shows up there. Note it is the hook, not `omarchy
  // theme set` -- theme-set pushes the palette in over IPC and restarts the
  // terminal, hyprctl, btop, opencode and helix, never the shell (measured: the
  // quickshell pid is unchanged across one). The hook restarts it from an EXIT
  // trap when, and only when, a synced file actually changed.
  //
  // Get that wrong and the failure is quiet in the worst way: the drop-in is
  // correct on disk, this index predates it, and the tile just keeps its Nerd
  // Font glyph with nothing to say why.
  Process {
    id: iconScan
    // Both roots in one pass. A missing directory is an stderr line and nothing
    // else -- the other root is still walked, and StdioCollector only reads
    // stdout -- which is exactly the degradation wanted: a machine with neither
    // gets an empty index rather than an error, and every tile keeps its glyph.
    command: ["find", root.userIconRoot, root.dotfilesIconDir, "-name", "*.svg"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._applyIconIndex(text)
    }
  }

  function _applyIconIndex(text) {
    var idx = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var pth = lines[i].trim()
      if (pth.length === 0) continue
      var slash = pth.lastIndexOf("/")
      var f = slash >= 0 ? pth.substring(slash + 1) : pth
      var dot = f.lastIndexOf(".")
      if (dot <= 0) continue
      // .svg only, deliberately, so one ink convention holds everywhere -- see
      // iconSize in the delegate.
      // Ignoring a stray .png here means a leftover from an older generation
      // cannot quietly reintroduce the second convention; the app falls back to
      // its glyph until the file is regenerated, which is the honest result.
      if (f.substring(dot + 1).toLowerCase() !== "svg") continue
      // First hit wins, and the user's own root is walked first, so a mark they
      // placed outranks anything synced in beside it.
      var name = f.substring(0, dot)
      if (idx[name] !== undefined) continue
      idx[name] = "file://" + pth
    }
    root.iconIndex = idx
  }

  // ── What is RUNNING in a terminal ───────────────────────────────────────────
  //
  // The window title is the only signal there is, and it took measuring to be
  // sure of that. Ghostty runs --gtk-single-instance=true, so every one of its
  // windows reports the SAME pid -- measured here, four windows all pid 3242 --
  // and the compositor cannot say which process belongs to which window. No
  // process-tree walk recovers it either: the shells are all children of that
  // one pid, and nothing ties a child back to a surface.
  //
  // The title turns out to be the better signal anyway. Ghostty's shell
  // integration sets it to the command AS TYPED, so an alias arrives as itself
  // -- `diff`, not `hunk diff` -- an idle shell shows its cwd, and Claude Code
  // overwrites it with its own status line. windowtitle/windowtitlev2 are
  // already in refreshEvents, so a processIcon follows the foreground command live
  // with no new machinery at all.

  // Command name -> icon name, for the cases where the two differ.
  //
  // Not in this file: it lives in icon-aliases.json at the plugin root, so it
  // can be edited without touching QML. Two separate reasons a mapping is
  // needed -- a shell alias means the title carries what was TYPED rather than
  // what ran, and a drop-in is named for a desktop entry's `Icon=` rather than
  // for any command. Everything unlisted resolves by its own name, which is most
  // of the set. README.md documents the shipped entries; the file itself is
  // strict JSON and carries no prose, because JSON has nowhere to put any.
  //
  // Watched, so a saved edit applies without a restart. `text()` is stale inside
  // the change signal itself -- Omarchy's own Color.qml records the same trap --
  // so both paths route through reload() -> onLoaded and always parse fresh
  // content.
  property var iconAliases: ({})

  FileView {
    path: root.pluginRoot + "icon-aliases.json"
    watchChanges: true
    printErrors: false
    onLoaded: root._applyIconAliases(text())
    onFileChanged: reload()
    // Absent is not the same as unparseable, and they are handled differently
    // below: a missing file means no aliases at all, which is a real state a
    // user can choose by deleting it.
    onLoadFailed: root._applyIconAliases("")
  }

  function _applyIconAliases(text) {
    var raw = String(text || "")
    if (raw.trim().length === 0) { root.iconAliases = ({}); return }
    var parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      // Keep whatever was last loaded. A typo mid-edit should not make every
      // processIcon vanish; the file is watched, so the next good save fixes it.
      // The comment hint is here because this file used to strip `//` lines and
      // no longer does: JSON has no comments, so that is the likeliest mistake.
      console.warn("window-switcher: icon-aliases.json did not parse (" + e
        + ") -- keeping the previous mappings. Note it is strict JSON:"
        + " no comments, no trailing commas.")
      return
    }
    if (!parsed || typeof parsed !== "object" || parsed.constructor === Array) {
      console.warn("window-switcher: icon-aliases.json is not an object -- ignored")
      return
    }
    var idx = ({})
    for (var k in parsed)
      if (typeof parsed[k] === "string" && parsed[k].length > 0) idx[k] = parsed[k]
    root.iconAliases = idx
  }

  // Claude Code announces itself by overwriting the title with
  // "<status marker> <what it is working on>". Measured on this machine across
  // sessions: U+25D0, U+25D1 and U+2733. The marker tracks session state and
  // only the states seen so far are known, so the rest of the family is
  // included rather than waiting to be surprised by one.
  readonly property string claudeMarkers:
    "\u2733\u2722\u273B\u273D\u2736\u2739\u25D0\u25D1\u25D2\u25D3\u23FA"

  function _isTerminal(cls) {
    var c = String(cls || "").toLowerCase()
    return c.indexOf("ghostty") !== -1 || c.indexOf("alacritty") !== -1
      || c.indexOf("kitty") !== -1 || c.indexOf("foot") !== -1
      || c.indexOf("wezterm") !== -1 || c.indexOf("xterm") !== -1
      || c.indexOf("konsole") !== -1 || c.indexOf("terminal") !== -1
  }

  // The icon for what this window is showing, or "" for none: the program
  // running in a terminal, or the favicon of the site in a browser.
  //
  // One slot for both because it is one question -- a terminal and a browser
  // are alike in being a window you keep, whose contents are what you are
  // actually looking for under SUPER+TAB, and neither one's own mark says
  // which of four you meant. The badge answers that and the rules are the
  // same: drawn exactly as it comes, and absent rather than guessed at.
  //
  // Resolved through the SAME indexes a window class goes through, in the same
  // order, so a terminal process icon and an app tile can never disagree about
  // what a given program looks like. A favicon has no such index -- it comes
  // from the browser's own cache, see faviconIndex below.
  //
  // Most of these are answered by the vendor sweep or by icons/ here, which is
  // where the CLI and agent marks live. Drawn exactly as the file is, like
  // every other icon.
  //
  // No glyph fallback: at processIcon size a Nerd Font glyph is a smudge, and "no icon
  // for this" is better read as no processIcon than as a mark nobody can identify.
  function processIconFor(cls, title) {
    // A browser is showing a site rather than running a program. Keyed on the
    // page title with the browser's own name stripped, which is exactly what
    // was handed to the helper, so the two cannot disagree about the key.
    //
    // A web app is deliberately not included: its class already carries the
    // host, so iconFor resolves the site's own desktop entry as the TILE icon
    // and a badge would repeat it.
    if (root._isBrowser(cls) && !root._webAppEntry(cls)) {
      var key = root._pageTitle(cls, title)
      var fav = key.length > 0 ? root.faviconIndex[key] : undefined
      // typeof, not `!== undefined`: a page really titled "constructor" or
      // "toString" reads the INHERITED Object.prototype member out of a plain
      // object, and a function stringified into Image.source is a mess with no
      // error behind it. Page titles are arbitrary web content, so this one is
      // reachable in a way the command-name indexes above are not.
      return (typeof fav === "string") ? fav : ""
    }
    if (!root._isTerminal(cls)) return ""
    var t = String(title || "").trim()
    if (t.length === 0) return ""
    // An idle shell is titled with its working directory, and a directory is
    // not a program.
    if (t.charAt(0) === "~" || t.charAt(0) === "/") return ""

    var name = ""
    if (root.claudeMarkers.indexOf(t.charAt(0)) !== -1) {
      name = "claude"
    } else if (t.charCodeAt(0) > 0x2000 && t.charAt(1) === " ") {
      // A marker this does not know yet, in the shape Claude Code uses. Loose
      // on purpose and the one guess in here: nothing else on this machine
      // titles itself with a leading symbol and a space. If something starts,
      // it will wear the wrong processIcon and this is the line to tighten.
      name = "claude"
    } else {
      name = t.split(/\s+/)[0].toLowerCase()
      // A path-qualified command still names itself in its last segment.
      var slash = name.lastIndexOf("/")
      if (slash >= 0) name = name.substring(slash + 1)
    }
    if (name.length === 0) return ""

    // Aliased AFTER the branches, not inside one of them. It was inside the
    // last one to begin with, which meant a claude session -- recognised by its
    // marker and never by a command name -- skipped the table entirely and went
    // looking for "claude". The file is claude-code.svg, so it found nothing
    // and the tile drew no processIcon while every other program carrying a process icon correctly.
    var aliased = root.iconAliases[name]
    if (aliased !== undefined) name = aliased

    var flat = root.iconIndex[name]
    if (flat !== undefined) return flat
    var v = root.vendorIndex[name]
    if (v !== undefined) return v
    var own = root.pluginIconIndex[name]
    return own === undefined ? "" : own
  }

  // ── What a BROWSER window is showing ────────────────────────────────────────
  //
  // Same slot as the terminal's process icon and the same reasoning, but the
  // signal underneath is weaker and it is worth being plain about why.
  //
  // A terminal's title IS the command: shell integration writes it, so the
  // window says what it is running. A browser's title is the PAGE's own title,
  // chosen by the page, and there is no URL anywhere on the Wayland toplevel --
  // not in the class, not in the title, not on the handle. So the only join
  // available is title -> the browser's History DB -> the URL it recorded ->
  // its Favicons DB. That is two SQLite databases, which QML cannot read, hence
  // favicons.py; everything about how it reads them is documented there.
  //
  // Measured before building it, over the 200 most recently visited pages in
  // this profile: every one resolved a favicon, 11 of them through an exact
  // page URL and 189 through another page on the same host. 145 resolved the
  // identical icon the true URL would have; the 55 that did not were one
  // session of raw images opened off a CDN, whose titles the origin site shares
  // -- and there the origin's mark is the more useful answer anyway. Not one
  // genuine mis-attribution in the sample. Re-measure before trusting that on a
  // different browsing history.
  //
  // What it cannot do, and each of these ends as no badge rather than a wrong
  // one: a page never visited before in a profile this can find (nothing to
  // join to), an incognito window (nothing is recorded), and a local file or a
  // chrome:// page (no favicon cached). Firefox used to be on this list, and is
  // not: favicons.py carries a row for it, reading the places.sqlite /
  // favicons.sqlite schema the way it reads Chromium's History / Favicons.

  // Both families. favicons.py carries a row per family rather than a code
  // path, so what is browser-specific here is only this list of classes and
  // the title suffixes below -- the lookup itself knows nothing about either.
  //
  // "chrome" also matches a web app's chrome-<host>__-Profile_N class; both
  // callers exclude those explicitly rather than tightening this, since the
  // class genuinely IS a browser -- it is only that a web app already wears the
  // site's own icon on the tile.
  function _isBrowser(cls) {
    var c = String(cls || "").toLowerCase()
    return c.indexOf("chromium") !== -1 || c.indexOf("chrome") !== -1
      || c.indexOf("brave") !== -1 || c.indexOf("vivaldi") !== -1
      || c.indexOf("edge") !== -1 || c.indexOf("helium") !== -1
      || c.indexOf("opera") !== -1
      || c.indexOf("firefox") !== -1 || c.indexOf("librewolf") !== -1
      || c.indexOf("waterfox") !== -1 || c.indexOf("floorp") !== -1
      || c.indexOf("zen") !== -1
  }

  // Product names a browser appends to its window title, longest first.
  //
  // Order is load-bearing: " - Chrome" is a suffix of " - Google Chrome", so
  // testing the short one first would turn "Docs - Google Chrome" into
  // "Docs - Google" and the lookup would find nothing. Same for Edge, and for
  // "Mozilla Firefox" against "Mozilla Firefox Private Browsing".
  readonly property var browserTitleSuffixes: [
    "Mozilla Firefox Private Browsing", "Google Chrome", "Microsoft Edge",
    "Mozilla Firefox", "Zen Browser", "LibreWolf", "Waterfox", "Chromium",
    "Vivaldi", "Firefox", "Chrome", "Floorp", "Helium", "Brave", "Opera", "Zen"
  ]

  // Both separators a browser puts in front of that name. Chromium-family uses
  // a hyphen, Firefox-family an EM DASH -- written as an escape rather than
  // literally so it cannot be mangled by an editor or a diff tool, which is a
  // silent failure here: the suffix would simply never match and every Firefox
  // tile would look up a title that has a browser name glued to the end of it.
  readonly property var browserTitleSeparators: [" - ", " \u2014 "]

  // The page's own title: the window title with the browser's name taken off.
  //
  // This is the lookup key on both sides -- it is what goes to favicons.py and
  // what comes back keyed by -- so the two cannot drift. A fork not in the list
  // above keeps its suffix, matches no history row and simply gets no badge,
  // which is the same outcome as any other miss.
  function _pageTitle(cls, title) {
    var t = String(title || "").trim()
    if (t.length === 0) return ""
    for (var i = 0; i < root.browserTitleSuffixes.length; i++) {
      for (var j = 0; j < root.browserTitleSeparators.length; j++) {
        var suf = root.browserTitleSeparators[j] + root.browserTitleSuffixes[i]
        if (t.length > suf.length && t.substring(t.length - suf.length) === suf)
          return t.substring(0, t.length - suf.length).trim()
      }
    }
    return t
  }

  // Page title -> a data: URL holding the favicon PNG.
  //
  // data:, not a file. QML's Image takes one -- verified against a file:// URL
  // of the same bytes, both reaching Image.Ready at the same sourceSize -- so
  // the PNG never touches the disk and this plugin still writes nothing.
  //
  // Pruned to what is on screen on every refresh, so it is bounded by the
  // number of browser windows open rather than growing with everywhere you
  // have been this session.
  property var faviconIndex: ({})

  // The keys of the query in flight, in the order they were passed. favicons.py
  // answers by INDEX rather than by echoing the title back, so a tab or any
  // other separator inside a page title cannot break the parse.
  //
  // Only the keys with no answer yet, which is not the same set as what is on
  // screen -- hence faviconLive beside it. A title that already resolved cannot
  // have changed, because the title IS the key: a page that becomes something
  // else becomes a different key. So re-asking about it buys nothing, and at
  // scale it is the expensive half: `urls.title` carries no index in Chromium's
  // schema, so every lookup is a full table scan -- measured 0.02ms at this
  // profile's 730 rows, but 5.2ms at 100k and 25.5ms at 500k, per title.
  property var faviconKeys: []

  // Every browser page title on screen. The index is pruned to this, so it
  // stays bounded by the number of browser windows open rather than growing
  // with everywhere you have been this session.
  property var faviconLive: []

  // Browser profiles, swept once per session -- the fourth index scan in this
  // file, and for the same reason as the other three: it is a walk of the
  // filesystem whose answer does not change while the shell runs.
  //
  // Unlike the other three it is NOT started in Component.onCompleted, but on
  // first sight of a browser window; see _refreshFavicons.
  //
  // It has to be a sweep rather than a list of browsers, or every fork would
  // need a line here; favicons.py identifies a profile by the two database
  // files in it instead. That costs 10.5ms, which is why it is paid ONCE.
  // Leaving it in the per-query path was the version before this and it was
  // the second-largest cost in a run whose actual SQL is 0.43ms.
  //
  // A browser installed after the shell started is not found until a restart,
  // which is the same contract the icon index already has.
  property var faviconProfiles: []

  // Whether the sweep has RUN, which is not the same as whether it found
  // anything: a machine with no browser installed must sweep once and never
  // again, not once per title change.
  property bool faviconSwept: false

  // How many times each on-screen title has been ASKED about without an answer
  // coming back. The cap below is what makes the retry bounded rather than a
  // poll: a title that can never resolve -- an incognito window, a local file,
  // a chrome:// page -- costs three spawns spread over half a minute and then
  // stops, while one that was merely EARLY gets the second look it needs.
  //
  // Pruned alongside faviconIndex, so it stays bounded by what is on screen. A
  // window that navigates away and back starts over, which is right: that is a
  // fresh sighting, and the database it failed against has moved on since.
  property var faviconTries: ({})

  // Three attempts at 12s apart covers ~24s against the 10.07s Chromium takes
  // to commit a visit -- measured, and it is kCommitIntervalSeconds rather
  // than a figure worth re-deriving. Two would just about do for Chromium on
  // its own and leaves nothing for a profile that is mid-write on the retry.
  readonly property int faviconMaxTries: 3

  // Set by faviconRetry alone and cleared by the first _refreshFavicons that
  // reads it. It is what lets a retry through the unchanged-key-set guard
  // WITHOUT letting every window event through it -- which is the whole reason
  // that guard exists. See _refreshFavicons.
  property bool faviconRetryDue: false

  Process {
    id: faviconDiscover
    command: ["python3", "-S", root.pluginRoot + "favicons.py", "--discover"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._applyFaviconProfiles(text)
    }
  }

  function _applyFaviconProfiles(text) {
    var out = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab <= 0) continue
      out.push("--profile")
      out.push(lines[i].substring(0, tab))
      out.push(lines[i].substring(tab + 1))
    }
    root.faviconProfiles = out
    root.faviconSwept = true
    if (out.length === 0) return
    // A refresh can have run and missed while this sweep was still in flight --
    // it would have spawned with no --profile, and the helper's own fallback
    // discovery is the slow path this exists to avoid. Clearing faviconLive is
    // what makes the retry actually happen: _refreshFavicons compares the
    // titles on screen against it and returns early when they match, so
    // restarting the timer alone would be a no-op. Anything already answered
    // is still skipped, since the retry only asks about what has no answer.
    root.faviconLive = []
    faviconDebounce.restart()
  }

  Process {
    id: faviconProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._applyFavicons(text)
    }
  }

  // Everything still on SCREEN, and nothing else.
  //
  // Keyed on faviconLive rather than on what was last asked about: the query
  // only covers titles with no answer yet, so pruning to it would throw away
  // every icon already resolved. A title still on screen that momentarily
  // failed to resolve keeps the icon it had -- re-assigning a tile's Image
  // source is what makes it flash -- while a window that has navigated away
  // takes its entry with it.
  function _pruneFavicons() {
    var live = root.faviconLive
    var idx = ({})
    for (var k = 0; k < live.length; k++) {
      var prev = root.faviconIndex[live[k]]
      if (typeof prev === "string") idx[live[k]] = prev
    }
    return idx
  }

  // Same bound as _pruneFavicons and for the same reason: keyed on what is on
  // screen, never on everything that has ever been asked about. typeof rather
  // than a plain test, like every other lookup in here -- a page titled
  // "constructor" reads the inherited Object.prototype member otherwise.
  function _pruneFaviconTries() {
    var live = root.faviconLive
    var t = ({})
    for (var k = 0; k < live.length; k++) {
      var n = root.faviconTries[live[k]]
      if (typeof n === "number") t[live[k]] = n
    }
    return t
  }

  function _applyFavicons(text) {
    var keys = root.faviconKeys
    var idx = root._pruneFavicons()
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab <= 0) continue
      var tab2 = lines[i].indexOf("\t", tab + 1)
      if (tab2 <= tab) continue
      var n = parseInt(lines[i].substring(0, tab), 10)
      if (!(n >= 0 && n < keys.length)) continue
      // The media type is sniffed from the blob rather than assumed: Chromium
      // re-encodes every favicon to PNG, Firefox stores what the site served,
      // and a data: URL that lies about its type is refused by Qt silently.
      var mime = lines[i].substring(tab + 1, tab2)
      // Checked, not trusted, because this file and favicons.py can be
      // DIFFERENT VERSIONS at runtime: `omarchy plugin update` replaces the
      // script on disk while this QML stays in the running shell until a
      // restart, so a field the old parser does not expect ends up spliced
      // into the URL. Seen for real -- a 2-field parser reading 3-field output
      // produced `data:image/png;base64,image/png<TAB>iVBOR...` and Qt logged
      // one "Unsupported image format" per frame. Rejecting the line instead
      // keeps a version skew silent, which is what every other failure here is.
      if (!/^[a-z]+\/[a-z0-9.+-]+$/.test(mime)) continue
      idx[keys[n]] = "data:" + mime + ";base64," + lines[i].substring(tab2 + 1)
    }
    root.faviconIndex = idx
    root.faviconTries = root._pruneFaviconTries()
    root._armFaviconRetry()
  }

  // Arm the second look only while there is something left to look for: a title
  // on screen, with no answer, that has not yet spent its attempts. Once every
  // live title is either answered or spent this arms nothing, so the retry
  // terminates instead of turning into a poll.
  function _armFaviconRetry() {
    var live = root.faviconLive
    for (var k = 0; k < live.length; k++) {
      if (typeof root.faviconIndex[live[k]] === "string") continue
      var n = root.faviconTries[live[k]]
      if ((typeof n === "number" ? n : 0) < root.faviconMaxTries) {
        faviconRetry.restart()
        return
      }
    }
    faviconRetry.stop()
  }

  function _sameKeys(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function _refreshFavicons() {
    // Re-arm rather than drop. The timer has already fired by the time this
    // runs, so returning outright would leave the badge missing until some
    // unrelated event happened to restart it -- which on a quiet desktop can
    // be a long time.
    if (faviconProc.running) { faviconDebounce.restart(); return }
    var vs = Hyprland.toplevels.values
    var keys = []
    var seen = ({})
    for (var i = 0; i < vs.length; i++) {
      var o = vs[i].lastIpcObject
      if (!o || o.mapped !== true) continue
      var cls = o["class"] || o.initialClass || ""
      if (!root._isBrowser(cls) || root._webAppEntry(cls)) continue
      var k = root._pageTitle(cls, o.title)
      // `=== 1`, not a truthiness test, for the same reason refreshEvents uses
      // one: a page titled "constructor" or "toString" would otherwise match
      // the inherited member and be dropped from every query.
      if (k.length === 0 || seen[k] === 1) continue
      seen[k] = 1
      keys.push(k)
    }
    // Nothing to ask about, and nothing to clear either: leaving the index
    // alone means closing the last browser window does not discard answers a
    // reopened one would want back.
    if (keys.length === 0) return

    // Find the browser profiles the first time a browser window is actually
    // on screen, rather than at launch. Two reasons, and the second is the
    // better one: a session with no browser open never pays the 28ms sweep,
    // and -- since that sweep is a walk of the hidden directories of $HOME --
    // a machine that never opens a browser never has its home directory
    // examined by this plugin at all.
    //
    // Returning here rather than querying without profiles is deliberate: the
    // helper would fall back to sweeping for itself, per query, which is the
    // 31ms path this exists to avoid. _applyFaviconProfiles clears faviconLive
    // and restarts the debounce, so the query runs one cycle later with the
    // profiles in hand.
    if (!root.faviconSwept) {
      if (!faviconDiscover.running) faviconDiscover.running = true
      return
    }
    // Every title on screen is already the subject of the last query, and the
    // TITLE cannot have changed -- it IS the key, so a page that becomes
    // something else becomes a different key. This is what keeps ordinary
    // browsing free: windowtitle fires on every page load and this refresh
    // hangs off the same debounce, so without it each one would cost a process.
    //
    // What an unchanged title does NOT settle is whether the ANSWER is
    // unchanged, which is what this guard was read as saying for as long as it
    // stood alone. The answer comes out of a database the browser writes on its
    // own schedule -- ~10s behind the navigation -- so the first look at a page
    // you just opened misses and a look a few seconds later hits. faviconRetry
    // is that second look, and faviconRetryDue is how it gets past here. A
    // window event still cannot, which is the point.
    var retry = root.faviconRetryDue
    root.faviconRetryDue = false
    if (root._sameKeys(keys, root.faviconLive) && !retry) return
    root.faviconLive = keys

    // Ask only about what has no answer yet AND has attempts left. Anything
    // answered is already correct by construction -- see faviconKeys -- and
    // anything out of attempts is a page this cannot resolve at all, which is a
    // state to stop paying for rather than one to keep testing.
    var ask = []
    for (var n = 0; n < keys.length; n++) {
      if (typeof root.faviconIndex[keys[n]] === "string") continue
      var tried = root.faviconTries[keys[n]]
      if ((typeof tried === "number" ? tried : 0) >= root.faviconMaxTries) continue
      ask.push(keys[n])
    }
    if (ask.length === 0) {
      // Nothing worth a process: every title here is either answered or spent.
      // Prune to the new set -- a window closed, or navigated back to a page
      // seen earlier -- and let _armFaviconRetry decide whether to come back.
      root.faviconKeys = []
      root.faviconIndex = root._pruneFavicons()
      root.faviconTries = root._pruneFaviconTries()
      root._armFaviconRetry()
      return
    }
    // Counted at ASK time rather than at failure time, because a query that
    // never answers at all -- no python3, a helper that died on start -- has to
    // count too or it would retry for ever. Rebuilt from `keys` rather than
    // mutated, which prunes it to the live set in the same pass.
    var tries = ({})
    for (var t = 0; t < keys.length; t++) {
      var was = root.faviconTries[keys[t]]
      tries[keys[t]] = (typeof was === "number" ? was : 0)
    }
    for (var a = 0; a < ask.length; a++) tries[ask[a]] = tries[ask[a]] + 1
    root.faviconTries = tries
    root.faviconKeys = ask

    // python3 rather than the sqlite3 CLI, although the CLI starts in 1ms
    // against python's 8 and this build's base64() would remove the encoding
    // step: the CLI has no way to BIND a value, so every window title -- which
    // is a string a remote web page chose -- would have to be escaped into SQL
    // text by hand, in a shell whose `writefile()` is one quote away. Not a
    // trade worth 7ms.
    //
    // `-S` skips the `site` module, which halves interpreter startup here
    // (16ms -> 8ms) and costs nothing: everything favicons.py imports is
    // stdlib, so it never needed site-packages on sys.path.
    faviconProc.command = ["python3", "-S", root.pluginRoot + "favicons.py"]
      .concat(root.faviconProfiles).concat(["--"]).concat(ask)
    faviconProc.running = true
  }

  // Friendly app name for the class, shown ahead of the window title as
  // "App Name (title)". Same class-matching idiom as glyphFor, so the two
  // stay in step.
  //
  // Three steps, most specific first: a web app is named by its own desktop
  // entry rather than by the browser hosting it; then the curated list below,
  // which exists only for names we deliberately disagree with the entry about;
  // then the entry's Name=, which is what the launcher shows. Title-casing the
  // raw class (last segment of a reverse-DNS style class, e.g.
  // "org.gnome.Nautilus") is the last resort, for a window whose class joins to
  // no entry at all, rather than leaving the tile unlabelled.
  function nameFor(cls) {
    // A web app is named by its desktop entry, not by the browser hosting it.
    // Without this the Slack tile reads "Chrome" -- correct for the class,
    // useless on screen, and identical to every other web app you have.
    var w = root._webAppEntry(cls)
    if (w && w.name.length > 0) return w.name
    var c = String(cls || "").toLowerCase()
    function has() {
      for (var i = 0; i < arguments.length; i++)
        if (c.indexOf(arguments[i]) !== -1) return true
      return false
    }
    if (has("ghostty")) return "Ghostty"
    else if (has("alacritty")) return "Alacritty"
    else if (has("kitty")) return "Kitty"
    else if (has("foot")) return "Foot"
    else if (has("wezterm")) return "WezTerm"
    else if (has("xterm")) return "XTerm"
    else if (has("konsole")) return "Konsole"
    else if (has("firefox")) return "Firefox"
    else if (has("librewolf")) return "LibreWolf"
    else if (has("floorp")) return "Floorp"
    else if (has("zen-browser", "zen_browser")) return "Zen"
    else if (has("waterfox")) return "Waterfox"
    else if (has("chromium")) return "Chromium"
    else if (has("chrome")) return "Chrome"
    else if (has("helium")) return "Helium"
    else if (has("vivaldi")) return "Vivaldi"
    else if (has("brave")) return "Brave"
    else if (has("edge")) return "Edge"
    else if (has("opera")) return "Opera"
    else if (has("cursor")) return "Cursor"
    else if (has("code")) return "VS Code"
    else if (has("sublime")) return "Sublime Text"
    else if (has("jetbrains", "idea")) return "IntelliJ IDEA"
    else if (has("pycharm")) return "PyCharm"
    else if (has("webstorm")) return "WebStorm"
    else if (has("zed")) return "Zed"
    else if (has("vim")) return "Vim"
    else if (has("emacs")) return "Emacs"
    else if (has("steam")) return "Steam"
    else if (has("spotify")) return "Spotify"
    else if (has("vlc")) return "VLC"
    else if (has("mpv")) return "mpv"
    else if (has("celluloid")) return "Celluloid"
    else if (has("gimp")) return "GIMP"
    else if (has("inkscape")) return "Inkscape"
    else if (has("krita")) return "Krita"
    else if (has("thunderbird")) return "Thunderbird"
    else if (has("discord")) return "Discord"
    else if (has("slack")) return "Slack"
    else if (has("telegram")) return "Telegram"
    else if (has("signal")) return "Signal"
    else if (has("beeper")) return "Beeper"
    else if (has("nautilus", "files")) return "Files"
    else if (has("thunar")) return "Thunar"
    else if (has("pcmanfm")) return "PCManFM"
    else if (has("dolphin")) return "Dolphin"
    else if (has("nemo")) return "Nemo"
    else if (has("obsidian")) return "Obsidian"
    else if (has("obs")) return "OBS Studio"
    else if (has("pinta")) return "Pinta"
    else if (has("imv")) return "Image Viewer"
    else if (has("kdenlive")) return "Kdenlive"
    else if (has("evince", "papers")) return "Document Viewer"
    else if (has("zathura")) return "Zathura"
    else if (has("okular")) return "Okular"
    else if (has("libreoffice-writer")) return "LibreOffice Writer"
    else if (has("libreoffice-calc")) return "LibreOffice Calc"
    else if (has("libreoffice-impress")) return "LibreOffice Impress"
    else if (has("libreoffice-draw")) return "LibreOffice Draw"
    else if (has("libreoffice-base")) return "LibreOffice Base"
    else if (has("libreoffice-math")) return "LibreOffice Math"
    else if (has("libreoffice")) return "LibreOffice"
    else if (has("localsend")) return "LocalSend"
    else if (has("moonlight")) return "Moonlight"
    else if (has("xournal")) return "Xournal++"
    else if (has("cliamp")) return "cliamp"
    else if (has("docker")) return "Docker"
    else if (has("qv4l2", "qvidcap")) return "Qt V4L2"
    else if (has("cheese")) return "Cheese"
    else if (has("omacalc")) return "Omacalc"
    else if (has("omawrite")) return "Omawrite"
    else if (has("omacut")) return "Omacut"

    // Nothing curated matched -- take the name off the desktop entry, which is
    // the same Name= the launcher reads, so the two surfaces agree by
    // construction instead of by a second list kept in step by hand.
    //
    // Figma Desktop is the case that exposed it: the launcher showed
    // "Figma Desktop" (its entry's Name=) while a hardcoded has("figma") here
    // answered "Figma". The chain above is now only for names we deliberately
    // disagree with the entry about -- "VS Code" over "Visual Studio Code",
    // "mpv" over mpv.desktop's "Media Player" -- and everything else resolves
    // itself, including apps that are not in it at all.
    //
    // The join is classIndex's, so it is only as good as the entry's
    // StartupWMClass. Upstream's Figma entry declares StartupWMClass=Figma
    // against a live class of `figma-desktop`, which matches nothing; the local
    // entry is corrected to the class Hyprland actually reports.
    var e = root.classIndex[c]
    if (e && String(e.name || "").length > 0) return String(e.name)

    var seg = String(cls || "").split(".").pop().replace(/[-_]+/g, " ").trim()
    if (!seg) return ""
    return seg.replace(/\w\S*/g, function (w) {
      return w.charAt(0).toUpperCase() + w.slice(1)
    })
  }

  // Window titles come from arbitrary apps and sometimes carry icon glyphs,
  // emoji or other symbols that don't exist in the menu font and render as
  // tofu boxes. Rather than a Unicode-range regex (whose \p{} property
  // escapes aren't reliably supported by every JS engine build), this is a
  // plain character whitelist checked by String.indexOf -- easy to read and
  // to extend with one more character.
  readonly property string titleWhitelist:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789æøåÆØÅ" +
    " ,.-:()&'!?"

  function sanitizeTitle(s) {
    var str = String(s || "")
    // Hoisted: this is a QML property read, and it sat inside the loop -- one
    // lookup per character of every title on every rebuild.
    var allowed = root.titleWhitelist
    var out = ""
    for (var i = 0; i < str.length; i++) {
      var ch = str.charAt(i)
      if (allowed.indexOf(ch) !== -1) out += ch
    }
    return out.trim()
  }

  Process { id: focusProc }
  Process { id: moveProc }
  Process { id: placeProc }


  // ── Window list ─────────────────────────────────────────────────────────────
  //
  // Kept warm from Hyprland's event socket rather than rebuilt by shelling out
  // to `hyprctl clients -j` on every summon. Two things made that worth doing:
  //
  //  - The old path spawned a process and parsed its JSON on every open. That
  //    turned out NOT to be the visible cost: end-to-end open latency measured
  //    the same (~40ms) before and after, because it is dominated by the
  //    `omarchy-shell shell summon` spawn in the keybind itself. One less
  //    process per keypress is still worth having, but it is not why this
  //    changed.
  //  - It then assigned `root.wins` unconditionally. Measured with a delegate
  //    lifecycle probe, a repeat open rebuilt a list that was byte-identical
  //    (`same=true`) and still reset the ListView, destroying and recreating
  //    cells. A recreated cell's icon Image starts out `Loading`, so the
  //    delegate falls back to its Nerd Font glyph for a frame or two before the
  //    icon pops in -- the flicker.
  //
  // What is live and what is not, measured against this Quickshell build:
  //
  //  - `Hyprland.rawEvent` is live -- openwindow/closewindow/movewindow/... all
  //    arrive on the event socket as they happen.
  //  - `toplevel.activated` is live, and tracks focus with no refresh at all.
  //  - `toplevel.lastIpcObject` is a SNAPSHOT, not live. Its `focusHistoryID`
  //    sat at 2/1/0 across two focus changes. So the ordering fields (`at`,
  //    `class`, `workspace`) need an explicit refreshToplevels(), and the
  //    focused window has to come from `activated`, never focusHistoryID.
  //  - `Hyprland.toplevels` is populated lazily. In a bare Quickshell instance
  //    it is EMPTY until something calls refreshToplevels(); inside the Omarchy
  //    shell it already held 3 entries by the time this plugin's onCompleted
  //    ran. Both are true, which is why the prime below does BOTH: refresh (for
  //    the empty case) and rebuild (for the already-populated case). Relying on
  //    a valuesChanged signal instead deadlocks the already-populated case --
  //    the signal has already been and gone, and the list stays empty forever.
  //    That was a real bug here, not a hypothetical.
  Component.onCompleted: { iconScan.running = true; vendorScan.running = true; pluginIconScan.running = true; Hyprland.refreshToplevels(); root._rebuild() }

  // Events that can change the set of windows or their on-screen order. Focus
  // changes are deliberately absent: `activated` already tracks those live, and
  // refreshing on them would rebuild the list on every commit.
  //
  // A lookup object rather than an array: onRawEvent runs for EVERY event on
  // the compositor socket, and this stays one hash probe however many event
  // names get added below. The `=== 1` test (not a truthiness test) is what
  // keeps an event named after something on Object.prototype -- "constructor",
  // "toString" -- from matching the inherited member.
  readonly property var refreshEvents: ({
    openwindow: 1, closewindow: 1, movewindow: 1, movewindowv2: 1,
    windowtitle: 1, windowtitlev2: 1, changefloatingmode: 1, fullscreen: 1,
    monitoradded: 1, monitorremoved: 1
  })

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (root.refreshEvents[event.name] !== 1) return
      refreshDebounce.restart()
    }
  }

  // A single window move emits several events in a burst; coalesce them into
  // one refresh rather than one IPC round-trip each.
  Timer {
    id: refreshDebounce
    interval: 24
    repeat: false
    onTriggered: { Hyprland.refreshToplevels(); rebuildAfterRefresh.restart() }
  }

  // refreshToplevels() rewrites each toplevel's lastIpcObject in place. The
  // values array itself is untouched, so valuesChanged does NOT fire and the
  // rebuild has to be scheduled by hand once the IPC round-trip has landed.
  Timer {
    id: rebuildAfterRefresh
    interval: 40
    repeat: false
    onTriggered: root._rebuild()
  }

  // Favicons are looked up on the same signal the window list is, one step
  // slower. A page load changes the title two or three times before it settles
  // -- a bare host, then the real title -- and each one reaches this; 400ms is
  // long enough that only the settled title is ever asked about, and short
  // enough that the answer is waiting before the strip is next opened.
  //
  // Deliberately NOT hung off open(): a lookup there would land after the tiles
  // were already on screen and the icon would pop in. Keeping the index warm
  // instead means the common case -- a window whose page has not changed since
  // the last time -- draws its badge in the first frame.
  Timer {
    id: faviconDebounce
    interval: 400
    repeat: false
    onTriggered: root._refreshFavicons()
  }

  // The second look -- and the reason a badge appears at all on a page you have
  // only just opened.
  //
  // A browser does not write a visit to its history database when it happens.
  // Chromium batches and commits 10.07s later: measured against a throwaway
  // profile, navigation driven over DevTools, polling the DB exactly as
  // favicons.py opens it. The lookup above runs ~464ms after a title settles --
  // 24ms of refreshDebounce, 40ms of rebuildAfterRefresh, 400ms of the debounce
  // -- so the page in front of you is invisible to that query by construction,
  // every single time.
  //
  // On its own that would be a transient miss. What made it PERMANENT was the
  // unchanged-key-set guard in _refreshFavicons: the title on screen does not
  // change, so the key set does not change, so nothing ever asked again.
  // Measured on a real profile, 70% of navigations were to a URL with no prior
  // visit -- so most pages silently never got a badge for the life of that
  // window on them, which is exactly what this read as in use.
  //
  // 12s rather than 10.1: a retry landing ON the commit races it.
  Timer {
    id: faviconRetry
    interval: 12000
    repeat: false
    onTriggered: { root.faviconRetryDue = true; root._refreshFavicons() }
  }

  Connections {
    target: Hyprland.toplevels
    function onValuesChanged() { root._rebuild() }
  }

  // Focus history. Only shifts when the focused window actually changes, so
  // re-focusing the same window does not lose the window before it -- otherwise
  // committing to where you already are would erase the thing you wanted to go
  // back to.
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      var t = Hyprland.activeToplevel
      var a = t ? root._addr(t.address) : ""
      if (a === "" || a === root.activeAddr) return
      root.prevAddr = root.activeAddr
      root.activeAddr = a
    }
  }

  // Hyprland's own addresses carry an 0x prefix in the IPC object but not on
  // the toplevel handle. Compared raw, nothing ever matches and every open
  // starts from index 0.
  function _addr(a) {
    var t = String(a || "")
    return t.indexOf("0x") === 0 ? t.substring(2) : t
  }

  function _rebuild(force) {
    // Ahead of the freeze below, on purpose. The MODEL is frozen while the
    // strip is up, but faviconIndex is a root property the delegates bind
    // through rather than part of the model, so an answer that lands mid-open
    // reaches the tile without reshuffling anything.
    faviconDebounce.restart()

    // Frozen while the strip is on screen: a macOS Cmd-Tab list does not
    // reshuffle under the hand holding it, and re-assigning the model mid-open
    // is exactly what made the icons flicker.
    //
    // A drop is the one thing that has to get through. It changed the list
    // ITSELF, deliberately, and freezing it out would leave the tile sitting in
    // the group it was just dragged out of. The exception is a WINDOW of time
    // rather than a single rebuild because the move is a hyprctl process: the
    // debounced refresh can beat it, see the list unchanged and stop there, and
    // the movewindow event that follows would then find the freeze back on.
    if (root.opened && !force && !dropUnfreeze.running) return

    var vs = Hyprland.toplevels.values
    var mapped = []
    for (var i = 0; i < vs.length; i++) {
      var o = vs[i].lastIpcObject
      if (!o || o.mapped !== true) continue
      if (!o.workspace || (o.workspace.id | 0) <= 0) continue // special / scratchpad
      // Agent terminals are deliberately NOT filtered, though they were once.
      // Omarchy launches them as `ghostty --class=org.omarchy.agent`, which at
      // the time only happened while working on this plugin -- hence the old
      // "this plugin's own dev window" skip. They are now simply how a Claude
      // session runs, so the filter hid the very window you were typing in and
      // made it unreachable with Cmd+Tab. Do not put it back without checking
      // that first.
      mapped.push(o)
    }

    // Loaded means a window actually SURVIVED the filters, not that Hyprland
    // has told us toplevels exist.
    //
    // vs.length > 0 was the earlier signal and it lied: right after a restart
    // the toplevel objects arrive before their lastIpcObject is filled in, so
    // every one of them fails the `!o` test above, mapped comes out empty, and
    // the flag said loaded while the strip held nothing but placeholders. Third
    // variant of the same bug -- the first counted wins.length, the second
    // trusted a returned refresh, this one trusted an unpopulated object.
    if (mapped.length > 0) root.listLoaded = true

    var out = []
    var occupied = ({})
    for (var j = 0; j < mapped.length; j++) {
      var m = mapped[j]
      var wid = (m.workspace && m.workspace.id) | 0
      occupied[wid] = true
      var t = (m.title && m.title !== "") ? m.title
        : (m.initialTitle && m.initialTitle !== "") ? m.initialTitle
        : ""   // no title -- the detail line renders an ellipsis for this
      out.push({
        kind: "window",
        address: m.address,
        title: t,
        cls: m["class"] || m.initialClass || "",
        ws: String((m.workspace && m.workspace.name) || "").trim(),
        wsId: wid,
        x: (m.at && m.at[0]) | 0,
        y: (m.at && m.at[1]) | 0
      })
    }

    // A tile per empty workspace, so Cmd+Tab can reach a blank desktop the same
    // way it reaches a window -- previously the only route was the bar or a
    // workspace keybind.
    //
    // The synthetic "ws:N" address is what lets everything downstream stay as
    // it was: _sameWins still compares addresses and sees a real difference,
    // _activeIndex and _mruIndex match against live window addresses and simply
    // never hit one of these, and commit() branches on kind.
    for (var w = 1; w <= root.emptyWorkspaceSlots; w++) {
      if (occupied[w]) continue
      out.push({
        kind: "workspace",
        address: "ws:" + w,
        title: "Empty",
        cls: "",
        ws: String(w),
        wsId: w,
        x: -1,
        y: -1
      })
    }

    // Order of appearance: workspace first (ascending id, matching the bar),
    // then left-to-right / top-to-bottom position within that workspace --
    // not MRU. The focused window is found separately, via `activated`. An
    // empty workspace carries x/y of -1, so it sorts to the head of its own id
    // -- which is the whole workspace, there being nothing else there.
    out.sort(function (a, b) {
      if (a.wsId !== b.wsId) return a.wsId - b.wsId
      if (a.x !== b.x) return a.x - b.x
      return a.y - b.y
    })

    // A placement walk steps off THIS list, and the model is deliberately left
    // alone until the walk is over.
    //
    // Assigning it resets the ListView and takes every delegate with it --
    // measured on a nine-tile strip, one reorder is create 9 / destroy 9 -- and
    // a walk would pay that once per step, so a three-place move would blink
    // the whole strip three times while the user watches it rearrange. The walk
    // does not need the model to do its work, only a current list, which is
    // exactly what `out` is. So it steps off `out` and the strip updates once,
    // at the end, showing where the window came to rest.
    if (root.dropPlacePending) {
      root._placeStep(out)
      if (root.dropPlacePending) return
    }

    // The whole point: only touch the model when something actually changed.
    // An unchanged assignment resets the ListView and churns delegates.
    if (!root._sameWins(out, root.wins)) root.wins = out

    // A drop moved a window; the sort has just put it somewhere else in the
    // strip. Carry the highlight with it, or releasing SUPER focuses whatever
    // slid into the index the dragged tile used to occupy.
    if (root.dropFollowAddr !== "") {
      for (var f = 0; f < root.wins.length; f++) {
        if (root._addr(root.wins[f].address) !== root.dropFollowAddr) continue
        root.index = f
        break
      }
    }

    if (!root.listPending) return
    root.listPending = false
    // Deliberately NOT marking the list loaded here.
    //
    // It used to, on the reasoning that a returned refresh is authoritative
    // even when empty. It is not, right after a shell restart: refreshToplevels
    // can come back before Hyprland's toplevel list has reached us, so an empty
    // answer marked the list loaded, the placeholders sailed through the
    // length check, and the strip opened on five empty workspaces with six
    // windows on screen. Only actually SEEING a toplevel counts -- see the
    // vs.length check at the top of this function.
    //
    // The cost is a genuinely window-less session, where the strip then never
    // opens at all. That was the behaviour before empty workspaces existed, and
    // a session with no windows has nothing to switch between but blank
    // desktops.

    // Cold-start presses that landed before the list did.
    //
    // listLoaded is checked as well as the count, and that is the whole point:
    // out.length counts empty-workspace placeholders, so a refresh that came
    // back before Hyprland's toplevels reached us still clears the bar here and
    // opens the strip on five empty workspaces. The count cannot tell "nothing
    // to switch to" from "nothing arrived yet"; the flag can. Dropping the
    // queued presses in that case costs one keypress, which beats opening onto
    // a list that is wrong.
    if (!root.listLoaded || out.length < 2) { // nothing to switch to, or nothing yet
      root.pendingSteps = 0
      root.pendingCommit = false
      return
    }
    root._openStepped(root.pendingSteps)
    if (root.pendingCommit) { root.pendingCommit = false; root.commit() }
  }

  function _sameWins(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      if (a[i].address !== b[i].address) return false
      if (a[i].title !== b[i].title) return false
      if (a[i].cls !== b[i].cls) return false
      if (a[i].ws !== b[i].ws) return false
    }
    return true
  }

  // Index of the window Hyprland currently has focused. `activated` is live, so
  // this is read at open time rather than baked into the cached list.
  function _activeIndex() {
    var vs = Hyprland.toplevels.values
    var addr = ""
    for (var i = 0; i < vs.length; i++) {
      if (vs[i].activated) { addr = root._addr(vs[i].address); break }
    }
    // Cold fallback. `activated` is only set once Quickshell has seen an
    // activewindow event, so on the very first summon after a shell restart
    // nothing reports it and every window looks unfocused -- which silently
    // opened the strip one step from index 0 instead of from the focused
    // window, and a tap then committed straight back to where it started.
    // focusHistoryID is a stale field in general, but it is accurate in the
    // snapshot we just refreshed, which is exactly this case.
    if (addr === "") {
      for (var k = 0; k < vs.length; k++) {
        var o = vs[k].lastIpcObject
        if (o && (o.focusHistoryID | 0) === 0) { addr = root._addr(o.address); break }
      }
    }
    if (addr === "") return 0
    for (var j = 0; j < root.wins.length; j++) {
      if (root._addr(root.wins[j].address) === addr) return j
    }
    return 0
  }

  // Where the previously focused window sits in the CURRENT positional order,
  // or -1 if it is gone (closed, or on a workspace being filtered out).
  function _mruIndex() {
    if (root.prevAddr === "") return -1
    for (var i = 0; i < root.wins.length; i++) {
      if (root._addr(root.wins[i].address) === root.prevAddr) return i
    }
    return -1
  }

  // Open the strip `step` places from whatever is focused right now.
  function _openStepped(step) {
    // Never inherit the last open's drag. Nothing should be able to leave one
    // hanging, but a stale dragIndex would dim a tile of the NEW list and let a
    // stray release drop a window somewhere nobody asked for.
    root._dragCancel()
    var n = root.wins.length
    if (n < 2) return
    var cur = root._activeIndex()
    var k = step | 0
    var idx

    if (k > 0) {
      // The first forward tap goes to the window you came from, which is what
      // makes SUPER+TAB alternate. Any further taps in the same gesture then
      // walk the positional order from there, so the highlight moves along the
      // strip the way it looks like it should rather than hopping around a
      // history the tiles do not show.
      var m = root._mruIndex()
      idx = (m >= 0 && m !== cur) ? m : (cur + 1) % n
      idx = (idx + (k - 1)) % n
    } else {
      // SHIFT+TAB stays purely positional: stepping backwards through a history
      // the strip does not display has no visible meaning.
      idx = ((cur + k) % n + n) % n
    }

    root.index = ((idx % n) + n) % n
    root.pendingSteps = 0
    root.opened = true
    idleTimer.restart()
  }

  // --- Pointer hover ----------------------------------------------------------
  //
  // Real Qt hover events, via the MouseArea over the tile row.
  //
  // This used to poll: `hyprctl cursorpos -j` on a 40ms timer, because the
  // surface was click-through (an empty input region) and so received no Qt
  // pointer events at all. That is 25 process spawns a second, ~3-4ms each,
  // for the entire time the strip is on screen -- burning CPU and adding JSON
  // parsing exactly when the thing needs to feel smooth.
  //
  // Masking the surface to the card (mask: Region { item: card }) gave it a
  // real input region, so hover now arrives for free and the poll is gone.
  // onPositionChanged only fires when the pointer actually moves, which also
  // replaces the old `hoverBase` distance threshold: that existed purely so a
  // cursor resting on a tile at open time would not yank the selection off the
  // keyboard's choice, and a movement-only signal gives that for nothing.

  // Which tile is at `lx`, measured from the START of the ListView's content
  // (contentX - originX, not contentX alone -- cell 0 begins at originX, which
  // is what the overflow scrims below also measure against).
  // -1 for "none" -- past the end, or in the gap between two cells. Shared by
  // the hover handler and the click handler so the two can never disagree about
  // what is under the cursor.
  // True where tile `i` opens a new workspace group, which is what earns it
  // the wider lead gap.
  function _groupStart(i) {
    return i > 0 && i < root.wins.length
      && root.wins[i].wsId !== root.wins[i - 1].wsId
  }

  // Left edge of tile `i` within the content. The uniform stride is still the
  // bulk of it; every group break before `i` adds one groupGap on top. Linear
  // rather than cached: the strip is a handful of tiles, and a cache would be
  // one more thing to invalidate when wins changes.
  function _cellX(i) {
    var x = i * (card.cellW + card.gap)
    for (var k = 1; k <= i && k < root.wins.length; k++)
      if (root.wins[k].wsId !== root.wins[k - 1].wsId) x += card.groupGap
    return x
  }

  // The compositor's output scale, which is NOT Screen.devicePixelRatio.
  //
  // Qt draws this surface at buffer scale 2 and Hyprland resamples it to the
  // output's 1.25, so a logical pixel is 1.25 physical ones. Qt only knows
  // about the 2. Anything that has to land on a whole SCREEN pixel needs the
  // 1.25, and Hyprland is the only thing that has it.
  readonly property real outputScale: {
    var m = Hyprland.focusedMonitor
    if (!m) return 1
    var s = Number(m.scale)
    if (!isFinite(s) || s <= 0) {
      var o = m.lastIpcObject
      s = o ? Number(o.scale) : 1
    }
    return (isFinite(s) && s > 0) ? s : 1
  }

  // Round a logical length to land on a whole physical pixel.
  //
  // Without this a 3px rule is 3.75 physical, and every rule resolves that
  // fraction differently depending on where it falls -- measured 4, 3 and 3
  // columns for three rules that are nominally identical. Snapping the width
  // AND the position puts them all on the same grid, so they come out the same
  // width as each other, which is what "breaking on scaling" actually looked
  // like. Perfect crispness is not on offer -- a buffer pixel is 0.625 screen
  // pixels, so nothing can be integral in both -- but consistency is.
  function _snapPx(v) {
    var s = root.outputScale
    if (!(s > 0)) return v
    return Math.round(v * s) / s
  }

  function _cellAt(lx) {
    if (lx < 0) return -1
    for (var i = 0; i < root.wins.length; i++) {
      var x = root._cellX(i)
      if (lx < x) return -1              // in a gap, before this tile starts
      if (lx <= x + card.cellW) return i
    }
    return -1
  }

  // --- Drag and drop ----------------------------------------------------------
  //
  // Press a tile, move past the drag threshold, release over another
  // workspace's group: the window is moved there, silently, and the strip stays
  // up with the highlight following it. Released anywhere else -- over its own
  // group, or off the card entirely -- nothing happens, which is what a drop on
  // no target normally means.
  //
  // A press that never travels far enough is still a click, and still focuses.

  // Which workspace the pointer is offering to drop on.
  //
  // Per GROUP, not per tile, because the thing being dropped on is a workspace
  // -- the strip already draws one as a run of tiles with a rule down the side.
  // Nearest tile centre, so the gap between two groups belongs to whichever is
  // closer and every x resolves to exactly one workspace: a drop can miss the
  // card, but it cannot fall between two groups and quietly do nothing.
  function _wsAt(lx) {
    var best = -1
    var bestD = -1
    for (var i = 0; i < root.wins.length; i++) {
      var d = Math.abs(lx - (root._cellX(i) + card.cellW / 2))
      if (bestD < 0 || d < bestD) { bestD = d; best = i }
    }
    return best < 0 ? -1 : root.wins[best].wsId
  }

  // [first, last] tile index of a workspace's group, or [-1, -1]. The list is
  // sorted by workspace, so a group is always one contiguous run -- which is
  // what lets the drop-target highlight be a single rectangle.
  // `arr` defaults to the model, but the placement walk passes the list a
  // rebuild has just computed and NOT yet assigned -- see _rebuild.
  function _groupRange(wsId, arr) {
    var w = arr || root.wins
    var first = -1
    var last = -1
    for (var i = 0; i < w.length; i++) {
      if (w[i].wsId !== wsId) continue
      if (first < 0) first = i
      last = i
    }
    return [first, last]
  }

  function _dragStart(i) {
    root.dragIndex = i
    root.dragging = true
    // The dragged tile is what the highlight means for the rest of the gesture:
    // it is the thing in the hand, and releasing SUPER has to focus it rather
    // than whatever the pointer happened to pass over on the way.
    root.index = i
  }

  // lx is in ListView CONTENT coordinates; cx/cy in card coordinates.
  function _dragTo(lx, cx, cy) {
    root.dragX = cx
    root.dragY = cy
    var inCard = cx >= 0 && cy >= 0 && cx <= card.width && cy <= card.height
    root.dropWsId = inCard ? root._wsAt(lx) : -1
    // Which boundary within the group the pointer is offering: one slot per gap
    // between its tiles, plus one at each end. Counting the tile centres the
    // pointer has passed gives all of them with no special case -- 0 when it is
    // left of everything, m when it is right of everything.
    if (root.dropWsId > 0) {
      var r = root._groupRange(root.dropWsId)
      var j = 0
      if (r[0] >= 0 && root.wins[r[0]].kind === "window") {
        for (var t = r[0]; t <= r[1]; t++)
          if (lx >= root._cellX(t) + card.cellW / 2) j++
      }
      root.dropSlot = j
    }
    idleTimer.restart()
  }

  function _dragCancel() {
    root.dragIndex = -1
    root.dragging = false
    root.dropWsId = -1
  }

  function _dragDrop() {
    if (!root.dropReady) { root._dragCancel(); return }
    var i = root.dragIndex
    var w = root.wins[i]
    var ws = root.dropWsId
    var slot = root.dropSlot
    root._dragCancel()
    if (w.kind !== "window" || !w.address) return

    // Slot -> final index. The two differ by one whenever the window is already
    // in this group and is being moved to the RIGHT of where it sits: taking it
    // out shifts everything after it down a place, so the boundary it was aimed
    // at has moved too. Dropping into a group it is not yet part of has no such
    // shift, and the slot is the index.
    var gr = root._groupRange(ws)
    var occupied = gr[0] >= 0 && root.wins[gr[0]].kind === "window"
    var m = occupied ? (gr[1] - gr[0] + 1) : 0
    var j = Math.max(0, Math.min(m, slot))
    root.dropPlaceIndex = (ws === w.wsId && occupied && j > (i - gr[0])) ? j - 1 : j

    root.dropPlacePending = true
    root.dropPlaceWs = ws
    root.dropPlaceLastAt = -1
    root.dropPlaceSteps = 0
    root.dropFollowAddr = root._addr(w.address)
    dropUnfreeze.restart()

    if (ws === w.wsId) {
      // Already on the workspace it was dropped on: nothing to move BETWEEN
      // workspaces, so this is a pure re-arrange and the strip in front of us
      // is already the arrangement to measure against.
      root._placeStep(root.wins)
      return
    }

    // follow = false: this is organising, not navigating. The same dispatcher
    // SUPER + SHIFT + ALT + <n> uses (default/hypr/bindings/tiling.lua:24),
    // with `window` naming the tile that was dragged rather than whatever
    // happens to be focused -- the HUD never takes focus, so the active window
    // is emphatically not the one in the hand.
    moveProc.command = ["hyprctl", "dispatch",
      "hl.dsp.window.move({ workspace = \"" + ws + "\", window = \"address:"
        + w.address + "\", follow = false })"]
    moveProc.running = true

    // A nudge, not the mechanism: movewindow lands on the event socket and
    // restarts this anyway. It only matters if the compositor were to move the
    // window without saying so.
    refreshDebounce.restart()
  }

  // Walk the dropped window to the slot it was dropped on, ONE STEP PER REBUILD,
  // reading the list the rebuild computed rather than the model itself.
  //
  // There is no "insert at index" to dispatch -- Hyprland moves a window one
  // neighbour at a time -- and the whole distance cannot be sent at once.
  // Measured on a three-window workspace: two `r` steps in a single
  // `hyprctl --batch` advanced the window ONE position, not two. A dwindle
  // workspace is a tree and every step reshapes it (the widths change, not just
  // the order), so the second dispatch in a batch is resolved against a layout
  // the first has already invalidated.
  //
  // Stepping on the rebuild fixes that by construction: each step is resolved
  // against the arrangement the strip is actually showing, because that is the
  // same arrangement the refresh just read back from the compositor. It is also
  // self-limiting -- a step that moves nothing ends the walk -- which is what
  // keeps a layout this cannot express from spinning. The cost is a round trip
  // per step, about 75ms, which no drag is going to notice.
  //
  // `window` is what makes any of it work: the dispatcher acts on the named
  // window, on a workspace nobody is looking at, leaving focus alone --
  // verified. `swapwindow` looks like the better primitive, being inherently
  // edge-safe, but it ignores `window` and acts on the active one.
  function _placeStep(arr) {
    if (!root.dropPlacePending) return
    var i = -1
    for (var k = 0; k < arr.length; k++) {
      if (root._addr(arr[k].address) === root.dropFollowAddr) { i = k; break }
    }
    if (i < 0) return
    var w = arr[i]
    if (w.kind !== "window" || !w.address) { root.dropPlacePending = false; return }
    // Until the window is actually ON the workspace it was dropped on, this is
    // still looking at the arrangement it is leaving.
    if (w.wsId !== root.dropPlaceWs) return

    var r = root._groupRange(w.wsId, arr)
    if (r[0] < 0) { root.dropPlacePending = false; return }
    var at = i - r[0]
    var want = Math.max(0, Math.min(r[1] - r[0], root.dropPlaceIndex))

    if (at === want) { root.dropPlacePending = false; return }   // arrived

    // Same position the last step was sent from: the refresh has not caught up
    // yet, so wait for one that has.
    //
    // This deliberately does NOT read as "the layout refused". A refusal emits
    // no movewindow at all and so arrives as SILENCE -- placeSettle below is
    // what ends the walk on it. Conflating the two cost a real bug: a stale
    // snapshot looked identical to a refusal, and a two-step walk gave up after
    // gaining one place. Measured, then confirmed by hand: the step the walk
    // had written off moved the window perfectly well when it was re-sent.
    //
    // Stepping again on a stale read is the other half of why this has to be
    // here: it would send a second step for one place of need, and overshoot.
    if (root.dropPlaceSteps > 0 && at === root.dropPlaceLastAt) return
    if (root.dropPlaceSteps >= 8) { root.dropPlacePending = false; return }
    root.dropPlaceLastAt = at
    root.dropPlaceSteps++
    placeSettle.restart()

    // Which axis the group is laid out on, re-read every step because a step
    // reshapes the tree. A workspace split top-and-bottom sorts by y in the
    // strip, so "earlier" there means the top and stepping it left would do
    // nothing at all. One row or one column is the whole of the
    // layout-awareness here; a workspace mixing the two is not something a
    // strip of tiles can express, and no attempt is made to.
    var column = arr[r[0]].x === arr[r[1]].x && arr[r[0]].y !== arr[r[1]].y
    var forward = want > at
    var dir = column ? (forward ? "d" : "u") : (forward ? "r" : "l")

    placeProc.command = ["hyprctl", "dispatch",
      'hl.dsp.window.move({ direction = "' + dir + '", window = "address:'
        + w.address + '" })']
    placeProc.running = true

    // Hold the list open for the next step, and for the one after that.
    dropUnfreeze.restart()
    refreshDebounce.restart()
  }

  // Auto-scroll while dragging against an edge.
  //
  // The strip is wider than the card as soon as there are more windows than
  // fit, and the group you most want to drop on is then exactly the one off the
  // end -- without this the drag cannot reach it and the feature quietly fails
  // on the busy desktop it is most useful on. The ListView is
  // `interactive: false`, so contentX is ours to move; speed ramps with how far
  // into the edge zone the pointer is, the way a drag-scroll normally does.
  Timer {
    id: dragScroll
    interval: 16
    repeat: true
    running: root.dragging
    onTriggered: {
      if (root.dropWsId < 0) return          // pointer is off the card entirely
      if (list.contentWidth <= list.width) return
      var lx = root.dragX - list.x           // pointer, in VIEWPORT coordinates
      var edge = card.cellW / 2
      var step = 0
      if (lx < edge) step = -Math.round((edge - lx) / 4)
      else if (lx > list.width - edge) step = Math.round((lx - (list.width - edge)) / 4)
      if (step === 0) return
      var max = list.originX + list.contentWidth - list.width
      var next = Math.max(list.originX, Math.min(max, list.contentX + step))
      if (next === list.contentX) return
      list.contentX = next
      // The strip moved under a pointer that did not, so the offer changed.
      root.dropWsId = root._wsAt(lx + list.contentX - list.originX)
    }
  }

  // Silence ends the walk.
  //
  // A step Hyprland declines emits no movewindow, so no refresh and no rebuild
  // follow it -- there is nothing to observe, only an absence. This is that
  // absence made concrete: restarted by every step, so it only ever fires when
  // one produced nothing. Generous against the measured ~64ms refresh chain,
  // because firing early would cut a walk short exactly the way the old
  // unchanged-reading test did.
  //
  // It forces the rebuild it ends on, because the model has been held back for
  // the length of the walk and a refused step leaves no event to flush it.
  Timer {
    id: placeSettle
    interval: 300
    repeat: false
    onTriggered: {
      root.dropPlacePending = false
      root._rebuild(true)
    }
  }

  // How long the list stays unfrozen after a drop -- long enough for the
  // hyprctl process, the toplevel refresh and the rebuild behind it to land.
  Timer {
    id: dropUnfreeze
    interval: 600
    repeat: false
    onTriggered: {
      root.dropFollowAddr = ""
      // A placement still pending here never saw its window reach the
      // workspace -- dropped onto one it could not move to, or the move
      // failed. Drop it rather than let it fire against some later drag, and
      // flush the model, which the walk has been holding back.
      var wasPending = root.dropPlacePending
      root.dropPlacePending = false
      if (wasPending) root._rebuild(true)
    }
  }

  Timer {
    id: idleTimer
    interval: root.idleTimeoutMs
    repeat: false
    onTriggered: root.dismiss() // safety only — never switches focus
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-window-switcher-hud"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Unmasked, deliberately. This used to mask input to the card
    // (mask: Region { item: card }) so the rest of the full-screen surface
    // stayed click-through -- the same idiom Omarchy uses for notification
    // toasts, which are passive and long-lived.
    //
    // A switcher is neither. It is modal for the moment it is up, and clicking
    // beside it should dismiss it rather than land on whatever happened to be
    // behind. Eating those clicks is only a hazard for a surface that is up
    // when you are not looking at it; `visible: root.opened` means this one
    // never is.

    // Click-away. Sits before the card, so anything the tile handlers above it
    // take never reaches here; this only sees what they did not. A press inside
    // the card that missed a tile -- the padding, the gaps between groups -- is
    // ignored rather than treated as "outside", or clicking the card's own
    // margin would close the thing you are aiming at.
    //
    // This is a real press now, not a keybind reporting one. It used to be
    // unreachable with SUPER held, because SUPER + mouse:272 was bound and the
    // bind consumed the button before the surface ever saw it; the bind now
    // stands down for as long as the strip is up.
    MouseArea {
      id: clickAway
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton

      function inCard(x, y) {
        var p = mapToItem(card, x, y)
        return p.x >= 0 && p.y >= 0 && p.x <= card.width && p.y <= card.height
      }

      onClicked: function (mouse) {
        if (clickAway.inCard(mouse.x, mouse.y)) return
        root.dismiss()   // close, never switch -- see dismiss() vs commit()
      }
    }

    // The SUPER+SPACE menu's own scrim, bound rather than reproduced.
    //
    // This used to compose its own colour at 0.35 -- the value the theme's
    // inert [launcher] section intends -- on the theory that a switcher wants a
    // touch more separation from the desktop than a menu does. Measured against
    // the menu side by side (solving composited = a*background + (1-a)*backdrop)
    // that read 0.37 against the menu's 0.22, and the two surfaces visibly did
    // not match. Aligned deliberately: they are the same kind of overlay and
    // should dim the desktop identically.
    //
    // Binding the role instead of composing a literal is what makes light and
    // dark both correct without a second value here. Color.menu.scrim resolves
    // `scrim` / `scrim-alpha` from each theme's own shell.menu.toml against that
    // theme's palette -- "background" over #1E1E1E in dark, over #FFFFFF in
    // light -- so a theme switch, or a retune of the menu's scrim, carries the
    // switcher with it. Change it in shell.menu.toml, not here.
    //
    // Still below the layer rule's ignore_alpha (0.6) in
    // hypr/window-switcher-looknfeel.lua -- 0.25 is further below it than
    // 0.35 was -- so the scrim stays unblurred and the windows being switched
    // between remain readable.
    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim

      // No fade here: the compositor owns it now.
      //
      // This ran a 120ms / OutCubic Behavior so the scrim eased in while the
      // card landed instantly under the keypress -- the compositor cannot fade
      // a card and its scrim separately, they are one layer surface. The side
      // effect was that the switcher was the only surface in the shell whose
      // CONTENT did not ramp, which read as noticeably faster than the Omarchy
      // panels beside it.
      //
      // hypr/window-switcher-looknfeel.lua now puts this namespace in the
      // same `animation = "fade"` layer rule as the menu and the other
      // keyboard-driven panels, so the whole surface ramps over layersIn's
      // 133ms on easeOutQuint. A Behavior here would stack on top of that.
      //
      // The binding stays. `opened` going false unmaps the window in the same
      // frame, so on screen this only ever evaluates to 1, but it keeps the
      // scrim tied to the same state the rest of this file reads.
      opacity: root.opened ? 1 : 0
    }

    // Card: same chrome as an Omarchy menu — theme menu background, the
    // themed menu border spec, panel padding, shared corner radius.
    BorderSurface {
      id: card
      x: Math.round((parent.width - width) / 2)
      y: Math.round((parent.height - height) / 2)

      // Tile width, as a named token rather than a bare number.
      //
      // The number was never raw pixels: Style.space(px) multiplies by
      // effectiveSpacingScale (spacingScale * fontScale), so it has always
      // tracked `omarchy display text size` and a theme's `[spacing] scale`.
      // What it lacked was a handle. spacingToken() gives it one -- a theme can
      // now set `switcher-cell-width` in its [spacing] section and win, exactly
      // as it can for xs/md/lg or dropdown-width, and the fallback below is
      // what applies otherwise.
      //
      // Note the asymmetry, which is spacingToken's own and not ours: an
      // override is taken RAW (rounded, unscaled), while the fallback goes
      // through space(). A theme setting this is stating a final width; the
      // default is stating a width at scale 1.
      //
      // 150 stepped down twice from the original 212 (212 -> 180 -> 150, about
      // -15% each time). Narrower tiles put more of the strip on screen and sit
      // closer to macOS's own Cmd-Tab proportions. Both text lines already
      // elide, so the only cost is fewer characters before the ellipsis -- no
      // layout gives way.
      readonly property int cellW: Style.spacingToken("switcher-cell-width", 150)
      readonly property int gap: Style.spacing.xs

      // Extra space inserted where the workspace changes, so the strip reads as
      // groups rather than one run. Tiles stay a uniform width; only the space
      // before a group's first tile grows, which is why _cellX below has to do
      // the arithmetic the ListView's own uniform `spacing` cannot.
      readonly property int groupGap: Style.spacingToken("switcher-group-gap", 36)
      // Same shape as Menu.qml's baseRowHeight/detailRowHeight: a floor, raised
      // if the stacked contents need more. Keeps the cell honest when
      // `omarchy display text size` grows the font tokens.
      // Gap between the icon and the title, as one named token. The delegate's
      // Column has a single uniform `spacing` that also sets the title/subtitle
      // gap, and those two lines want to stay a pair -- so the Column keeps its
      // xs and the title tops the rest up with topPadding. Step this along
      // Style.spacing (xs 3 / sm 4 / md 6 / lg 8 / xl 10) to retune; rowH and
      // the padding both derive from it, so there is one place to change.
      // The running-program processIcon, as two knobs on the same ladder
      // (xxs 2 / xs 3 / sm 4 / md 6 / lg 8 / xl 10).
      //
      // Its size is stated as how much SMALLER than the icon it sits on it is,
      // rather than as a fraction of it, so that stepping it means the same
      // thing as stepping anything else here -- a bigger inset is a smaller
      // processIcon. It was a 3/4 ratio, which had no step to take.
      //
      // The two move together. What is actually being tuned is neither number
      // but the sliver of terminal icon left showing at the top left, which is
      // `processIconInset + processIconOffset` wide -- 8px here. Raise the offset with the
      // size and that sliver holds; raise it alone and more of the terminal
      // shows; lower it alone and the processIcon swallows the icon, which is what
      // full size did.
      readonly property int processIconInset: Style.spacing.xxs
      readonly property int processIconSize: Math.max(1, card.iconDrawn - card.processIconInset)
      readonly property int processIconOffset: Style.spacing.md
      readonly property int iconTitleGap: Style.spacing.lg
      readonly property int iconTitleTopUp: Math.max(0, card.iconTitleGap - Style.spacing.xs)

      // The floor is a named token for the same reason cellW is: it is what
      // actually decides tile height. The computed side sits well under it
      // (85 against 104 at the default base), so the floor wins outright and a
      // theme with no say over it has no say over the tile.
      //
      // Style.spacing.xs rather than Style.space(3): identical by default, but
      // space(3) hard-codes the number a theme can rename through the `xs` key.
      // The Column below spaces itself by xs, and these two terms are its two
      // gaps -- so they have to move together with it, not with a literal.
      readonly property int rowH: Math.max(
        Style.spacingToken("switcher-row-height", 104),
        card.iconSize + Style.font.heading + Style.font.title
          + Style.spacing.xs * 2 + card.iconTitleTopUp + Style.spacing.rowPaddingX * 2)
      // In the menu the icon sits inline beside a label (Style.font.iconLarge);
      // here it's the primary element of a card, so it steps up the type scale
      // -- the way a macOS Cmd-Tab tile leads with its icon.
      //
      // fontPx(1.667) is 20 at the default base, one step down from the
      // `display` token (2.0 rem / 24) this used to be. There is no token in
      // between: the ladder runs title 14, heading 16, display 24, so taking
      // the next token down would have put the icon at 16 -- the same size as
      // the name line beneath it, which stops reading as an icon-led tile.
      //
      // Stepping off the ladder costs two things, both accepted knowingly. It
      // no longer picks up a per-theme `display` override, and fontPx rounds
      // wherever 1.667 isn't exact (20.0 at base 12, 23.33 -> 23 at base 14)
      // where the old 2.0 was exact at every base size. A correctly
      // proportioned tile at the size actually in use beats an exact multiple
      // at sizes that are not.
      readonly property int iconSize: Style.fontPx(1.667)

      // What an ICON is drawn at, as opposed to the em box a glyph gets. The
      // two are not the same thing and never were.
      //
      // A Nerd Font glyph does not fill its em box. Measured off a screen
      // capture at this size, ink is 26px of a 29px box -- and the 26 holds
      // across glyphs of very different shapes: desktop 29x26, code 32x26,
      // chrome 26x26. Widths vary with the mark, HEIGHT does not. An
      // edge-to-edge SVG fills its box completely, so handed the same number it
      // renders about 11% larger than the glyph beside it.
      //
      // 0.9 closes that, measured rather than guessed: 26/29 = 0.897.
      readonly property int iconDrawn: Math.round(card.iconSize * 0.9)
      // Matches the menu's cursor-row border (Menu.qml selectedBorderSpec), so
      // the theme's [menu] selected-border / selected-border-alpha reach the
      // HUD instead of being silently dropped.
      readonly property var selectedBorderSpec:
        Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
      readonly property int stripW: root.wins.length > 0
        ? root._cellX(root.wins.length - 1) + cellW
        : 0
      // Overflow scrim width: the card's own left/right padding (so the
      // fade starts right at the card edge, not inset from it) plus
      // two-thirds of a cell -- enough that a cell sitting right at the edge
      // is fully inside the scrim's opaque run, not just brushed by its
      // fade tail.
      readonly property int scrimW: Math.min(
        card.contentLeftInset + card.cellW * 2 / 3, list.width / 2)

      color: Color.menu.background
      radius: Style.cornerRadius
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding

      width: Math.min(parent.width - Style.gapsOut * 2,
                      card.contentLeftInset + card.contentRightInset + stripW)
      height: card.contentTopInset + card.contentBottomInset + rowH

      // Drop target: the workspace group the pointer is offering to drop on.
      //
      // Declared before the ListView so it renders BENEATH the tiles -- a drop
      // target is a place things land on, and a translucent sheet over the
      // labels would only mute the group it is meant to be offering. Same
      // scroll-tracking, clipped-wrapper shape as the group rules further down,
      // for the same reason: the rectangle belongs to the content, not to the
      // viewport it is seen through.
      Item {
        id: dropTarget
        x: list.x
        y: list.y
        width: list.width
        height: list.height
        clip: true
        visible: root.dropReady

        readonly property var range: root.dropReady ? root._groupRange(root.dropWsId) : [-1, -1]

        BorderSurface {
          visible: dropTarget.range[0] >= 0
          // Out to the middle of the gap on each side, so the highlight covers
          // the whole run and not just the tiles in it.
          x: root._cellX(dropTarget.range[0]) - (list.contentX - list.originX) - card.gap / 2
          width: root._cellX(dropTarget.range[1]) - root._cellX(dropTarget.range[0])
            + card.cellW + card.gap
          height: parent.height
          radius: Style.cornerRadius
          // The cursor cell's own fill and border. There is no separate
          // drop-target role in the palette, and inventing a colour here would
          // be the one thing in this file that does not come from the theme --
          // "the place the selection is about to go" is close enough to "the
          // selection" to borrow its treatment.
          color: Color.menu.selectedBackground
          borderSpec: card.selectedBorderSpec
        }
      }

      ListView {
        id: list
        x: card.contentLeftInset
        y: card.contentTopInset
        width: Math.min(card.width - card.contentLeftInset - card.contentRightInset, card.stripW)
        height: card.rowH
        orientation: ListView.Horizontal
        spacing: card.gap
        interactive: false
        clip: true
        // Retain every cell, even one sitting a fraction of a pixel outside the
        // viewport. Without this the rightmost delegate is culled and rebuilt on
        // each open (measured: destroy 2 / create 2, every time), and a rebuilt
        // cell's icon Image starts out `Loading` -- so it shows its fallback
        // glyph for a frame before the icon appears. Cheap: the strip is a
        // handful of cells, never a long list.
        cacheBuffer: Math.max(card.stripW, 1)
        model: root.wins
        currentIndex: root.index
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        // Styled after an Omarchy menu row (Menu.qml's row delegate): a
        // BorderSurface whose selected state gets Color.menu.selectedBackground
        // + selectedText + the selected-border spec, radius = cornerRadius,
        // label in heading/Medium and the secondary line in title at 0.52
        // (bumped two token steps up from the menu's own bodySmall).
        // Only the icon deliberately departs -- see card.iconSize.
        // Wrapped so a tile can carry the group gap in front of it: ListView's
        // own `spacing` is uniform, and this is the only place the extra space
        // can live without the tiles themselves changing width.
        delegate: Item {
          id: slot
          readonly property bool groupStart: root._groupStart(index)
          width: card.cellW + (slot.groupStart ? card.groupGap : 0)
          height: list.height

          // Group separator: a hairline down the middle of the lead gap.
          //
          // Centred on the VISUAL gap rather than on the slot. The previous
          // tile ends one ListView `gap` behind this slot's origin, so the
          // empty run actually spans -gap..groupGap in slot coordinates and its
          // midpoint is (groupGap - gap) / 2, not groupGap / 2.
          //
          // Colour and weight both come from the theme rather than from here.
          // Color.muted is the palette's own muted role -- colour8, falling
          // back to foreground -- which is what a divider between groups wants:
          // secondary information, not the surface-edge treatment the border
          // role is tuned for.
          //
          BorderSurface {
            id: cell
            x: slot.groupStart ? card.groupGap : 0
            width: card.cellW
            height: list.height
            radius: Style.cornerRadius
            readonly property bool sel: index === root.index
            color: sel ? Color.menu.selectedBackground : "transparent"
            borderSpec: sel ? card.selectedBorderSpec : Border.none()
            // Lifted. The tile being dragged fades back to a hole in the strip
            // while the ghost under the cursor carries it, which is how a
            // dragged item normally reads -- and it keeps the two from looking
            // like two copies of the same window.
            opacity: (root.dragging && index === root.dragIndex) ? 0.3 : 1

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.spacing.rowPaddingX * 2
              spacing: Style.spacing.xs

              // The mark. Almost always a Nerd Font glyph rendered as text --
              // crisp at this size, and it recolours for free on selection. The
              // exception is an app with a hand-placed icon in one of the
              // drop-in directories -- see iconFor() above.
              //
              // Drawn exactly as the file is. No recolouring, here or anywhere:
              // an icon is the source of truth for its own appearance, and
              // whoever placed it decided how it should look. The only thing
              // this plugin does to an icon is scale its viewBox to match the
              // others, and that happens in the FILE -- see AGENTS.md -- never
              // at draw time.
              //
              // Height tracks the fallback Text's implicitHeight, not iconSize,
              // so swapping a glyph for an image shifts no layout: line height
              // exceeds pixelSize, and rowH above is written against the old
              // stacking.
              Item {
                id: mark
                anchors.horizontalCenter: parent.horizontalCenter
                width: card.iconSize
                height: glyphText.implicitHeight
                // Resolved once from the cached index, never probed. hasIcon is
                // the only thing the layer, the effect and the glyph below key
                // off -- deliberately NOT Image.status, see iconFor() above.
                readonly property string iconUrl: root.iconFor(modelData.cls)
                readonly property bool hasIcon: mark.iconUrl.length > 0
                readonly property bool isWorkspace: modelData.kind === "workspace"

                // What is running inside this terminal, if anything an icon
                // index can name. Cached exactly as iconUrl is, and for exactly
                // the same reason: the processIcon owns an item tree, and item
                // structure keyed on Image.status is what aborted the shell
                // four times -- see iconFor() above. This comes from the index
                // and cannot move while Qt walks the tree.
                readonly property string processIconUrl:
                  root.processIconFor(modelData.cls, modelData.title)
                readonly property bool hasProcessIcon: mark.processIconUrl.length > 0

                // Match the INK, not the canvas -- but only where there IS
                // canvas, which is the half of this that was wrong.
                //
                // There is no ink-ratio compensation here any more, and that is
                // the point: every drop-in is an edge-to-edge SVG, so the drawn
                // box IS iconSize and an icon sits beside a glyph of the same
                // pixelSize with nothing to reconcile.
                //
                // It used to scale the box by 256/200, which was right for a PNG
                // and wrong for an SVG. The sync this plugin was extracted
                // alongside trimmed each raster and re-padded it onto a 256x256
                // canvas at 200x200, so its ink really was 200/256 of the file,
                // while the SVG branch only recoloured and copied -- a simple-icons source arriving
                // edge-to-edge. Applying the raster ratio to both drew every SVG
                // 28% oversized, overflowing the mark and clipping top and
                // bottom, while the correctly-sized rasters beside them looked
                // small and off-centre. One cause, both complaints.
                //
                // Compensating per asset fixed it but kept two conventions alive.
                // Dropping the rasters leaves one, enforced end to end: the
                // generator takes only .svg, the index indexes only .svg, and an
                // app with no drop-in falls back to its Nerd Font glyph.

                // ONE decode size, shared by both Images below.
                //
                // Screen.devicePixelRatio, deliberately -- it is what Qt actually
                // rasterises this surface at. Measured on this machine:
                // Screen.devicePixelRatio and Window.window.devicePixelRatio both
                // report 2 while Hyprland's output scale is 1.25, i.e. Qt takes
                // the next integer buffer scale and the COMPOSITOR scales the
                // finished 2x surface down to 1.25x. That last step is not
                // something a per-Image sourceSize can or should pre-compensate
                // for: decoding at 1.25 would draw a 45px image into a region Qt
                // renders at 72px, which is upscaling. See CLAUDE.md.
                readonly property int decodePx: Math.ceil(card.iconDrawn * Screen.devicePixelRatio)

                Image {
                  anchors.centerIn: parent
                  width: card.iconDrawn
                  height: width
                  // The index already picked the extension, so there is one Image
                  // per mark and no probe. Empty for a class with no drop-in,
                  // which loads nothing at all.
                  source: mark.iconUrl
                  // sourceSize is REQUIRED here, and for a reason that differs by
                  // format. For a raster it selects the decode resolution, and
                  // leaving it unset simply uses the file's own (256px) -- fine.
                  // For a VECTOR it selects the rasterisation resolution, and
                  // leaving it unset makes Qt rasterise at the SVG's intrinsic
                  // size, which for these sources is 24x24 (simple-icons) or
                  // 16x16 (freedesktop symbolic). Those then get scaled UP to the
                  // drawn size, which is exactly as blurry as it sounds. Omarchy's
                  // own Menu.qml sets it for the same reason.
                  sourceSize.width: mark.decodePx
                  sourceSize.height: mark.decodePx
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  // Kept as a hidden layer so the effect can sample it as a
                  // texture -- but only on tiles that HAVE one, so a glyph-only
                  // tile costs no FBO and no extra render pass. Measured against
                  // a live window set: chromium and ghostty resolve, cursor, the
                  // omarchy agent and the screensaver do not, so roughly half the
                  // strip was paying for a layer it never sampled.
                  //
                  // Keyed on hasIcon, not on status. status is not stable
                  // across a DPR change -- Qt reloads the Image from inside the
                  // item-tree walk -- and structure destroyed mid-walk is what
                  // aborted the shell. hasIcon comes from the cached index and
                  // cannot move while the walk runs.
                  visible: mark.hasIcon
                }

                Text {
                  id: glyphText
                  anchors.centerIn: parent
                  // Covers a machine with no drop-in directory at all, an empty
                  // one, and a name mismatch alike: all three leave the class
                  // out of every index, so the tile stays a glyph.
                  visible: !mark.hasIcon && !mark.isWorkspace
                  text: root.glyphFor(modelData.cls)
                  textFormat: Text.PlainText
                  font.family: Style.font.menuFamily
                  font.pixelSize: card.iconSize
                  color: cell.sel ? Color.menu.selectedText : Color.menu.text
                }

                // Empty-workspace mark: a DOTTED box, U+F0485.
                //
                // Picked by RENDERING candidates, not by name -- this font's
                // name-to-codepoint mapping does not match the Nerd Font
                // tables. nf-md-select (U+F0C08) draws a circled J here, and
                // U+2B1A DOTTED SQUARE is absent from the face entirely, which
                // matters because a missing glyph renders as NOTHING in this
                // font rather than tofu: an absent box and a blank slot look
                // identical, so name-guessing fails silently.
                //
                // F0489, which this was for a while, is the DASHED one: fewer,
                // longer segments, rounded corners. F0485 is dotted -- measured
                // by connected components at a 96px render, 16 separate 4x4
                // pieces of identical size evenly spaced around the perimeter.
                // Worth stating because the two are easy to confuse by eye at
                // tile size, and this file previously described F0485 as
                // "the same idea with square corners", which undersold it: it
                // is a different texture, not the same one squared off. Dotted
                // is the lighter, quieter mark, which is what an absence wants.
                //
                // Nothing else in the face competes. All 6895 glyphs in the
                // Material Design range were rendered and filtered to square-ish
                // hollow outlines (265), then ranked by how many disconnected
                // pieces of ink they contain: every other many-piece hit is a
                // dotted CIRCLE (F0D32, F0F22), or a dashed square carrying a
                // pin, a plus or an inner square (F0562, F055D, F1280, F0A6D).
                // F14FC is rounded but solid, so it reads as a container rather
                // than an absence.
                //
                // pixelSize is iconSize, the same as the app glyph below, so it
                // lands on the shared ink ratio with no extra arithmetic.
                // The processIcon: the running program's mark, a shade under the
                // size of the terminal's own and hanging past its bottom-right
                // corner. Both numbers are card.processIcon* knobs -- see there.
                //
                // Full size was tried and read as a replacement rather than an
                // overlay: at the same size, no offset small enough to look
                // deliberate leaves enough of the terminal icon to recognise,
                // and the tile stops saying "a terminal running this" and
                // starts saying "this". Three-quarters keeps the program
                // dominant -- it is the thing you are looking for -- while the
                // whole top-left of the terminal's mark stays clear.
                //
                // Behind a Loader so a tile that has no processIcon -- every app
                // window, every idle shell -- pays for no Image and no effect
                // at all. `active` keys off the cached bool above, never off a
                // load status.
                //
                // Positioned against the DRAWN icon box rather than against
                // `mark`, whose height is the glyph's line height and so taller
                // than the art it contains. Anchoring to the item would float
                // the processIcon below the corner it is meant to sit in.
                Loader {
                  id: processIcon
                  active: mark.hasProcessIcon
                  width: card.processIconSize
                  height: processIcon.width
                  // The icon box's bottom-right corner, then one step past it.
                  // The box is centred in `mark`, whose height is the glyph's
                  // line height rather than the art's -- hence the arithmetic
                  // instead of an anchor.
                  x: (mark.width + card.iconDrawn) / 2 - processIcon.width + card.processIconOffset
                  y: (mark.height + card.iconDrawn) / 2 - processIcon.height + card.processIconOffset

                  sourceComponent: Item {
                    // Nothing behind it, and nothing done to it. Two
                    // separation layers were tried and both were worse than
                    // nothing: a filled plate is visible AS a plate the moment
                    // the theme stops matching the art -- it punched a dark
                    // square through the ghost on the first dark theme -- and a
                    // fitted shadow pools into a smudge on a sparse mark like
                    // Claude's. The icon hangs mostly outside the terminal's own
                    // at the current offset, so it needs less than either
                    // attempt assumed.
                    Image {
                      anchors.fill: parent
                      source: mark.processIconUrl
                      sourceSize.width: Math.ceil(processIcon.width * Screen.devicePixelRatio)
                      sourceSize.height: Math.ceil(processIcon.width * Screen.devicePixelRatio)
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                    }
                  }
                }

                Text {
                  visible: mark.isWorkspace
                  anchors.centerIn: parent
                  text: String.fromCodePoint(0xF0485)
                  textFormat: Text.PlainText
                  font.family: Style.font.menuFamily
                  font.pixelSize: card.iconSize
                  // No selection tint, unlike every other mark in the tile. An
                  // empty workspace is a place rather than a thing you are
                  // looking at, and recolouring it made the strip twitch under
                  // a passing pointer.
                  color: Color.menu.text
                }
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: modelData.kind === "workspace"
                  ? "Workspace " + modelData.wsId
                  : (root.nameFor(modelData.cls) || root.sanitizeTitle(modelData.title))
                // Tops the Column's uniform xs up to card.iconTitleGap. Counted
                // into card.rowH too, or the taller stack is clipped by the
                // fixed cell height.
                topPadding: card.iconTitleTopUp
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.Medium
                // Selection colours this, from the pointer and the keyboard
                // alike. The launcher draws no such distinction -- its row
                // delegate is `row.hasCursor ? selectedText : foreground`
                // (Menu.qml:1242), and hovering a row selects it outright
                // (onEntered -> selectFromPointer, Menu.qml:1340) -- and
                // neither do the icon and glyph above. The detail line below
                // never changed colour at all, so it needs no equivalent.
                color: cell.sel ? Color.menu.selectedText : Color.menu.text
              }
              // Detail line: just the title. The workspace is carried by the
              // gap in the strip, not by anything in here -- see card.groupGap.
              // A "1 - " prefix and, briefly, a filled number processIcon both lived
              // here first; each spent horizontal room in a 150px tile to repeat
              // what adjacency already says.
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                // An ellipsis when there is no title to show.
                //
                // Covers two cases that look the same on screen: a window that
                // reports no title at all, and one whose title survives
                // sanitizeTitle as nothing -- an all-CJK title, say, since the
                // whitelist is Latin plus a few marks. Both used to read
                // "(untitled)", which spent a 150px line saying so.
                //
                // The character cannot come from the model: it is not in
                // titleWhitelist, so sanitizeTitle would strip it right back
                // out. It has to be applied after sanitising, here.
                text: modelData.kind === "workspace"
                  ? "Empty"
                  : (root.sanitizeTitle(modelData.title) || "…")
                textFormat: Text.PlainText
                elide: Text.ElideRight
                maximumLineCount: 1
                font.family: Style.font.menuFamily
                // One step above Menu.qml's detail line, which is bodySmall
                // (Menu.qml:1299, at the same opacity 0.52).
                //
                // It has been walked down to find this: `title` was two steps
                // over and read as a different component next to the launcher;
                // bodySmall matched exactly but sat too quiet under a heading
                // in a card this wide. `body` is the step between.
                //
                // The label above matches the launcher outright -- heading /
                // Font.Medium / elide, the same as Menu.qml:1286 -- so the
                // deviation is confined to this line, on purpose.
                font.pixelSize: Style.font.body
                color: Color.menu.text
                opacity: 0.52
              }
            }
          }
        }
      }

      // Group rules, drawn OVER the card rather than inside the ListView.
      //
      // The list clips to its own height -- it has to, or a scrolled cell
      // spills past the viewport -- so a rule parented to a delegate can never
      // reach the card's top and bottom edges. Lifting it out is the only way
      // to span the container.
      //
      // x tracks the list's scroll so the rules stay welded to the gaps they
      // belong to, and the wrapper clips horizontally so none escapes the
      // viewport when the strip is wider than the card. The card's own border
      // draws at z 100000, above this, so a rule cannot bleed into the edge.
      Item {
        id: groupRules
        // The card's own border width, from the same spec the card draws with,
        // so the rules stop exactly where the stroke begins instead of running
        // under it. Top and bottom are read separately: the spec is a
        // {top,right,bottom,left} shape and a theme may set them apart.
        readonly property var edge: card.borderSpec.widths
        readonly property real edgeTop: groupRules.edge ? groupRules.edge.top : 0
        readonly property real edgeBottom: groupRules.edge ? groupRules.edge.bottom : 0
        // The other two edges, for the overflow scrims below. Same shape and
        // the same reason: a theme may set the four apart.
        readonly property real edgeLeft: groupRules.edge ? groupRules.edge.left : 0
        readonly property real edgeRight: groupRules.edge ? groupRules.edge.right : 0

        x: list.x
        y: groupRules.edgeTop
        width: list.width
        height: card.height - groupRules.edgeTop - groupRules.edgeBottom
        clip: true

        Repeater {
          model: root.wins.length

          delegate: Rectangle {
            id: groupRule
            // 3x the theme's hairline. It has climbed 1 -> 1.5 -> 3: at full
            // card height a hairline reads as a hesitation rather than a
            // division, and the gap it sits in is 32px, so there is room.
            readonly property real stroke: Math.max(1, Style.normalBorderWidth) * 3
            visible: root._groupStart(index)
            // Centred in the gap between the two tiles, and centred on its own
            // stroke within that.
            //
            // _cellX is the TILE's left edge, so the empty run in front of it
            // is gap + groupGap wide and its midpoint is half that back. This
            // read `+ (groupGap - gap) / 2` while the rule still lived inside
            // the delegate, where x was relative to the SLOT -- one groupGap
            // further left. Lifting it out onto the card without re-deriving
            // the offset put every rule 28px into the tile to its right.
            x: root._snapPx(root._cellX(index) - (list.contentX - list.originX)
              - (card.gap + card.groupGap) / 2 - groupRule.width / 2)
            width: root._snapPx(groupRule.stroke)
            height: parent.height
            // The hover/selection background -- the same fill a tile takes
            // when the cursor is on it.
            //
            // There is no dedicated hover role in the palette; the menu's
            // hovered row and its cursor row are one and the same
            // (menu.selected-background), so that is the honest source. It is
            // also exactly the step this rule wants: the theme sets it to
            // #F6F6F6 on light, with the note that #FFFFFF "has no brighter
            // tier -- white is the ceiling", i.e. the palette's own nearest
            // move off the surface colour.
            //
            // Which is the thing pure white and pure black both got wrong from
            // opposite directions: one vanished into the card, the other cut
            // through it like chrome. A hair off the surface reads as a seam.
            color: Color.menu.selectedBackground
          }
        }
      }


      // Insertion caret: WHICH END of the target group the window would land on.
      //
      // Drawn over the tiles, unlike the group highlight beneath them, because
      // it has to be legible against that highlight -- and it hugs the group's
      // outer edge rather than sitting mid-gap where the group rules are, so
      // the two read as different things at a glance: a rule divides, a caret
      // points at a slot.
      //
      // Sized to the ROW, not to the card, which is the other half of that
      // distinction. The group rules deliberately run the full card height --
      // they are the card's own divisions, and are drawn against `card.height`
      // inside their own wrapper for exactly that reason. This is a mark on the
      // tiles, so it takes the tiles' box: `list` geometry, the same the group
      // highlight and every cell already use.
      //
      // Clamped into the viewport, which is what covers the first and last
      // groups: their outer edge is the card's own padding, with no gap to sit
      // in, so without this the caret would be clipped away exactly where the
      // strip most needs to show it.
      Item {
        id: dropCaret
        x: list.x
        y: list.y
        width: list.width
        height: list.height
        clip: true
        visible: root.dropArrangeReady

        readonly property var range: root.dropArrangeReady ? root._groupRange(root.dropWsId) : [-1, -1]

        Rectangle {
          id: caret
          // Same weight as a group rule: this is a boundary too.
          readonly property real stroke: Math.max(1, Style.normalBorderWidth) * 3
          visible: dropCaret.range[0] >= 0
          width: root._snapPx(caret.stroke)
          // Inset from the row by the card's own padding, top and bottom, so
          // the caret sits within the tiles rather than running their full
          // height. Read as topPadding/bottomPadding rather than as `padding`
          // doubled: BorderSurface carries the four separately and a theme may
          // set them apart, the same reason groupRules reads its border widths
          // per edge.
          y: card.topPadding
          height: Math.max(1, parent.height - card.topPadding - card.bottomPadding)
          // Fully rounded ends. Half the width is the only radius that reads as
          // finished on a bar this thin -- anything less leaves a visible flat,
          // and Style.cornerRadius (18 against a ~3px bar) would clamp to the
          // same pill anyway. Deliberately NOT the card's radius token: this is
          // a cap on a stroke, not a rounded box, so it follows the stroke.
          radius: caret.width / 2
          x: {
            var r = dropCaret.range
            if (r[0] < 0) return -caret.width
            var m = r[1] - r[0] + 1
            var j = Math.max(0, Math.min(m, root.dropSlot))
            // The boundary in front of tile j, or past the last tile when j is
            // the whole group. Within a group the tiles are one `gap` apart and
            // nothing else, so half a gap back from a tile's left edge IS the
            // boundary -- the same arithmetic at both ends and in between.
            var edge = (j < m)
              ? root._cellX(r[0] + j) - card.gap / 2
              : root._cellX(r[1]) + card.cellW + card.gap / 2
            var vx = edge - (list.contentX - list.originX) - caret.width / 2
            return root._snapPx(Math.max(0, Math.min(list.width - caret.width, vx)))
          }
          // The selection accent, not the group rules' surface step. This marks
          // an active target, and the group highlight underneath it already IS
          // selected-background -- a step off the surface would vanish into it.
          color: Color.menu.selectedText
        }
      }

      // Click a tile to focus that window; drag one onto another workspace's
      // group to move it there. Placed after the ListView so it sits above it;
      // the list is `interactive: false`, so nothing below competes for the
      // press. Geometry is copied from the list rather than anchored to it, so
      // `mouse.x` arrives already in list coordinates and the same _cellAt()
      // hit-test serves the press, the hover and the release alike.
      MouseArea {
        id: tiles
        x: list.x
        y: list.y
        width: list.width
        height: list.height
        acceptedButtons: Qt.LeftButton
        // A hand over the tiles, closing on one while it is being carried --
        // the pair every other draggable thing on the desktop uses.
        cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        // Moving the pointer over a cell makes it the highlight; releasing
        // SUPER then focuses it, same as with the keyboard.
        hoverEnabled: true

        // The tile under the press, if it is one that can be dragged at all --
        // a workspace tile is a destination, never cargo. -1 means this press
        // can only ever end up a click.
        property int dragCandidate: -1
        property real pressX: 0
        property real pressY: 0

        // ListView content coordinates: the list scrolls, _cellAt does not.
        function lx(x) { return x + list.contentX - list.originX }

        onPressed: function (mouse) {
          tiles.pressX = mouse.x
          tiles.pressY = mouse.y
          var i = root._cellAt(tiles.lx(mouse.x))
          tiles.dragCandidate =
            (i >= 0 && root.wins[i].kind === "window") ? i : -1
        }

        onPositionChanged: function (mouse) {
          if (!root.opened || root.wins.length < 2) return

          if (root.dragging) {
            root._dragTo(tiles.lx(mouse.x), mouse.x + list.x, mouse.y + list.y)
            return
          }

          if (tiles.dragCandidate >= 0 && (mouse.buttons & Qt.LeftButton)) {
            // Qt's own threshold rather than a number of our own, so the strip
            // agrees with everything else on this desktop about where a click
            // stops being a click. 8px here.
            var dx = mouse.x - tiles.pressX
            var dy = mouse.y - tiles.pressY
            if (Math.sqrt(dx * dx + dy * dy) < Qt.styleHints.startDragDistance) return
            root._dragStart(tiles.dragCandidate)
            root._dragTo(tiles.lx(mouse.x), mouse.x + list.x, mouse.y + list.y)
            return
          }

          // Plain hover. Deliberately after the drag branches: the highlight
          // belongs to the tile in the hand for the whole of a drag, and must
          // not follow the pointer across the tiles it passes over.
          var idx = root._cellAt(tiles.lx(mouse.x))
          if (idx < 0) return
          root.index = idx
        }

        // Released, not clicked, because a drag has to be able to end here
        // without also counting as a click on whatever it ended over -- a
        // MouseArea emits `clicked` on release however far the pointer
        // travelled in between.
        onReleased: function (mouse) {
          tiles.dragCandidate = -1
          if (root.dragging) { root._dragDrop(); return }
          var idx = root._cellAt(tiles.lx(mouse.x))
          if (idx < 0) return
          root.index = idx
          root.commit()
        }

        // The grab can be taken away -- the surface unmapping under a held
        // button, for one. Nothing in the hand then, and nothing dropped.
        onCanceled: { tiles.dragCandidate = -1; root._dragCancel() }

        // Wheel scrolls the strip sideways when it overflows.
        //
        // The list is `interactive: false`, so contentX is ours to move and
        // nothing below competes for the event. It reaches the surface at all
        // only because `SUPER + mouse_down` / `mouse_up` are unbound -- stock
        // Omarchy binds those to "Scroll active workspace forward/backward"
        // (default/hypr/bindings/tiling.lua:67), and Hyprland resolves a mouse
        // bind before handing the event to a layer surface, exactly as it does
        // for the button. With those binds in place the wheel would change
        // workspace out from under the strip instead of scrolling it.
        //
        // A vertical wheel drives the horizontal axis, because a vertical wheel
        // is the only one most mice have. A real horizontal wheel or a
        // trackpad's sideways gesture arrives as angleDelta.x and is preferred
        // when it is non-zero.
        onWheel: function (wheel) {
          if (list.contentWidth <= list.width) { wheel.accepted = false; return }
          var d = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y
          if (d === 0) { wheel.accepted = false; return }
          var max = list.originX + list.contentWidth - list.width
          list.contentX = Math.max(list.originX, Math.min(max, list.contentX - d))
          wheel.accepted = true
          // Scrolling is activity: it should hold the strip open the same way
          // stepping or dragging does.
          idleTimer.restart()
        }
      }

      // Overflow scrims, same idiom as the SUPER+SPACE menu's scroll scrims
      // (Menu.qml) -- just rotated to this strip's horizontal axis instead of
      // the menu's vertical one. Strength tracks how much content is still
      // hidden past each edge rather than a fixed on/off, so it reads
      // correctly the instant the strip opens already scrolled (e.g.
      // currentIdx landed mid-list) with no animation to catch up.
      Rectangle {
        // Anchored to the CARD's inner edge, not the list's.
        //
        // scrimW already includes the card's padding -- that is what its own
        // definition is for, "so the fade starts right at the card edge, not
        // inset from it" -- so starting at list.x counted that padding twice:
        // the fade began one padding in and ended one padding short, leaving a
        // bare band of card background between the scrim and the border at each
        // end, with whatever the ListView clipped stranded in it. Measured at
        // this card size: card [0..3048], list [22..3026], scrimW 130, so the
        // right scrim stopped at 3026 and left 22px of flat background.
        //
        // INNER edge, though, not the card's outer one. Run it to x: 0 and the
        // scrim paints over the border and squares off the rounded corner --
        // the border is not above these, whatever the group rules' comment says
        // about z 100000. So it stops where the stroke begins, exactly as
        // groupRules does vertically, and carries the card's own radius so the
        // corner it now reaches into stays round. Rounding all four corners is
        // free: the two at the transparent end of the gradient cannot be seen.
        x: groupRules.edgeLeft
        radius: Math.max(0, Style.cornerRadius - groupRules.edgeLeft)
        // The rules run the CARD's height, not the row's, so a scrim sized to
        // the row leaves the top and bottom of a rule sticking out past the
        // fade -- a hairline hanging in space at the card edge with nothing
        // either side of it. Matched to groupRules exactly rather than to the
        // list, and these draw after it, so a rule under a scrim goes with it.
        y: groupRules.y
        height: groupRules.height
        width: card.scrimW
        visible: opacity > 0
        opacity: list.contentWidth > list.width
          ? Math.max(0, Math.min(1, (list.contentX - list.originX) / width))
          : 0
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Color.menu.background }
          GradientStop { position: 1; color: Util.alpha(Color.menu.background, 0) }
        }
      }

      Rectangle {
        x: card.width - groupRules.edgeRight - width
        radius: Math.max(0, Style.cornerRadius - groupRules.edgeRight)
        y: groupRules.y
        height: groupRules.height
        width: card.scrimW
        visible: opacity > 0
        opacity: list.contentWidth > list.width
          ? Math.max(0, Math.min(1, (list.originX + list.contentWidth - list.width - list.contentX) / width))
          : 0
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Util.alpha(Color.menu.background, 0) }
          GradientStop { position: 1; color: Color.menu.background }
        }
      }
    }

    // The thing in the hand: a chip under the cursor carrying the window being
    // dragged. Sibling of the card rather than a child of it, so it can be over
    // the card's own border and outside its bounds -- a drag that leaves the
    // card has to stay visible, or letting go somewhere harmless looks like the
    // window was dropped into nothing.
    //
    // A reduced copy of the tile, not the tile itself. A ListView delegate
    // cannot leave its viewport, and taking the real item out of the model for
    // the length of a gesture is a much larger change than a drag ghost is
    // worth -- so the mark and the name are drawn again here, and the tile it
    // came from fades to a hole in the strip.
    BorderSurface {
      id: ghost

      // Guarded rather than read straight out of `wins`: this is bound while
      // the drag is being torn down too, and dragIndex is -1 by then.
      readonly property var win:
        (root.dragging && root.dragIndex >= 0 && root.dragIndex < root.wins.length)
          ? root.wins[root.dragIndex] : null

      visible: ghost.win !== null
      opacity: 0.92

      // The same radius a SUPER+SPACE menu row draws with -- bound to the same
      // token rather than copied as a number. `Menu.qml:1222` is
      // `root.cornerRadius` and `Menu.qml:98` defines that as
      // `Style.cornerRadius`, which is `decoration:rounding`, 18 here.
      //
      // The proportions line up as well as the number does: measured 48px tall
      // against a menu row's 54 (`baseRowHeight`, `Menu.qml:102`). So the chip,
      // the tiles and the card all round alike, and a change to the
      // compositor's rounding carries every one of them.
      radius: Style.cornerRadius
      color: Color.menu.selectedBackground
      borderSpec: card.selectedBorderSpec
      padding: Style.spacing.rowPaddingX

      width: ghost.contentLeftInset + ghost.contentRightInset + ghostRow.width
      height: ghost.contentTopInset + ghost.contentBottomInset + ghostRow.height
      // Centred on the pointer. dragX/dragY are card coordinates, which is what
      // the drag handler has to work in anyway -- the card is the only thing
      // either of them is measured against.
      x: card.x + root.dragX - ghost.width / 2
      y: card.y + root.dragY - ghost.height / 2

      Row {
        id: ghostRow
        x: ghost.contentLeftInset
        y: ghost.contentTopInset
        spacing: Style.spacing.sm

        // Same three-way mark as the tile -- drop-in svg recoloured, vendor
        // icon as-is, Nerd Font glyph otherwise -- and keyed the same way, off
        // the cached index rather than off Image.status. That is not a detail:
        // binding item structure to an Image's status is what aborted the shell
        // four times over, see iconFor() above.
        Item {
          id: ghostMark
          width: card.iconSize
          height: card.iconSize
          anchors.verticalCenter: parent.verticalCenter

          readonly property string url: ghost.win ? root.iconFor(ghost.win.cls) : ""

          Image {
            anchors.centerIn: parent
            width: card.iconDrawn
            height: width
            source: ghostMark.url
            sourceSize.width: Math.ceil(card.iconDrawn * Screen.devicePixelRatio)
            sourceSize.height: Math.ceil(card.iconDrawn * Screen.devicePixelRatio)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            visible: ghostMark.url.length > 0
          }

          Text {
            anchors.centerIn: parent
            visible: ghostMark.url.length === 0
            text: ghost.win ? root.glyphFor(ghost.win.cls) : ""
            textFormat: Text.PlainText
            font.family: Style.font.menuFamily
            font.pixelSize: card.iconSize
            color: Color.menu.selectedText
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          // The name only. The title line the tile carries is the one thing
          // that would make this chip wide enough to hide the group it is being
          // dropped on.
          text: ghost.win
            ? (root.nameFor(ghost.win.cls) || root.sanitizeTitle(ghost.win.title))
            : ""
          textFormat: Text.PlainText
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.heading
          font.weight: Font.Medium
          color: Color.menu.selectedText
        }
      }
    }
  }
}
