#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
kaye_enable_err_trap

copy_if_missing() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ ! -e "$dst" ]]; then
    cp -a "$src" "$dst"
    echo "    created $dst"
    return 0
  else
    echo "    kept existing $dst"
    return 1
  fi
}

echo "==> Installing desktop defaults into ~/.config..."
for rel in \
  gtk-3.0/settings.ini \
  gtk-4.0/settings.ini \
  qt6ct/qt6ct.conf \
  xdg-desktop-portal/hyprland-portals.conf \
  autostart/kaye-first-run.desktop; do
  copy_if_missing "$KAYE_DIR/config/$rel" "$HOME/.config/$rel" || true
done

MIMEAPPS_CREATED=0
if copy_if_missing "$KAYE_DIR/config/mimeapps.list" "$HOME/.config/mimeapps.list"; then
  MIMEAPPS_CREATED=1
fi

# Record and apply chosen default web browser preference.
KAYE_BROWSER="${KAYE_BROWSER:-firefox}"
STATE_DIR="$HOME/.local/state/kaye"
mkdir -p "$STATE_DIR"

BROWSER_DESKTOP=""
case "$KAYE_BROWSER" in
  firefox) BROWSER_DESKTOP="firefox.desktop" ;;
  chromium) BROWSER_DESKTOP="chromium.desktop" ;;
  skip) BROWSER_DESKTOP="" ;;
esac

if [[ -n "$BROWSER_DESKTOP" ]]; then
  printf '%s\n' "$BROWSER_DESKTOP" >"$STATE_DIR/default-browser"
  if (( MIMEAPPS_CREATED == 1 )) && [[ "$BROWSER_DESKTOP" != "firefox.desktop" ]]; then
    sed -i "s|=firefox\.desktop$|=${BROWSER_DESKTOP}|g" "$HOME/.config/mimeapps.list"
  fi
else
  rm -f "$STATE_DIR/default-browser"
  if (( MIMEAPPS_CREATED == 1 )) && ! command -v firefox >/dev/null 2>&1; then
    sed -i '/=firefox\.desktop$/d' "$HOME/.config/mimeapps.list"
  fi
fi

# Install one-shot graphical first-run hook (triggered by ~/.config/autostart/kaye-first-run.desktop).
echo "==> Installing ~/.local/bin/kaye-first-run..."
mkdir -p "$HOME/.local/bin"
install -m 755 "$KAYE_DIR/install/first-run.sh" "$HOME/.local/bin/kaye-first-run"
