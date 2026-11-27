-- Kaye OS — Default Session Autostart

local paths = require("default.hypr.paths")

hl.on("hyprland.start", function()
  -- Propagate Wayland/Hyprland session environment to systemd user services & D-Bus,
  -- then ensure Quickshell is running (via systemd unit or direct fallback).
  hl.exec_cmd(
    "dbus-update-activation-environment --systemd --all && "
      .. "(systemctl --user start kaye-shell.service 2>/dev/null || "
      .. "pgrep -x quickshell >/dev/null 2>&1 || "
      .. "quickshell -p "
      .. kaye.shell_quote(paths.shell_path)
      .. ")"
  )

  hl.exec_cmd(kaye.launch("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1"))
  hl.exec_cmd(kaye.launch("udiskie --smart-tray"))
  hl.exec_cmd(kaye.launch("hyprsunset"))
  hl.exec_cmd("wl-paste --type text --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")
end)
