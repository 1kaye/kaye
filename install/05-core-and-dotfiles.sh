#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Building and installing Rust 'kaye' CLI binary..."
mkdir -p "$HOME/.local/bin"
cargo install --path "$KAYE_DIR/core" --root "$HOME/.local" --force

# Copy starter user configs ONLY if missing (never clobber existing user customizations).
copy_if_missing() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ ! -e "$dst" ]]; then
    cp -a "$src" "$dst"
    echo "    created $dst"
  else
    echo "    kept existing $dst"
  fi
}

echo "==> Installing starter configs into ~/.config..."
for rel in \
  hypr/hyprland.conf \
  hypr/monitors.conf \
  hypr/input.conf \
  hypr/bindings.conf \
  hypr/looknfeel.conf \
  hypr/autostart.conf \
  kaye/shell.json \
  kaye/menu.jsonc \
  uwsm/env.d/10-kaye.conf \
  foot/foot.ini \
  fastfetch/config.jsonc \
  systemd/user/kaye-shell.service; do
  copy_if_missing "$KAYE_DIR/config/$rel" "$HOME/.config/$rel"
done

# Point KAYE_PATH in user configs to actual clone directory
sed -i "s|^\$KAYE_PATH = .*|\$KAYE_PATH = $KAYE_DIR|" "$HOME/.config/hypr/hyprland.conf" || true
sed -i "s|^export KAYE_PATH=.*|export KAYE_PATH=\"$KAYE_DIR\"|" "$HOME/.config/uwsm/env.d/10-kaye.conf" || true
sed -i "s|^Environment=KAYE_PATH=.*|Environment=KAYE_PATH=$KAYE_DIR|" "$HOME/.config/systemd/user/kaye-shell.service" || true
sed -i "s|^ExecStart=/usr/bin/quickshell -p .*|ExecStart=/usr/bin/quickshell -p $KAYE_DIR/shell|" "$HOME/.config/systemd/user/kaye-shell.service" || true

# Copy branding files for fastfetch & shell
mkdir -p "$HOME/.config/kaye/branding" "$HOME/.local/state/kaye/toggles"
cp -a "$KAYE_DIR/branding/." "$HOME/.config/kaye/branding/"

# Ensure ~/.bashrc exports KAYE_PATH and ~/.local/bin
touch "$HOME/.bashrc"
if ! grep -q 'KAYE_PATH' "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<EOF

# Kaye OS
export KAYE_PATH="$KAYE_DIR"
export PATH="\$HOME/.local/bin:\$PATH"
EOF
fi

# Enable kaye-shell systemd user service (if user bus is available)
if systemctl --user daemon-reload 2>/dev/null; then
  systemctl --user enable kaye-shell.service || true
fi
