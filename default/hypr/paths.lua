-- Shared path constants for Kaye OS Hyprland Lua modules.

if _G._kaye_paths then
  return _G._kaye_paths
end

local home = os.getenv("HOME") or ""

local function env_or(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

local kaye_path = env_or("KAYE_PATH", home .. "/kaye")

return {
  home = home,
  config_home = env_or("XDG_CONFIG_HOME", home .. "/.config"),
  state_home = env_or("XDG_STATE_HOME", home .. "/.local/state"),
  kaye_path = kaye_path,
  shell_path = kaye_path .. "/shell",
}
