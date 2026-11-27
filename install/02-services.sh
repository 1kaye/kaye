#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
kaye_enable_err_trap
kaye_is_chroot || true

unit_exists() {
  local unit="$1"
  [[ -f "/usr/lib/systemd/system/$unit" || -f "/etc/systemd/system/$unit" ]] || \
    systemctl list-unit-files "$unit" >/dev/null 2>&1
}

enable_unit() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    return 0
  fi

  if kaye_is_chroot; then
    sudo systemctl enable "$unit"
  else
    sudo systemctl enable --now "$unit" || true
  fi
}

disable_unit() {
  local unit="$1"
  if ! unit_exists "$unit"; then
    return 0
  fi

  if kaye_is_chroot; then
    sudo systemctl disable "$unit" >/dev/null 2>&1 || true
  else
    sudo systemctl disable --now "$unit" >/dev/null 2>&1 || true
  fi
}

# 1. Core system services (chroot-safe: enable-only inside chroot).
echo "==> Enabling core system services..."
for unit in \
  NetworkManager.service \
  bluetooth.service \
  power-profiles-daemon.service \
  paccache.timer; do
  enable_unit "$unit"
done

# Never block boot waiting for DHCP / Wi-Fi association.
if unit_exists NetworkManager-wait-online.service; then
  echo "==> Masking NetworkManager-wait-online.service..."
  sudo systemctl mask NetworkManager-wait-online.service
fi

# 2. Firewall (UFW) — never mutate the live ISO firewall when running in chroot.
set_kv_file() {
  local file="$1" key="$2" val="$3"
  if [[ -f "$file" ]] && grep -Eq "^[[:space:]]*${key}=" "$file"; then
    sudo sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" | sudo tee -a "$file" >/dev/null
  fi
}

if command -v ufw >/dev/null 2>&1; then
  echo "==> Configuring UFW default-deny firewall..."
  if kaye_is_chroot; then
    # Configure UFW policy files directly in chroot so re-runs never invoke
    # ufw's live firewall reload against the host/ISO kernel netfilter.
    if [[ -f /etc/default/ufw ]]; then
      set_kv_file /etc/default/ufw DEFAULT_INPUT_POLICY '"DROP"'
      set_kv_file /etc/default/ufw DEFAULT_OUTPUT_POLICY '"ACCEPT"'
    fi
    if [[ -f /etc/ufw/ufw.conf ]]; then
      set_kv_file /etc/ufw/ufw.conf ENABLED 'yes'
    fi
    sudo systemctl enable ufw.service
  else
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw --force enable
    sudo systemctl enable --now ufw.service
  fi
fi

# 3. ZRAM swap (idempotent, skip live start in chroot).
if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
  echo "==> Configuring zram-generator..."
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
  if ! kaye_is_chroot; then
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service || true
  fi
fi

# 4. Btrfs Snapper (keep max 3 pre-update snapshots, no timeline spam; chroot-safe).
set_snapper_kv() {
  local cfg="$1" key="$2" val="$3"
  if grep -q "^${key}=" "$cfg"; then
    sudo sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$cfg"
  else
    printf '%s="%s"\n' "$key" "$val" | sudo tee -a "$cfg" >/dev/null
  fi
}

if [[ "$(findmnt -n -o FSTYPE / 2>/dev/null || true)" == "btrfs" ]] && command -v snapper >/dev/null 2>&1; then
  if [[ ! -f /etc/snapper/configs/root ]]; then
    echo "==> Creating Snapper root configuration..."
    if ! sudo snapper --no-dbus -c root create-config / 2>/dev/null; then
      # If /.snapshots is already mounted as a dedicated subvolume (e.g. @.snapshots),
      # populate /etc/snapper/configs/root directly from the Snapper template.
      snapper_tpl=""
      for candidate in \
        /usr/share/snapper/config-templates/default \
        /etc/snapper/config-templates/default; do
        if [[ -f "$candidate" ]]; then
          snapper_tpl="$candidate"
          break
        fi
      done

      if [[ -d /.snapshots && -n "$snapper_tpl" ]]; then
        sudo install -d -m 755 /etc/snapper/configs /etc/conf.d
        sudo install -m 640 "$snapper_tpl" /etc/snapper/configs/root
        set_snapper_kv /etc/snapper/configs/root SUBVOLUME "/"
        set_snapper_kv /etc/snapper/configs/root FSTYPE "btrfs"
        sudo chmod 750 /.snapshots || true
        if [[ -f /etc/conf.d/snapper ]] && grep -q '^SNAPPER_CONFIGS=' /etc/conf.d/snapper; then
          if ! grep -Eq '^SNAPPER_CONFIGS=.*\broot\b' /etc/conf.d/snapper; then
            sudo sed -i 's/^SNAPPER_CONFIGS="\(.*\)"/SNAPPER_CONFIGS="\1 root"/' /etc/conf.d/snapper
            sudo sed -i 's/^SNAPPER_CONFIGS=" /SNAPPER_CONFIGS="/' /etc/conf.d/snapper
          fi
        else
          printf 'SNAPPER_CONFIGS="root"\n' | sudo tee /etc/conf.d/snapper >/dev/null
        fi
      else
        echo "Warning: unable to initialize Snapper root config; continuing." >&2
      fi
    fi
  fi

  if [[ -f /etc/snapper/configs/root ]]; then
    if ! sudo snapper --no-dbus -c root set-config \
      TIMELINE_CREATE=no \
      NUMBER_CLEANUP=yes \
      NUMBER_MIN_AGE=0 \
      NUMBER_LIMIT=3 \
      NUMBER_LIMIT_IMPORTANT=3 2>/dev/null; then
      set_snapper_kv /etc/snapper/configs/root TIMELINE_CREATE "no"
      set_snapper_kv /etc/snapper/configs/root NUMBER_CLEANUP "yes"
      set_snapper_kv /etc/snapper/configs/root NUMBER_MIN_AGE "0"
      set_snapper_kv /etc/snapper/configs/root NUMBER_LIMIT "3"
      set_snapper_kv /etc/snapper/configs/root NUMBER_LIMIT_IMPORTANT "3"
    fi

    disable_unit snapper-timeline.timer
    enable_unit snapper-cleanup.timer
  fi
fi

# 5. Relax PAM faillock limits (avoid 10-minute lockouts from lockscreen typos).
echo "==> Configuring /etc/security/faillock.conf (deny = 10, unlock_time = 120)..."
sudo install -d -m 755 /etc/security
if [[ ! -f /etc/security/faillock.conf ]]; then
  sudo tee /etc/security/faillock.conf >/dev/null <<'EOF'
# Kaye OS — relaxed PAM faillock thresholds
deny = 10
unlock_time = 120
EOF
else
  if grep -Eq '^\s*#?\s*deny\s*=' /etc/security/faillock.conf; then
    sudo sed -i -E 's/^\s*#?\s*deny\s*=.*/deny = 10/' /etc/security/faillock.conf
  else
    printf 'deny = 10\n' | sudo tee -a /etc/security/faillock.conf >/dev/null
  fi

  if grep -Eq '^\s*#?\s*unlock_time\s*=' /etc/security/faillock.conf; then
    sudo sed -i -E 's/^\s*#?\s*unlock_time\s*=.*/unlock_time = 120/' /etc/security/faillock.conf
  else
    printf 'unlock_time = 120\n' | sudo tee -a /etc/security/faillock.conf >/dev/null
  fi
fi
