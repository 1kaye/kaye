#!/usr/bin/env bash
set -euo pipefail

# 1. Core system services
for svc in NetworkManager bluetooth power-profiles-daemon; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    sudo systemctl enable --now "${svc}.service" || true
  fi
done

# 2. Firewall (UFW)
if command -v ufw >/dev/null 2>&1; then
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw --force enable
  sudo systemctl enable --now ufw.service
fi

# 3. ZRAM swap (skip if already configured)
if [[ ! -f /etc/systemd/zram-generator.conf ]]; then
  echo "==> Configuring zram-generator..."
  sudo tee /etc/systemd/zram-generator.conf >/dev/null <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF
  sudo systemctl daemon-reload
  sudo systemctl start systemd-zram-setup@zram0.service || true
fi

# 4. Btrfs Snapper (keep max 3 pre-update snapshots, no timeline spam)
if [[ "$(findmnt -n -o FSTYPE /)" == "btrfs" ]] && command -v snapper >/dev/null 2>&1; then
  if [[ ! -f /etc/snapper/configs/root ]]; then
    echo "==> Creating Snapper root config..."
    sudo snapper -c root create-config /
  fi
  sudo snapper -c root set-config \
    TIMELINE_CREATE=no \
    NUMBER_CLEANUP=yes \
    NUMBER_MIN_AGE=0 \
    NUMBER_LIMIT=3 \
    NUMBER_LIMIT_IMPORTANT=3
  sudo systemctl enable --now snapper-cleanup.timer
fi
