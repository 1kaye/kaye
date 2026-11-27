#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"
export PATH="$HOME/.local/bin:$PATH"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
kaye_enable_err_trap

TARGET_THEME="${1:-${KAYE_THEME:-catppuccin}}"

if [[ ! -f "$HOME/.config/kaye/themes/$TARGET_THEME/colors.toml" ]] && \
   [[ ! -f "$KAYE_DIR/themes/$TARGET_THEME/colors.toml" ]]; then
  echo "Warning: theme '$TARGET_THEME' not found; falling back to 'catppuccin'." >&2
  TARGET_THEME="catppuccin"
fi

if ! command -v kaye >/dev/null 2>&1; then
  echo "Error: 'kaye' CLI binary not found in PATH ($PATH). Run 06-core-and-dotfiles.sh first." >&2
  exit 1
fi

echo "==> Applying initial Kaye OS theme: $TARGET_THEME"
kaye theme set "$TARGET_THEME"

if [[ ! -f "$HOME/.local/state/kaye/current/theme.name" ]] || \
   [[ ! -f "$HOME/.local/state/kaye/current/theme/shell.toml" ]] || \
   [[ ! -f "$HOME/.local/state/kaye/current/theme/hyprland.lua" ]]; then
  echo "Error: theme state files were not generated cleanly in ~/.local/state/kaye/current/." >&2
  exit 1
fi
