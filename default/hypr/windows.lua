-- Kaye OS — Default Window Rules

hl.window_rule({
  name = "kaye-suppress-maximize",
  match = { class = ".*" },
  suppress_event = "maximize",
})

hl.window_rule({
  name = "kaye-float-system-dialogs",
  match = {
    class = "^(polkit-gnome-authentication-agent-1|org\\.pulseaudio\\.pavucontrol|nm-connection-editor)$",
  },
  float = true,
})

hl.window_rule({
  name = "kaye-picture-in-picture",
  match = { title = "^(Picture-in-Picture)$" },
  float = true,
  pin = true,
})

-- Fix dragging issues with XWayland popups/ghost windows
hl.window_rule({
  name = "kaye-fix-xwayland-drags",
  match = {
    class = "^$",
    title = "^$",
    xwayland = true,
    float = true,
    fullscreen = false,
    pin = false,
  },
  no_focus = true,
})
