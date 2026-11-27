#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
# shellcheck source=install/lib/ui.sh
source "$KAYE_DIR/install/lib/ui.sh"
kaye_enable_err_trap
kaye_is_chroot || true

if (( EUID == 0 )); then
  echo "Error: 05-login.sh must run as your regular target user, not root." >&2
  exit 1
fi

TARGET_USER="$(id -un)"
KAYE_AUTOLOGIN="${KAYE_AUTOLOGIN:-auto}"

# Verified against Arch Linux /usr/share/wayland-sessions/hyprland-uwsm.desktop
SESSION_CMD="uwsm start -e -D Hyprland hyprland.desktop"

USE_AUTOLOGIN=0
case "$KAYE_AUTOLOGIN" in
  1)
    USE_AUTOLOGIN=1
    ;;
  0)
    USE_AUTOLOGIN=0
    ;;
  auto)
    if kaye_is_luks_root; then
      USE_AUTOLOGIN=1
    else
      USE_AUTOLOGIN=0
    fi
    ;;
  *)
    echo "Warning: unrecognized KAYE_AUTOLOGIN='$KAYE_AUTOLOGIN'; defaulting to tuigreet greeter." >&2
    USE_AUTOLOGIN=0
    ;;
esac

if ! command -v greetd >/dev/null 2>&1; then
  echo "Warning: greetd is not installed; skipping login manager setup." >&2
  exit 0
fi

# Back up any non-Kaye /etc/greetd/config.toml once before managing it.
sudo install -d -m 755 /etc/greetd
if [[ -f /etc/greetd/config.toml ]] && ! grep -q '^# Kaye OS — greetd configuration' /etc/greetd/config.toml; then
  backup="/etc/greetd/config.toml.pre-kaye.bak"
  if [[ -e "$backup" ]]; then
    backup="/etc/greetd/config.toml.pre-kaye.$(date +%s).bak"
  fi
  echo "==> Backing up existing /etc/greetd/config.toml to $backup..."
  sudo cp -p /etc/greetd/config.toml "$backup"
fi

echo "==> Writing /etc/greetd/config.toml (autologin=$USE_AUTOLOGIN, user=$TARGET_USER)..."
{
  cat <<EOF
# Kaye OS — greetd configuration
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --greeting 'Kaye OS' --cmd '${SESSION_CMD}'"
user = "greeter"
EOF

  if (( USE_AUTOLOGIN == 1 )); then
    cat <<EOF

[initial_session]
command = "${SESSION_CMD}"
user = "${TARGET_USER}"
EOF
  fi
} | sudo tee /etc/greetd/config.toml >/dev/null
sudo chmod 644 /etc/greetd/config.toml

# Ensure tuigreet cache directory exists so --remember and --remember-session work on first boot.
if getent passwd greeter >/dev/null 2>&1; then
  sudo install -d -o greeter -g greeter -m 755 /var/cache/tuigreet
fi

# Seed a passwordless default GNOME keyring when autologin is active so apps never
# nag for an unlock passphrase after already unlocking LUKS at Plymouth.
if (( USE_AUTOLOGIN == 1 )); then
  KEYRING_DIR="$HOME/.local/share/keyrings"
  KEYRING_FILE="$KEYRING_DIR/Default_keyring.keyring"
  DEFAULT_FILE="$KEYRING_DIR/default"

  mkdir -p "$KEYRING_DIR"
  if [[ ! -f "$KEYRING_FILE" ]]; then
    echo "==> Seeding passwordless default GNOME keyring for autologin..."
    cat >"$KEYRING_FILE" <<EOF
[keyring]
display-name=Default keyring
ctime=$(date +%s)
mtime=0
lock-on-idle=false
lock-after=false
EOF
  fi

  if [[ ! -f "$DEFAULT_FILE" ]]; then
    printf 'Default_keyring\n' >"$DEFAULT_FILE"
  fi

  chmod 700 "$KEYRING_DIR"
  chmod 600 "$KEYRING_FILE"
  chmod 644 "$DEFAULT_FILE"
fi

# Safely enable greetd.service without blindly overwriting another active display manager.
# Never use --now here: starting greetd mid-install would terminate the current session.
if systemctl is-enabled greetd.service >/dev/null 2>&1; then
  echo "==> greetd.service is already enabled."
else
  conflicting_dm=""
  for dm in sddm.service gdm.service lightdm.service ly.service ly@tty2.service; do
    if systemctl is-enabled "$dm" >/dev/null 2>&1; then
      conflicting_dm="$dm"
      break
    fi
  done

  if [[ -z "$conflicting_dm" ]]; then
    echo "==> Enabling greetd.service..."
    sudo systemctl enable greetd.service
  else
    echo "Warning: another display manager ($conflicting_dm) is currently enabled." >&2
    if kaye_has_gum_tty; then
      if kaye_ui_confirm "Disable $conflicting_dm and enable greetd for Kaye OS?" 1; then
        sudo systemctl disable "$conflicting_dm"
        sudo systemctl enable greetd.service
      else
        echo "==> Keeping $conflicting_dm enabled (greetd config written to /etc/greetd/config.toml)."
      fi
    else
      echo "==> Skipping automatic disable of $conflicting_dm in non-interactive mode." >&2
      echo "    To switch later: sudo systemctl disable $conflicting_dm && sudo systemctl enable greetd.service" >&2
    fi
  fi
fi
