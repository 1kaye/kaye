-- Kaye OS — Default Wayland/Hyprland Environment

local paths = require("default.hypr.paths")

hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("TERMINAL", "foot")

-- Ensure KAYE_PATH and ~/.local/bin (for `kaye`) are always available to keybinds
-- and spawned apps even if Hyprland was started without UWSM or a login shell.
hl.env("KAYE_PATH", paths.kaye_path)

local local_bin = paths.home .. "/.local/bin"
local kept = {}
for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
  if entry ~= local_bin then
    table.insert(kept, entry)
  end
end
table.insert(kept, 1, local_bin)
hl.env("PATH", table.concat(kept, ":"))

hl.config({
  xwayland = {
    force_zero_scaling = true,
  },

  ecosystem = {
    no_update_news = true,
    no_donation_nag = true,
  },
})
