#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Enable color and parallel downloads in pacman.conf
if grep -q '^#Color' /etc/pacman.conf; then
  sudo sed -i 's/^#Color/Color/' /etc/pacman.conf
fi
if grep -q '^#ParallelDownloads' /etc/pacman.conf; then
  sudo sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
fi

mapfile -t BASE_PKGS < <(grep -Ev '^\s*(#|$)' "$KAYE_DIR/install/packages.base")
echo "==> Installing ${#BASE_PKGS[@]} base packages..."
sudo pacman -Syu --needed --noconfirm "${BASE_PKGS[@]}"

# Install yay if missing
if ! command -v yay >/dev/null 2>&1; then
  echo "==> Installing yay-bin from AUR..."
  tmp_yay="$(mktemp -d)"
  trap 'rm -rf "$tmp_yay"' EXIT
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp_yay/yay-bin"
  (cd "$tmp_yay/yay-bin" && makepkg -si --noconfirm)
fi

mapfile -t AUR_PKGS < <(grep -Ev '^\s*(#|$)' "$KAYE_DIR/install/packages.aur")
if (( ${#AUR_PKGS[@]} > 0 )); then
  echo "==> Installing ${#AUR_PKGS[@]} AUR packages..."
  yay -S --needed --noconfirm "${AUR_PKGS[@]}"
fi

# Ensure Rust stable toolchain is ready for building `core/`
if command -v rustup >/dev/null 2>&1; then
  echo "==> Ensuring Rust stable toolchain..."
  rustup default stable
fi
