-- Window Switcher (cllpse.window-switcher) -- appearance. OPTIONAL.
--
-- Append to ~/.config/hypr/looknfeel.lua. Without it the switcher still works;
-- it just opens and closes without a fade.
--
-- A later layer rule wins over an earlier one, so this needs no edit to any
-- Omarchy file.

-- Blur is deliberately NOT applied, though Omarchy blurs its own panels.
--
-- The switcher is a full-screen layer, and blurring one costs the compositor a
-- full-screen blur on every frame that changes -- every frame of the open fade
-- and of the highlight fading between tiles. Measured with Qt's render-loop
-- timing while the highlight faded on a 120Hz output: frames every 16-17ms
-- (60 fps) with this rule, every 8ms (120 fps) without it, Qt itself rendering
-- in ~0ms either way. And it buys nothing while the card is opaque, as it is
-- under Omarchy's own menu colours: an opaque pixel has nothing to blur
-- through, and the transparent rest is under ignore_alpha.
--
-- If your theme makes the menu translucent and you want the card frosted,
-- uncomment this, knowing the frame rate is the price. The scrim (off by
-- default, showScrim in Hud.qml) sits under ignore_alpha, so it stays sharp.
--
-- hl.layer_rule({
--   match = { namespace = "^omarchy-window-switcher-hud$" },
--   blur = true,
--   blur_popups = true,
--   ignore_alpha = 0.6,
-- })

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
