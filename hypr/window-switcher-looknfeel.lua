-- Window Switcher (cllpse.window-switcher) -- appearance. OPTIONAL.
--
-- Append to ~/.config/hypr/looknfeel.lua. Without it the switcher still works;
-- it just will not blur the way Omarchy's own panels do.
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
  -- being switched between stay readable. (The scrim is off by default --
  -- showScrim in Hud.qml -- in which case nothing behind the card is drawn at
  -- all.)
  ignore_alpha = 0.6,
})

-- Fade the strip in as it maps, over layersIn, and out over layersOut.
-- Hyprland would do that anyway -- Omarchy's no_anim list does not name this
-- namespace -- so this states it, and makes it win over any broader no_anim
-- rule loaded earlier.
--
-- A card and its scrim are one layer surface, so this fades both. The scrim is
-- off by default (showScrim in Hud.qml); turned on, it also runs its own QML
-- fade on top of this one. To have the card land instantly with only the scrim
-- fading, make this no_anim = true, animation = "none" instead.
hl.layer_rule({
  match = { namespace = "^omarchy-window-switcher-hud$" },
  no_anim = false,
  animation = "fade",
})
