#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"

# Idempotently ensures quiet, splash, and loglevel=3 are present in a kernel cmdline string.
kaye_ensure_cmdline_tokens() {
  local line="$1"
  local token

  for token in quiet splash; do
    if [[ ! " $line " =~ [[:space:]]${token}[[:space:]] ]]; then
      line="${line:+${line} }${token}"
    fi
  done

  if [[ ! " $line " =~ [[:space:]]loglevel= ]]; then
    line="${line:+${line} }loglevel=3"
  fi

  printf '%s\n' "$line"
}

kaye_patch_limine_conf() {
  local file="$1"
  local use_sudo="${2:-1}"
  [[ -f "$file" ]] || return 0

  local tmp changed=0 line prefix rest updated
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*(cmdline|KERNEL_CMDLINE):[[:space:]]*)(.*)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[3]}"
      updated="$(kaye_ensure_cmdline_tokens "$rest")"
      if [[ "$updated" != "$rest" ]]; then
        changed=1
      fi
      printf '%s%s\n' "$prefix" "$updated" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( changed == 1 )); then
    local backup="${file}.bak.$(date +%s)"
    echo "==> Patching Limine cmdline in $file (backup: $backup)"
    if (( use_sudo == 1 )); then
      sudo cp -p "$file" "$backup"
      sudo install -m 644 "$tmp" "$file"
    else
      cp -p "$file" "$backup"
      install -m 644 "$tmp" "$file"
    fi
  else
    echo "==> Limine cmdline already configured in $file"
  fi

  rm -f "$tmp"
}

kaye_patch_sdboot_entry() {
  local file="$1"
  local use_sudo="${2:-1}"
  [[ -f "$file" ]] || return 0

  local tmp changed=0 line prefix rest updated
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^([[:space:]]*options[[:space:]]+)(.*)$ ]]; then
      prefix="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      updated="$(kaye_ensure_cmdline_tokens "$rest")"
      if [[ "$updated" != "$rest" ]]; then
        changed=1
      fi
      printf '%s%s\n' "$prefix" "$updated" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( changed == 1 )); then
    local backup="${file}.bak.$(date +%s)"
    echo "==> Patching systemd-boot entry $file (backup: $backup)"
    if (( use_sudo == 1 )); then
      sudo cp -p "$file" "$backup"
      sudo install -m 644 "$tmp" "$file"
    else
      cp -p "$file" "$backup"
      install -m 644 "$tmp" "$file"
    fi
  else
    echo "==> systemd-boot entry already configured: $file"
  fi

  rm -f "$tmp"
}

