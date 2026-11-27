-- Personal monitor layout & scaling
-- Run `hyprctl monitors all` to list output names and available modes.
-- See https://wiki.hypr.land/Configuring/Monitors/

hl.monitor({
  output = "",
  mode = "preferred",
  position = "auto",
  scale = "auto",
})

-- Example explicit monitor setup:
-- hl.monitor({ output = "DP-1", mode = "preferred", position = "auto", scale = 1 })
-- hl.monitor({ output = "DP-2", mode = "1920x1080@60", position = "auto-right", scale = 1 })
