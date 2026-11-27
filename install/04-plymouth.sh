#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
THEME_SRC="$KAYE_DIR/plymouth/kaye"
THEME_DST="/usr/share/plymouth/themes/kaye"

if ! command -v plymouth-set-default-theme >/dev/null 2>&1; then
  echo "==> Plymouth not installed; skipping boot splash setup."
  exit 0
fi

echo "==> Installing Kaye Plymouth boot splash theme to $THEME_DST..."
sudo install -d -m 755 "$THEME_DST"
sudo cp -a "$THEME_SRC/." "$THEME_DST/"

# Add plymouth hook to /etc/mkinitcpio.conf if not present (backup first).
if [[ -f /etc/mkinitcpio.conf ]] && ! grep -Eq '^HOOKS=.*\bplymouth\b' /etc/mkinitcpio.conf; then
  echo "==> Adding plymouth hook to /etc/mkinitcpio.conf..."
  sudo cp -p /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak.$(date +%s)"
  if grep -Eq '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf; then
    sudo sed -i 's/\bsystemd\b/systemd plymouth/' /etc/mkinitcpio.conf
  elif grep -Eq '^HOOKS=.*\budev\b' /etc/mkinitcpio.conf; then
    sudo sed -i 's/\budev\b/udev plymouth/' /etc/mkinitcpio.conf
  fi
fi

echo "==> Activating Kaye Plymouth theme and rebuilding initramfs..."
sudo plymouth-set-default-theme -R kaye

echo "==> Reminder: make sure your kernel cmdline includes 'quiet splash' for the Kaye boot splash."
