-- Kaye OS — Default Look & Feel
-- Active theme colors override border & shadow colors via ~/.local/state/kaye/current/theme/hyprland.lua.

hl.config({
  general = {
    gaps_in = 4,
    gaps_out = 8,
    border_size = 2,
    layout = "dwindle",
    resize_on_border = true,
    col = {
      active_border = {
        colors = { "rgb(89b4fa)", "rgb(cba6f7)" },
        angle = 45,
      },
      inactive_border = "rgba(585b70aa)",
    },
  },

  decoration = {
    rounding = 8,
    active_opacity = 1.0,
    inactive_opacity = 0.98,

    blur = {
      enabled = true,
      size = 5,
      passes = 2,
      new_optimizations = true,
    },

    shadow = {
      enabled = true,
      range = 14,
      render_power = 3,
      color = "rgba(161622cc)",
    },
  },

  animations = {
    enabled = true,
  },

  dwindle = {
    preserve_split = true,
  },

  misc = {
    force_default_wallpaper = 0,
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    allow_session_lock_restore = true,
  },

  debug = {
    vfr = true,
  },

  layers = {
    allow_new_top_layers_over_existing_fullscreen = true,
  },
})

hl.curve("kayeOut", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })

hl.animation({ leaf = "windows", enabled = true, speed = 3, bezier = "kayeOut", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 2, bezier = "kayeOut", style = "popin 92%" })
hl.animation({ leaf = "fade", enabled = true, speed = 2, bezier = "kayeOut" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "kayeOut", style = "slide" })
