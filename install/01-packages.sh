#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
kaye_enable_err_trap

if (( EUID == 0 )); then
  echo "Error: 01-packages.sh must run as a regular user (makepkg cannot run as root)." >&2
  exit 1
fi

# Tune /etc/pacman.conf idempotently for color, candy progress bar, verbose lists, and parallel downloads.
if [[ -f /etc/pacman.conf ]]; then
  if grep -Eq '^\s*#Color\b' /etc/pacman.conf; then
    sudo sed -i 's/^\s*#Color\b/Color/' /etc/pacman.conf
  elif ! grep -Eq '^\s*Color\b' /etc/pacman.conf; then
    sudo sed -i '/^\[options\]/a Color' /etc/pacman.conf
  fi

  if ! grep -Eq '^\s*ILoveCandy\b' /etc/pacman.conf; then
    sudo sed -i '/^Color\b/a ILoveCandy' /etc/pacman.conf
  fi

  if grep -Eq '^\s*#ParallelDownloads\b' /etc/pacman.conf; then
    sudo sed -i 's/^\s*#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
  elif ! grep -Eq '^\s*ParallelDownloads\b' /etc/pacman.conf; then
    sudo sed -i '/^\[options\]/a ParallelDownloads = 5' /etc/pacman.conf
  fi

  if grep -Eq '^\s*#VerbosePkgLists\b' /etc/pacman.conf; then
    sudo sed -i 's/^\s*#VerbosePkgLists\b/VerbosePkgLists/' /etc/pacman.conf
  fi
fi

mapfile -t BASE_PKGS < <(grep -Ev '^\s*(#|$)' "$KAYE_DIR/install/packages.base")

KAYE_BROWSER="${KAYE_BROWSER:-firefox}"
case "$KAYE_BROWSER" in
  firefox)
    BASE_PKGS+=(firefox)
    ;;
  chromium)
    BASE_PKGS+=(chromium)
    ;;
  skip)
    echo "==> Skipping default browser package per KAYE_BROWSER=skip"
    ;;
  *)
    echo "Warning: unrecognized KAYE_BROWSER='$KAYE_BROWSER'; skipping browser package." >&2
    ;;
esac

echo "==> Installing ${#BASE_PKGS[@]} official Arch packages..."
sudo pacman -Syu --needed --noconfirm "${BASE_PKGS[@]}"

# Build yay-bin from AUR as non-root user if yay is missing.
if ! command -v yay >/dev/null 2>&1; then
  echo "==> Building yay-bin from AUR..."
  tmp_yay="$(mktemp -d)"
  (
    trap 'rm -rf "$tmp_yay"' EXIT
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$tmp_yay/yay-bin"
    cd "$tmp_yay/yay-bin"
    makepkg -si --noconfirm
  )
fi

if [[ -f "$KAYE_DIR/install/packages.aur" ]]; then
  mapfile -t AUR_PKGS < <(grep -Ev '^\s*(#|$)' "$KAYE_DIR/install/packages.aur")
  if (( ${#AUR_PKGS[@]} > 0 )); then
    echo "==> Installing ${#AUR_PKGS[@]} AUR packages..."
    yay -S --needed --noconfirm --answerdiff None --answerclean None --removemake "${AUR_PKGS[@]}"
  fi
fi

# Ensure Rust stable toolchain is configured for building `core/`.
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
if command -v rustup >/dev/null 2>&1; then
  echo "==> Ensuring Rust stable toolchain..."
  rustup default stable
fi