# Returns 0 if modified, 2 if already configured, 1 on missing file.
kaye_patch_grub_default() {
  local file="$1"
  local use_sudo="${2:-1}"
  [[ -f "$file" ]] || return 1

  local tmp changed=0 found=0 line quote rest updated
  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX_DEFAULT=([\"\'])(.*)([\"\'])[[:space:]]*$ ]]; then
      found=1
      quote="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      updated="$(kaye_ensure_cmdline_tokens "$rest")"
      if [[ "$updated" != "$rest" ]]; then
        changed=1
      fi
      printf 'GRUB_CMDLINE_LINUX_DEFAULT=%s%s%s\n' "$quote" "$updated" "$quote" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$file"

  if (( found == 0 )); then
    changed=1
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3"\n' >>"$tmp"
  fi

  if (( changed == 1 )); then
    local backup="${file}.bak.$(date +%s)"
    echo "==> Patching GRUB cmdline in $file (backup: $backup)"
    if (( use_sudo == 1 )); then
      sudo cp -p "$file" "$backup"
      sudo install -m 644 "$tmp" "$file"
    else
      cp -p "$file" "$backup"
      install -m 644 "$tmp" "$file"
    fi
    rm -f "$tmp"
    return 0
  fi

  echo "==> GRUB cmdline already configured in $file"
  rm -f "$tmp"
  return 2
}

kaye_add_plymouth_hook() {
  local file="$1"
  local use_sudo="${2:-1}"
  [[ -f "$file" ]] || return 0

  if grep -Eq '^[[:space:]]*HOOKS(\+)?=.*\bplymouth\b' "$file"; then
    echo "==> plymouth hook already present in $file"
    return 0
  fi

  local backup="${file}.bak.$(date +%s)"
  echo "==> Adding plymouth hook to $file (backup: $backup)"
  if (( use_sudo == 1 )); then
    sudo cp -p "$file" "$backup"
  else
    cp -p "$file" "$backup"
  fi

  local sed_expr=""
  if grep -Eq '^HOOKS=.*\bsystemd\b' "$file"; then
    if grep -Eq '^HOOKS=.*\bsd-vconsole\b' "$file"; then
      sed_expr='/^HOOKS=/ s/\bsd-vconsole\b/sd-vconsole plymouth/'
    else
      sed_expr='/^HOOKS=/ s/\bsystemd\b/systemd plymouth/'
    fi
  elif grep -Eq '^HOOKS=.*\budev\b' "$file"; then
    sed_expr='/^HOOKS=/ s/\budev\b/udev plymouth/'
  fi

  if [[ -n "$sed_expr" ]]; then
    if (( use_sudo == 1 )); then
      sudo sed -i "$sed_expr" "$file"
    else
      sed -i "$sed_expr" "$file"
    fi
  else
    echo "Warning: could not locate systemd or udev hook in $file; please verify HOOKS manually." >&2
  fi
}

# Allow sourcing helper functions in isolated tests without executing system modifications.
if [[ "${KAYE_BOOT_LIB_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

kaye_enable_err_trap

THEME_SRC="$KAYE_DIR/plymouth/kaye"
THEME_DST="/usr/share/plymouth/themes/kaye"

# 1. Install Kaye Plymouth theme & plymouthd.conf
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  echo "==> Installing Kaye Plymouth theme to $THEME_DST..."
  sudo install -d -m 755 "$THEME_DST"
  sudo cp -a "$THEME_SRC/." "$THEME_DST/"

  echo "==> Configuring /etc/plymouth/plymouthd.conf..."
  sudo install -d -m 755 /etc/plymouth
  sudo tee /etc/plymouth/plymouthd.conf >/dev/null <<'EOF'
# Kaye OS — Plymouth boot splash configuration
[Daemon]
Theme=kaye
ShowDelay=0
EOF

  # 2. Ensure plymouth hook is in mkinitcpio (match active HOOKS lines only, ignoring comments).
  if ! grep -Eq '^[[:space:]]*HOOKS(\+)?=.*\bplymouth\b' /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d/*.conf 2>/dev/null; then
    kaye_add_plymouth_hook /etc/mkinitcpio.conf 1
  else
    echo "==> plymouth hook already configured in mkinitcpio."
  fi
else
  echo "==> Plymouth not installed; skipping Plymouth theme setup."
fi

# 3. Auto-detect and patch bootloader kernel cmdline (Limine / systemd-boot / GRUB).
BOOTLOADER_FOUND=0

# 3a. Limine (limine-entry-tool drop-in + direct limine.conf paths)
if [[ -d /etc/limine-entry-tool.d ]] || command -v limine-update >/dev/null 2>&1; then
  BOOTLOADER_FOUND=1
  echo "==> Writing Limine entry-tool cmdline drop-in..."
  sudo install -d -m 755 /etc/limine-entry-tool.d
  sudo tee /etc/limine-entry-tool.d/10-kaye.conf >/dev/null <<'EOF'
# Kaye OS — Plymouth & quiet boot parameters
KERNEL_CMDLINE[default]+=" quiet splash loglevel=3"
EOF
fi

for limine_cfg in \
  /boot/limine.conf \
  /boot/EFI/limine/limine.conf \
  /boot/limine/limine.conf \
  /efi/limine.conf \
  /efi/EFI/limine/limine.conf; do
  if [[ -f "$limine_cfg" ]]; then
    BOOTLOADER_FOUND=1
    kaye_patch_limine_conf "$limine_cfg" 1
  fi
done

# 3b. systemd-boot (UKI /etc/cmdline.d + loader entries)
if [[ -d /etc/cmdline.d ]]; then
  BOOTLOADER_FOUND=1
  if ! grep -Eq '\bsplash\b' /etc/cmdline.d/*.conf 2>/dev/null; then
    echo "==> Writing /etc/cmdline.d/10-kaye.conf..."
    printf 'quiet splash loglevel=3\n' | sudo tee /etc/cmdline.d/10-kaye.conf >/dev/null
  fi
fi

shopt -s nullglob
for entries_dir in /boot/loader/entries /efi/loader/entries; do
  if [[ -d "$entries_dir" ]]; then
    for entry in "$entries_dir"/*.conf; do
      [[ "$(basename "$entry")" == *-fallback.conf ]] && continue
      BOOTLOADER_FOUND=1
      kaye_patch_sdboot_entry "$entry" 1
    done
  fi
done
shopt -u nullglob

# 3c. GRUB
if [[ -f /etc/default/grub ]]; then
  BOOTLOADER_FOUND=1
  grub_rc=0
  kaye_patch_grub_default /etc/default/grub 1 || grub_rc=$?
  if (( grub_rc == 0 )) && command -v grub-mkconfig >/dev/null 2>&1 && [[ -d /boot/grub ]]; then
    echo "==> Regenerating /boot/grub/grub.cfg..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg
  fi
fi

if (( BOOTLOADER_FOUND == 0 )); then
  echo "Warning: no supported bootloader config detected (Limine, systemd-boot, GRUB)." >&2
  echo "         Add 'quiet splash loglevel=3' to your kernel command line manually." >&2
fi

# 4. Activate Kaye Plymouth theme and rebuild initramfs.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
  echo "==> Activating Kaye Plymouth theme..."
  sudo plymouth-set-default-theme kaye
  if command -v limine-update >/dev/null 2>&1; then
    echo "==> Updating Limine boot images via limine-update..."
    sudo limine-update
  elif command -v mkinitcpio >/dev/null 2>&1; then
    echo "==> Rebuilding initramfs images..."
    sudo mkinitcpio -P
  fi
fi
