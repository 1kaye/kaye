-- Kaye OS — Core Hyprland Defaults
-- Loaded by ~/.config/hypr/hyprland.lua before personal overrides.

require("default.hypr.helpers")
require("default.hypr.env")
require("default.hypr.input")
require("default.hypr.looknfeel")
require("default.hypr.bindings")
require("default.hypr.windows")
require("default.hypr.autostart")

-- Active theme colors (rendered by `kaye theme set` into ~/.local/state/kaye/current/theme/hyprland.lua)
kaye.require_optional("kaye.current.theme.hyprland")
