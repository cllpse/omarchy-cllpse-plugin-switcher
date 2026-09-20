-- Window Switcher (cllpse.window-switcher) -- appearance. OPTIONAL.
--
-- Append to ~/.config/hypr/looknfeel.lua. Without it the switcher still works;
-- it just will not blur or fade the way Omarchy's own panels do.
--
-- Omarchy blurs its own panels through a layer rule matching a fixed list of
-- namespaces, which a third-party namespace cannot join, and opts them out of
-- the compositor's map fade through another. These two rules put the switcher
-- in the same company. A later layer rule wins over an earlier one, so this
-- needs no edit to any Omarchy file.
hl.layer_rule({
  match = { namespace = "^omarchy-window-switcher-hud$" },
  blur = true,
  blur_popups = true,
  -- The card's scrim sits below this, so it renders unblurred and the windows
  -- being switched between stay readable.
  ignore_alpha = 0.6,
})

hl.layer_rule({
  match = { namespace = "^omarchy-window-switcher-hud$" },
  no_anim = false,
  animation = "fade",
})
