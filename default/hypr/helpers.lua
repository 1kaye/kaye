-- Shared helpers for Kaye OS Hyprland Lua configuration.

local paths = require("default.hypr.paths")

kaye = kaye or {}

function kaye.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function kaye.file_exists(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

function kaye.cmd_present(command)
  if command:find("/", 1, true) then
    return kaye.file_exists(command)
  end

  local path = os.getenv("PATH") or "/usr/local/bin:/usr/bin"
  local local_bin = paths.home .. "/.local/bin"
  for directory in (local_bin .. ":" .. path .. ":"):gmatch("([^:]*):") do
    if directory ~= "" and kaye.file_exists(directory .. "/" .. command) then
      return true
    end
  end

  return false
end

-- Require a Lua module only if it exists on package.path.
-- Syntax or runtime errors inside existing files still surface normally.
function kaye.require_optional(module_name)
  if package.searchpath(module_name, package.path) then
    return require(module_name)
  end
  return nil
end

function kaye.uwsm_active()
  local finalize = os.getenv("UWSM_FINALIZE_VARNAMES")
  if finalize and finalize ~= "" then
    return true
  end

  local wait_vars = os.getenv("UWSM_WAIT_VARNAMES")
  if wait_vars and wait_vars ~= "" then
    return true
  end

  local runtime = os.getenv("XDG_RUNTIME_DIR")
  if runtime and runtime ~= "" then
    return kaye.file_exists(runtime .. "/uwsm/env_session.conf")
  end

  return false
end

-- Launch an application via UWSM when running inside a UWSM-managed session,
-- or directly if Hyprland was started standalone without UWSM.
function kaye.launch(command)
  if kaye.uwsm_active() then
    if kaye.cmd_present("uwsm-app") then
      return "uwsm-app -- " .. command
    elseif kaye.cmd_present("uwsm") then
      return "uwsm app -- " .. command
    end
  end
  return command
end

-- Prefix for Quickshell IPC commands pointing directly at Kaye OS's shell directory.
function kaye.ipc_prefix()
  return "qs -p " .. kaye.shell_quote(paths.shell_path) .. " ipc call"
end

function kaye.ipc(...)
  local parts = { kaye.ipc_prefix() }
  for i = 1, select("#", ...) do
    table.insert(parts, tostring(select(i, ...)))
  end
  return table.concat(parts, " ")
end

-- Declare a keybinding with an explicit description (visible in `Super + K` / `kaye menu keybindings`).
-- String dispatchers are automatically wrapped in `hl.dsp.exec_cmd(...)`.
function kaye.bind(keys, description, dispatcher, options)
  local opts = {}
  for k, v in pairs(options or {}) do
    opts[k] = v
  end

  if description and description ~= "" then
    opts.description = description
  end

  if type(dispatcher) == "string" then
    dispatcher = hl.dsp.exec_cmd(dispatcher)
  end

  return hl.bind(keys, dispatcher, opts)
end

-- Replace an existing keybinding cleanly.
function kaye.rebind(keys, description, dispatcher, options)
  hl.unbind(keys)
  return kaye.bind(keys, description, dispatcher, options)
end

function kaye.exec_on_start(command)
  hl.on("hyprland.start", function()
    hl.exec_cmd(command)
  end)
end

function kaye.launch_on_start(command)
  kaye.exec_on_start(kaye.launch(command))
end

return kaye
