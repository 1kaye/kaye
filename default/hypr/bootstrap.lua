-- Kaye OS — Hyprland Lua Bootstrap
-- Configures Lua module search paths and clears cached Kaye modules on reload.

local function env_or(name, fallback)
  local value = os.getenv(name)
  if value == nil or value == "" then
    return fallback
  end
  return value
end

return function(kaye_path)
  local home = os.getenv("HOME") or ""
  local resolved_kaye_path = kaye_path
  if not resolved_kaye_path or resolved_kaye_path == "" then
    resolved_kaye_path = env_or("KAYE_PATH", home .. "/kaye")
  end

  local config_home = env_or("XDG_CONFIG_HOME", home .. "/.config")
  local state_home = env_or("XDG_STATE_HOME", home .. "/.local/state")

  _G._kaye_paths = {
    home = home,
    config_home = config_home,
    state_home = state_home,
    kaye_path = resolved_kaye_path,
    shell_path = resolved_kaye_path .. "/shell",
  }

  local reload_prefixes = {
    "default.hypr",
    "hypr",
    "kaye.current.theme",
  }

  local function should_reload(module_name)
    for _, prefix in ipairs(reload_prefixes) do
      if module_name == prefix or module_name:sub(1, #prefix + 1) == prefix .. "." then
        return true
      end
    end
    return false
  end

  local to_reload = {}
  for module_name in pairs(package.loaded) do
    if should_reload(module_name) then
      table.insert(to_reload, module_name)
    end
  end
  for _, module_name in ipairs(to_reload) do
    package.loaded[module_name] = nil
  end

  -- Preserve original package.path so repeated reloads do not grow it unboundedly.
  _G._kaye_base_package_path = _G._kaye_base_package_path or package.path

  -- Search order: generated runtime state -> user overrides -> Kaye OS defaults.
  package.path = state_home
    .. "/?.lua;"
    .. config_home
    .. "/?.lua;"
    .. resolved_kaye_path
    .. "/?.lua;"
    .. _G._kaye_base_package_path
end
