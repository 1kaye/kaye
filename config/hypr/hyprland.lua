-- Kaye OS — User Entrypoint (~/.config/hypr/hyprland.lua)
-- Loads Kaye OS defaults and active theme first, then your personal overrides.
-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/

local default_kaye_path = (os.getenv("HOME") or "") .. "/kaye"
local kaye_path = os.getenv("KAYE_PATH")
if not kaye_path or kaye_path == "" then
  kaye_path = default_kaye_path
end

-- Bootstrap Lua module paths and clear cached Kaye modules on reload.
dofile(kaye_path .. "/default/hypr/bootstrap.lua")(kaye_path)

-- 1. Kaye OS defaults & active theme (managed by repo)
require("default.hypr.kaye")

-- 2. Personal overrides (safe to edit freely)
kaye.require_optional("hypr.monitors")
kaye.require_optional("hypr.input")
kaye.require_optional("hypr.bindings")
kaye.require_optional("hypr.looknfeel")
kaye.require_optional("hypr.autostart")
