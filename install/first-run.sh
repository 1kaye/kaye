#!/usr/bin/env bash
set -euo pipefail

# Kaye OS one-shot first graphical login hook.
# Runs once inside the first Hyprland/UWSM session to apply DBus/session-dependent defaults.

STATE_DIR="$HOME/.local/state/kaye"
DONE_STAMP="$STATE_DIR/first-run.done"

if [[ -f "$DONE_STAMP" ]]; then
  exit 0
fi

mkdir -p "$STATE_DIR"

# 1. Apply GTK/GNOME dark mode preferences on live user D-Bus.
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' || true
  gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' || true
  gsettings set org.gnome.desktop.interface icon-theme 'Adwaita' || true
  gsettings set org.gnome.desktop.interface font-name 'JetBrainsMono Nerd Font 10' || true
fi

# 2. Apply default web browser if selected during install and present on the system.
if [[ -f "$STATE_DIR/default-browser" ]] && command -v xdg-settings >/dev/null 2>&1; then
  browser_desktop="$(tr -d '[:space:]' <"$STATE_DIR/default-browser")"
  if [[ -n "$browser_desktop" ]] && \
     { [[ -f "/usr/share/applications/$browser_desktop" ]] || [[ -f "$HOME/.local/share/applications/$browser_desktop" ]]; }; then
    xdg-settings set default-web-browser "$browser_desktop" || true
  fi
fi

# 3. Ensure PipeWire audio and Kaye Quickshell desktop user units are active.
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload || true
  for unit in \
    pipewire.service \
    pipewire-pulse.service \
    wireplumber.service \
    kaye-shell.service; do
    if systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
      systemctl --user enable "$unit" >/dev/null 2>&1 || true
      systemctl --user start "$unit" >/dev/null 2>&1 || true
    fi
  done
fi

# 4. Wait briefly for Quickshell's NotificationServer, then show a welcome toast.
send_welcome_toast() {
  local title="Welcome to Kaye OS"
  local body="Super+Space = Menu  |  Super+Enter = Terminal  |  Super+B = Browser"

  if command -v gdbus >/dev/null 2>&1; then
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if gdbus call --session \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner \
        org.freedesktop.Notifications 2>/dev/null | grep -q 'true'; then
        break
      fi
      sleep 0.5
    done
  fi

  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="Kaye OS" "$title" "$body" || true
  elif command -v gdbus >/dev/null 2>&1; then
    gdbus call --session \
      --dest org.freedesktop.Notifications \
      --object-path /org/freedesktop/Notifications \
      --method org.freedesktop.Notifications.Notify \
      "Kaye OS" 0 "" "$title" "$body" "[]" "{}" 6000 >/dev/null 2>&1 || true
  fi
}

send_welcome_toast

printf '%s\n' "$(date -Iseconds)" >"$DONE_STAMP"
