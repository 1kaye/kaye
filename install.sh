#!/usr/bin/env bash
set -e

echo "[kaye installer] Building kaye release binary..."
cargo build --release

INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"
cp target/release/kaye "$INSTALL_DIR/kaye"
chmod +x "$INSTALL_DIR/kaye"

echo "[kaye installer] Installed 'kaye' to $INSTALL_DIR/kaye"

if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo ""
    echo "[note] $INSTALL_DIR is not in your PATH."
    echo "Add the following line to your ~/.bashrc, ~/.zshrc, or shell profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
else
    echo "[kaye installer] Setup complete. Run 'kaye --help' from any directory."
fi
