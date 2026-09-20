-- Window Switcher (cllpse.window-switcher) -- keybinds.
--
-- REQUIRED. The plugin has no input of its own: it registers global shortcuts
-- and waits. Without this file it loads, sits there, and nothing can open it.
--
-- Append the contents of this file to ~/.config/hypr/bindings.lua.

-- Keys reach the plugin over Hyprland's global-shortcuts protocol rather than
-- by summoning it over IPC, because the IPC path costs a process spawn per
-- keypress: `omarchy-shell shell summon` is bash -> timeout -> `qs ipc`, and
-- `qs ipc` starts a whole Quickshell binary to deliver one message. Measured at
-- 31-35ms per press with spikes to 130-166ms, paid on EVERY TAB. hl.dsp.global
-- hands the event straight to the running shell: no fork, no exec, no Qt
-- startup. The appid carries no dots or colons -- Hyprland parses a global
-- shortcut binding as "<appid>:<name>".
local function ws_exec(action)
  hl.dispatch(hl.dsp.global("cllpse-switcher:" .. action))
end

local ws_watching = false

-- While the strip is up, SUPER + left-click belongs to the switcher.
--
-- Hyprland resolves mouse BINDS before handing a button to a layer surface, so
-- with "Move window" bound to SUPER + mouse:272 the strip's input region never
-- sees a press -- the click lands as a window drag instead. A bind can only
-- report a press, never motion or release, so it cannot stand in for one
-- either. The bind is therefore switched off for exactly as long as the strip
-- is on screen, and the plugin receives ordinary press / move / release events:
-- click a tile to focus it, drag one onto another workspace to move it there.
--
-- hl.bind returns the keybind and set_enabled toggles it in place, so nothing
-- is unbound and rebound per gesture. Resize (mouse:273) is left alone.
hl.unbind("SUPER + mouse:272")
local ws_drag_bind = hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), {
  mouse = true,
  description = "Move window",
})

local function ws_hud_takes_clicks(taking)
  ws_drag_bind:set_enabled(not taking)
end

-- Rather than trust a key-release keybind to fire, a lightweight poll asks the
-- compositor "is SUPER still physically down?" every 30ms while the strip is
-- up. hl.is_key_down is a cheap in-process check, and the strip stays on screen
-- for exactly as long as that answer holds.
local function ws_watch()
  if not ws_watching then return end
  if hl.is_key_down("Super_L") or hl.is_key_down("Super_R") then
    hl.timer(ws_watch, { timeout = 30, type = "oneshot" })
  else
    ws_watching = false
    ws_hud_takes_clicks(false)
    ws_exec("commit") -- SUPER let go -> focus the highlighted window
  end
end

local function ws_step(action)
  return function()
    ws_exec(action)
    if not ws_watching then
      ws_watching = true
      ws_hud_takes_clicks(true)
      hl.timer(ws_watch, { timeout = 30, type = "oneshot" })
    end
  end
end

-- Omarchy binds SUPER + TAB to "next workspace" by default; unbind first or
-- both fire.
hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
o.bind("SUPER + TAB", "Window switcher: next", ws_step("next"))
o.bind("SUPER + SHIFT + TAB", "Window switcher: previous", ws_step("prev"))
