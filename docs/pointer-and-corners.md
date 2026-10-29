# The pointer and the screen corners

Part of the [Window Switcher](../README.md).

## A pointer resting on the strip

A quick `SUPER+TAB` goes back to where you came from, wherever the pointer
happens to be. Hover only takes the highlight once the pointer has travelled
more than twice Qt's drag distance (16px; Qt's own menus use the 8px) and no
sooner than 250ms after a key press (half what GNOME's switcher waits). Motion
during those 250ms does not count toward the 16px, so a mouse knocked during the tap
cannot take over later on its own. Each `TAB` hands the highlight back to the
keyboard until the pointer moves again. A click is never held back, and a strip
opened from a corner follows the pointer from the start.

## The screen corners

A one-pixel layer surface sits in each corner of every screen; crossing into one
opens the strip. Nothing polls — the compositor sends a single pointer-enter
event when the cursor crosses in, so the trigger costs nothing while you are not
touching it. A high mouse polling rate does not change that: a rate is reports
*while the mouse moves*, and a pointer resting in a corner generates no events
at all (measured at 8000Hz against the full-height edge this replaced: ~0 events
over 32s parked; ~500/s while sliding along it, under 4µs of client CPU each).

Hyprland clamps the cursor to the output, and in a corner it clamps in both axes
at once, so a fast throw cannot overshoot a one-pixel target the way it would
anywhere else on screen — measured on a 3072×1280 logical output, a warp to
(99999, 99999) lands at `3071, 1279`, and on a 2880×1620 one at `2879, 1619`.
That clamp is what makes one pixel enough.

Each set of four is bound to its output, the way Omarchy's own bar is. They
used to name no output, and a modeset that briefly drops the link (a scale
change on a TV behind a USB-C→HDMI adapter does) recreated them on Hyprland's
temporary `FALLBACK` output, where they died with it — the corners stayed dead
until the shell restarted. Bound, they are rebuilt when the output comes back.

It was the whole left edge first. A corner is the same gesture with the
accidents taken out: an edge is crossed by anything that overshoots a window's
left side, a scrollbar or a tab strip, and each of those opened the switcher
over work aimed somewhere else.

Two things it costs, both deliberate:

- The four corner pixels no longer pass clicks through to what is behind them.
  With Omarchy's default gaps the nearest window corner is 12px in (`gaps_out`
  10 plus a 2px border; 26 under omarchy-cllpse-macos's 24px gaps), so what is
  behind them is the wallpaper.
- It stands down while a window on the focused workspace is fullscreen, so a
  video or a game cannot be interrupted by a pointer thrown into a corner.
