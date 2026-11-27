-- Kaye OS — Default Keybindings
-- Uses `kaye.bind` so `Super + K` (`kaye menu keybindings`) displays descriptions cleanly.

-- Core Launcher & Shell Menus (Quickshell IPC)
kaye.bind("SUPER + SPACE", "Kaye Menu", kaye.ipc("menu", "toggle", "root"))
kaye.bind("SUPER + ALT + SPACE", "App Launcher", kaye.ipc("menu", "toggle", "apps"))
kaye.bind("SUPER + K", "Show Keybindings", kaye.ipc("menu", "keybindings"))
kaye.bind("SUPER + SHIFT + B", "Toggle Top Bar", "kaye bar toggle")

-- Applications
kaye.bind("SUPER + RETURN", "Open Terminal", kaye.launch("foot"))
kaye.bind("SUPER + E", "Open File Manager", kaye.launch("thunar"))
kaye.bind("SUPER + B", "Open Browser", kaye.launch("xdg-open https://"))

-- Window Management
kaye.bind("SUPER + Q", "Close Active Window", hl.dsp.window.close())
kaye.bind("SUPER + F", "Fullscreen Window", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
kaye.bind("SUPER + V", "Toggle Floating", hl.dsp.window.float({ action = "toggle" }))
kaye.bind("SUPER + J", "Toggle Split Direction", hl.dsp.layout("togglesplit"))

-- Focus Movement
kaye.bind("SUPER + LEFT", "Focus Left", hl.dsp.focus({ direction = "l" }))
kaye.bind("SUPER + RIGHT", "Focus Right", hl.dsp.focus({ direction = "r" }))
kaye.bind("SUPER + UP", "Focus Up", hl.dsp.focus({ direction = "u" }))
kaye.bind("SUPER + DOWN", "Focus Down", hl.dsp.focus({ direction = "d" }))

-- Workspaces 1..9
for i = 1, 9 do
  kaye.bind("SUPER + " .. i, "Workspace " .. i, hl.dsp.focus({ workspace = i }))
  kaye.bind("SUPER + SHIFT + " .. i, "Move to Workspace " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Mouse Window Controls
kaye.bind("SUPER + mouse:272", "Move Window", hl.dsp.window.drag(), { mouse = true })
kaye.bind("SUPER + mouse:273", "Resize Window", hl.dsp.window.resize(), { mouse = true })

-- Utilities & System
kaye.bind("SUPER + L", "Lock Screen", kaye.ipc("lock", "open"))
kaye.bind("SUPER + CTRL + I", "Toggle Stay Awake", "kaye toggle stay-awake")
kaye.bind("SUPER + CTRL + N", "Toggle Night Light", "kaye toggle nightlight")
kaye.bind("SUPER + SHIFT + S", "Screenshot Area to Clipboard", [[grim -g "$(slurp)" - | wl-copy]])
kaye.bind("PRINT", "Screenshot Fullscreen to Clipboard", "grim - | wl-copy")

-- Media & Brightness (triggers Quickshell OSD)
kaye.bind(
  "XF86AudioRaiseVolume",
  "Volume Up",
  [[pamixer -i 5 && ]] .. kaye.ipc_prefix() .. [[ osd volume "$(pamixer --get-volume)"]],
  { locked = true, repeating = true }
)
kaye.bind(
  "XF86AudioLowerVolume",
  "Volume Down",
  [[pamixer -d 5 && ]] .. kaye.ipc_prefix() .. [[ osd volume "$(pamixer --get-volume)"]],
  { locked = true, repeating = true }
)
kaye.bind(
  "XF86AudioMute",
  "Toggle Mute",
  [[pamixer -t && ]] .. kaye.ipc_prefix() .. [[ osd mute "$(pamixer --get-mute)"]],
  { locked = true }
)
kaye.bind(
  "XF86MonBrightnessUp",
  "Brightness Up",
  [[brightnessctl set +5% && ]] .. kaye.ipc_prefix() .. [[ osd brightness "$(brightnessctl -m | cut -d, -f4 | tr -d '%')"]],
  { locked = true, repeating = true }
)
kaye.bind(
  "XF86MonBrightnessDown",
  "Brightness Down",
  [[brightnessctl set 5%- && ]] .. kaye.ipc_prefix() .. [[ osd brightness "$(brightnessctl -m | cut -d, -f4 | tr -d '%')"]],
  { locked = true, repeating = true }
)
