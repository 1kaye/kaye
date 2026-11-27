#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"
export PATH="$HOME/.local/bin:$PATH"

DEFAULT_THEME="${1:-catppuccin}"
echo "==> Applying initial Kaye OS theme: $DEFAULT_THEME"
kaye theme set "$DEFAULT_THEME"
