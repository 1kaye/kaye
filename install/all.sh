#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

clear || true
if [[ -f "$KAYE_DIR/branding/logo.txt" ]]; then
  printf '\033[1;34m'
  cat "$KAYE_DIR/branding/logo.txt"
  printf '\033[0m\n'
fi
echo "  Kaye OS Installer (Arch Linux + Hyprland + Quickshell + Rust)"
echo "  Repo: $KAYE_DIR"
echo

for step in \
  "$KAYE_DIR/install/01-packages.sh" \
  "$KAYE_DIR/install/02-services.sh" \
  "$KAYE_DIR/install/03-hardware.sh" \
  "$KAYE_DIR/install/04-plymouth.sh" \
  "$KAYE_DIR/install/05-core-and-dotfiles.sh" \
  "$KAYE_DIR/install/06-theme.sh"; do
  echo "============================================================"
  echo "==> Running $(basename "$step")"
  echo "============================================================"
  bash "$step"
  echo
done

echo "============================================================"
echo "  Kaye OS setup complete!"
echo "  Reboot to enjoy the KAYE Plymouth boot splash, Hyprland,"
echo "  and Quickshell desktop (Super+Space = Menu, Super+Enter = Foot)."
echo "============================================================"
