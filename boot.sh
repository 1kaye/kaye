#!/usr/bin/env bash
set -euo pipefail

# Kaye OS one-liner bootstrapper:
#   curl -fsSL https://raw.githubusercontent.com/1kaye/kaye/main/boot.sh | bash

KAYE_REPO="${KAYE_REPO:-https://github.com/1kaye/kaye.git}"
KAYE_REF="${KAYE_REF:-main}"
KAYE_INSTALL_DIR="${KAYE_INSTALL_DIR:-$HOME/kaye}"

die() {
  printf '\033[1;31m[kaye-boot] Error:\033[0m %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\033[1;34m[kaye-boot]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[kaye-boot] Warning:\033[0m %s\n' "$*" >&2
}

if (( EUID == 0 )); then
  die "Do not run boot.sh as root. Run as your regular user with sudo privileges."
fi

if [[ ! -f /etc/arch-release ]] || ! command -v pacman >/dev/null 2>&1; then
  die "Kaye OS requires Arch Linux (pacman and /etc/arch-release not detected)."
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "'sudo' is required. Install and configure sudo for your user first."
fi

# Ensure git and gum are available before cloning and launching the TUI installer.
missing_pkgs=()
command -v git >/dev/null 2>&1 || missing_pkgs+=(git)
command -v gum >/dev/null 2>&1 || missing_pkgs+=(gum)

if (( ${#missing_pkgs[@]} > 0 )); then
  info "Installing bootstrap dependencies: ${missing_pkgs[*]}"
  if [[ "${KAYE_NONINTERACTIVE:-0}" != "1" ]] && [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
    sudo -v </dev/tty
    sudo pacman -Sy --needed --noconfirm "${missing_pkgs[@]}" </dev/tty
  else
    sudo -v
    sudo pacman -Sy --needed --noconfirm "${missing_pkgs[@]}"
  fi
fi

# Clone or update the Kaye OS repository.
if [[ -d "$KAYE_INSTALL_DIR/.git" ]]; then
  if [[ -z "$(git -C "$KAYE_INSTALL_DIR" status --porcelain)" ]]; then
    info "Updating existing Kaye OS repository in $KAYE_INSTALL_DIR ($KAYE_REF)..."
    if git -C "$KAYE_INSTALL_DIR" fetch --depth 1 origin "$KAYE_REF" 2>/dev/null; then
      git -C "$KAYE_INSTALL_DIR" checkout -q -B "$KAYE_REF" FETCH_HEAD
    else
      git -C "$KAYE_INSTALL_DIR" fetch origin
      git -C "$KAYE_INSTALL_DIR" checkout -q "$KAYE_REF"
    fi
  else
    warn "Existing repository at $KAYE_INSTALL_DIR has local changes; using as-is."
  fi
elif [[ -e "$KAYE_INSTALL_DIR" ]] && [[ -n "$(ls -A "$KAYE_INSTALL_DIR" 2>/dev/null)" ]]; then
  die "$KAYE_INSTALL_DIR already exists and is not a Kaye OS git repository. Set KAYE_INSTALL_DIR to another path or move it aside."
else
  info "Cloning Kaye OS ($KAYE_REPO @ $KAYE_REF) into $KAYE_INSTALL_DIR..."
  mkdir -p "$(dirname "$KAYE_INSTALL_DIR")"
  if ! git clone --depth 1 --branch "$KAYE_REF" "$KAYE_REPO" "$KAYE_INSTALL_DIR" 2>/dev/null; then
    rm -rf "$KAYE_INSTALL_DIR"
    git clone "$KAYE_REPO" "$KAYE_INSTALL_DIR"
    git -C "$KAYE_INSTALL_DIR" checkout -q "$KAYE_REF"
  fi
fi

if [[ ! -f "$KAYE_INSTALL_DIR/install/all.sh" ]]; then
  die "Installer entrypoint not found at $KAYE_INSTALL_DIR/install/all.sh"
fi

info "Launching Kaye OS installer..."
if [[ "${KAYE_NONINTERACTIVE:-0}" != "1" ]] && [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
  exec bash "$KAYE_INSTALL_DIR/install/all.sh" "$@" </dev/tty
else
  exec bash "$KAYE_INSTALL_DIR/install/all.sh" "$@"
fi
