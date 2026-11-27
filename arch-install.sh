#!/usr/bin/env bash
set -euo pipefail

# Kaye OS — Turnkey Arch Linux Live-ISO Installer (Track 2)
#
# Usage:
#   From official Arch Live ISO:
#     curl -fsSL https://raw.githubusercontent.com/1kaye/kaye/main/arch-install.sh | bash
#   From Kaye OS Live ISO:
#     /opt/kaye/arch-install.sh
#   Unattended:
#     /opt/kaye/arch-install.sh --config /path/to/kaye.env [--unattended]
#     (or attach a drive with LABEL=cidata containing kaye.env or kaye.conf)

readonly DEFAULT_KAYE_REPO="https://github.com/1kaye/kaye.git"
readonly DEFAULT_KAYE_REF="main"
readonly INSTALL_LOG="/var/log/kaye-arch-install.log"
readonly SUDOERS_TMP="/mnt/etc/sudoers.d/99-kaye-install"

# Catppuccin Mocha palette (matches themes/catppuccin/colors.toml)
readonly CLR_ACCENT="#89b4fa"
readonly CLR_MAUVE="#cba6f7"
readonly CLR_GREEN="#a6e3a1"
readonly CLR_YELLOW="#f9e2af"
readonly CLR_RED="#f38ba8"
readonly CLR_MUTED="#6c7086"

# Runtime flags & configuration state
CONFIG_FILE=""
UNATTENDED=0
DRY_RUN=0
SOURCE_OVERRIDE=""
KAYE_REPO="${KAYE_REPO:-$DEFAULT_KAYE_REPO}"
KAYE_REF="${KAYE_REF:-$DEFAULT_KAYE_REF}"

TARGET_DISK=""
USE_LUKS=""
LUKS_PASSPHRASE=""
BOOTLOADER=""
KEYMAP=""
TIMEZONE=""
TARGET_USER=""
USER_PASSWORD=""
ROOT_PASSWORD=""
TARGET_HOSTNAME=""
THEME=""
BROWSER=""
CONFIRM_WIPE=""
AUTO_REBOOT="0"

# Track cleanup state
MOUNTED=0
LUKS_OPENED=0
CIDATA_MNT=""
CIDATA_TMP_CFG=""
CIDATA_DEV=""
EFI_PART=""
ROOT_PART=""
BTRFS_DEV=""
LUKS_UUID=""
ROOT_UUID=""
KERNEL_CMDLINE=""
SCRIPT_DIR=""

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

# -----------------------------------------------------------------------------
# Logging & UI Helpers
# -----------------------------------------------------------------------------

log_msg() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  if [[ -w "$(dirname "$INSTALL_LOG")" || -w "$INSTALL_LOG" ]]; then
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >>"$INSTALL_LOG" 2>/dev/null || true
  fi
}

has_gum() {
  command -v gum >/dev/null 2>&1
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

print_logo() {
  local logo_file=""
  if [[ -n "$SOURCE_OVERRIDE" && -f "$SOURCE_OVERRIDE/branding/logo.txt" ]]; then
    logo_file="$SOURCE_OVERRIDE/branding/logo.txt"
  elif [[ -f "/opt/kaye/branding/logo.txt" ]]; then
    logo_file="/opt/kaye/branding/logo.txt"
  elif [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/branding/logo.txt" ]]; then
    logo_file="$SCRIPT_DIR/branding/logo.txt"
  fi

  local logo_text
  if [[ -n "$logo_file" ]]; then
    logo_text="$(cat "$logo_file")"
  else
    logo_text="$(cat <<'EOF'
███   ███   ▄█████▄   ███   ███  █████████
███  ███   ███   ███  ███   ███  ███
███ ███    ███   ███  ███   ███  ███
██████     █████████   ▀█████▀   ███████
███ ███    ███   ███     ███     ███
███  ███   ███   ███     ███     ███
███   ███  ███   ███     ███     █████████
EOF
)"
  fi

  if has_gum && is_tty; then
    gum style \
      --foreground "$CLR_ACCENT" \
      --border rounded \
      --border-foreground "$CLR_MAUVE" \
      --padding "1 3" \
      --margin "1 0" \
      "$logo_text" \
      "" \
      "Kaye OS — Turnkey Arch Linux Installer"
  else
    printf '\n%s\n\n  Kaye OS — Turnkey Arch Linux Installer\n\n' "$logo_text"
  fi
}

ui_step() {
  local step="$1"
  local total="$2"
  local title="$3"
  log_msg "STEP" "[$step/$total] $title"
  if has_gum && is_tty; then
    printf '\n'
    gum style --foreground "$CLR_ACCENT" --bold "[$step/$total] $title"
  else
    printf '\n==> [%s/%s] %s\n' "$step" "$total" "$title"
  fi
}

ui_info() {
  log_msg "INFO" "$*"
  if has_gum && is_tty; then
    gum style --foreground "$CLR_MUTED" "  • $*"
  else
    printf '  • %s\n' "$*"
  fi
}

ui_ok() {
  log_msg "OK" "$*"
  if has_gum && is_tty; then
    gum style --foreground "$CLR_GREEN" "  ✓ $*"
  else
    printf '  [OK] %s\n' "$*"
  fi
}

ui_warn() {
  log_msg "WARN" "$*"
  if has_gum && is_tty; then
    gum style --foreground "$CLR_YELLOW" "  ! $*" >&2
  else
    printf '  [WARN] %s\n' "$*" >&2
  fi
}

ui_err() {
  log_msg "ERROR" "$*"
  if has_gum && is_tty; then
    gum style --foreground "$CLR_RED" --bold "  ✗ $*" >&2
  else
    printf '  [ERROR] %s\n' "$*" >&2
  fi
}

die() {
  ui_err "$*"
  exit 1
}

# -----------------------------------------------------------------------------
# Traps & Guaranteed Cleanup
# -----------------------------------------------------------------------------

cleanup() {
  local exit_code=$?

  # Guarantee temporary installer sudoers file is ALWAYS removed
  if [[ -e "$SUDOERS_TMP" ]]; then
    rm -f "$SUDOERS_TMP" 2>/dev/null || true
  fi

  # Unmount and remove temporary cidata resources
  if [[ -n "$CIDATA_MNT" ]]; then
    if mountpoint -q "$CIDATA_MNT" 2>/dev/null; then
      umount "$CIDATA_MNT" 2>/dev/null || true
    fi
    rmdir "$CIDATA_MNT" 2>/dev/null || true
    CIDATA_MNT=""
  fi
  if [[ -n "$CIDATA_TMP_CFG" && -f "$CIDATA_TMP_CFG" ]]; then
    rm -f "$CIDATA_TMP_CFG" 2>/dev/null || true
    CIDATA_TMP_CFG=""
  fi

  # If aborted/failed while mounts or LUKS are open, cleanly release them so re-runs work
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$MOUNTED" -eq 1 ]]; then
      sync || true
      umount -R /mnt 2>/dev/null || true
      MOUNTED=0
    fi
    if [[ "$LUKS_OPENED" -eq 1 ]]; then
      cryptsetup close cryptroot 2>/dev/null || true
      LUKS_OPENED=0
    fi
  fi
}

on_error() {
  local line="$1"
  local cmd="$2"
  ui_err "Command failed at line ${line}: ${cmd}"
  if [[ -f "$INSTALL_LOG" ]]; then
    ui_warn "Inspect full log at: ${INSTALL_LOG}"
  fi
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# -----------------------------------------------------------------------------
# Usage & CLI Parsing
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Kaye OS — Turnkey Arch Linux Live-ISO Installer

Usage:
  arch-install.sh [OPTIONS]

Options:
  -c, --config <file>   Load configuration from key=value file (kaye.env / kaye.conf)
  -y, --unattended      Run non-interactively (requires --config or LABEL=cidata drive)
      --repo <url>      Override Kaye git repository URL (default: https://github.com/1kaye/kaye.git)
      --ref <branch>    Override git branch/tag (default: main)
      --source <dir>    Use local Kaye OS repository directory instead of cloning
      --dry-run         Validate config and print installation plan without modifying disks
  -h, --help            Show this help message and exit

Unattended Configuration (kaye.env / kaye.conf or LABEL=cidata partition):
  KAYE_DISK=/dev/nvme0n1             Target disk (required)
  KAYE_LUKS=1                        Enable LUKS2 encryption: 1|0 (default: 1)
  KAYE_LUKS_PASSPHRASE=secret        LUKS2 passphrase (required if KAYE_LUKS=1)
  KAYE_BOOTLOADER=limine             Bootloader: limine|systemd-boot (default: limine)
  KAYE_KEYMAP=us                     Console keymap (default: us)
  KAYE_TIMEZONE=UTC                  Timezone under /usr/share/zoneinfo (default: UTC)
  KAYE_USERNAME=alex                 Primary user account (required)
  KAYE_PASSWORD=secret               User password (required)
  KAYE_ROOT_PASSWORD=secret          Optional root password (defaults to KAYE_PASSWORD)
  KAYE_HOSTNAME=kaye                 System hostname (default: kaye)
  KAYE_THEME=catppuccin              Theme: catppuccin|tokyo-night|gruvbox (default: catppuccin)
  KAYE_BROWSER=firefox               Browser: firefox|chromium|skip (default: firefox)
  KAYE_CONFIRM_WIPE=yes              Confirm destructive disk wipe for unattended installs
  KAYE_AUTO_REBOOT=0                 Automatically reboot when done: 1|0 (default: 0)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--config)
        [[ $# -ge 2 ]] || die "--config requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      -y|--unattended)
        UNATTENDED=1
        shift
        ;;
      --repo)
        [[ $# -ge 2 ]] || die "--repo requires a URL"
        KAYE_REPO="$2"
        shift 2
        ;;
      --ref)
        [[ $# -ge 2 ]] || die "--ref requires a branch or tag"
        KAYE_REF="$2"
        shift 2
        ;;
      --source)
        [[ $# -ge 2 ]] || die "--source requires a directory path"
        SOURCE_OVERRIDE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Config Parsing & Unattended cidata Auto-Detection
# -----------------------------------------------------------------------------

normalize_bool() {
  local val="${1,,}"
  case "$val" in
    1|true|yes|y|on) printf '1\n' ;;
    0|false|no|n|off) printf '0\n' ;;
    *) return 1 ;;
  esac
}

load_config_file() {
  local file="$1"
  [[ -f "$file" && -r "$file" ]] || die "Config file not readable: $file"

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip CR (Windows line endings)
    line="${line%$'\r'}"
    # Trim leading whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    # Skip empty lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Allow optional leading 'export '
    line="${line#export }"
    line="${line#"${line%%[![:space:]]*}"}"

    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"

    # Trim whitespace around key
    key="${key%"${key##*[![:space:]]}"}"
    # Trim leading/trailing whitespace around value
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    # Strip matching surrounding single or double quotes (no shell eval!)
    if [[ ${#val} -ge 2 ]]; then
      if [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]]; then
        val="${val:1:${#val}-2}"
      elif [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
        val="${val:1:${#val}-2}"
      fi
    fi

    case "$key" in
      KAYE_DISK|DISK)                     TARGET_DISK="$val" ;;
      KAYE_LUKS|LUKS)                     USE_LUKS="$(normalize_bool "$val")" || die "Invalid KAYE_LUKS value: $val" ;;
      KAYE_LUKS_PASSPHRASE|LUKS_PASSPHRASE) LUKS_PASSPHRASE="$val" ;;
      KAYE_BOOTLOADER|BOOTLOADER)         BOOTLOADER="${val,,}" ;;
      KAYE_KEYMAP|KEYMAP)                 KEYMAP="$val" ;;
      KAYE_TIMEZONE|TIMEZONE)             TIMEZONE="$val" ;;
      KAYE_USERNAME|USERNAME)             TARGET_USER="$val" ;;
      KAYE_PASSWORD|PASSWORD)             USER_PASSWORD="$val" ;;
      KAYE_ROOT_PASSWORD|ROOT_PASSWORD)   ROOT_PASSWORD="$val" ;;
      KAYE_HOSTNAME|HOSTNAME)             TARGET_HOSTNAME="$val" ;;
      KAYE_THEME|THEME)                   THEME="${val,,}" ;;
      KAYE_BROWSER|BROWSER)               BROWSER="${val,,}" ;;
      KAYE_CONFIRM_WIPE|CONFIRM_WIPE)     CONFIRM_WIPE="$(normalize_bool "$val")" || die "Invalid KAYE_CONFIRM_WIPE value: $val" ;;
      KAYE_AUTO_REBOOT|AUTO_REBOOT)       AUTO_REBOOT="$(normalize_bool "$val")" || die "Invalid KAYE_AUTO_REBOOT value: $val" ;;
      KAYE_REPO)                          KAYE_REPO="$val" ;;
      KAYE_REF)                           KAYE_REF="$val" ;;
      KAYE_SOURCE)                        SOURCE_OVERRIDE="$val" ;;
      *)
        ui_warn "Ignoring unrecognized config key: $key"
        ;;
    esac
  done <"$file"
}

detect_cidata_config() {
  [[ -z "$CONFIG_FILE" ]] || return 0
  command -v blkid >/dev/null 2>&1 || return 0

  local dev=""
  dev="$(blkid -L cidata 2>/dev/null || blkid -L CIDATA 2>/dev/null || true)"
  [[ -n "$dev" && -b "$dev" ]] || return 0

  CIDATA_DEV="$dev"
  CIDATA_MNT="$(mktemp -d /tmp/kaye-cidata.XXXXXX)"
  if ! mount -o ro "$dev" "$CIDATA_MNT" 2>/dev/null; then
    rmdir "$CIDATA_MNT" 2>/dev/null || true
    CIDATA_MNT=""
    return 0
  fi

  local found=""
  if [[ -f "$CIDATA_MNT/kaye.env" ]]; then
    found="$CIDATA_MNT/kaye.env"
  elif [[ -f "$CIDATA_MNT/kaye.conf" ]]; then
    found="$CIDATA_MNT/kaye.conf"
  fi

  if [[ -n "$found" ]]; then
    CIDATA_TMP_CFG="$(mktemp /tmp/kaye-config.XXXXXX)"
    chmod 0600 "$CIDATA_TMP_CFG"
    cp "$found" "$CIDATA_TMP_CFG"
    CONFIG_FILE="$CIDATA_TMP_CFG"
    UNATTENDED=1
    ui_ok "Detected unattended config on LABEL=cidata (${dev}: $(basename "$found"))"
  fi

  umount "$CIDATA_MNT" 2>/dev/null || true
  rmdir "$CIDATA_MNT" 2>/dev/null || true
  CIDATA_MNT=""
}

# -----------------------------------------------------------------------------
# Pure Helper Functions (Disk Detection, Partition Naming, Validators)
# -----------------------------------------------------------------------------

partition_path() {
  local disk="$1"
  local part_num="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf '%sp%s\n' "$disk" "$part_num"
  else
    printf '%s%s\n' "$disk" "$part_num"
  fi
}

resolve_parent_disks() {
  local src="$1"
  [[ -n "$src" ]] || return 0
  # Strip btrfs subvol suffix like /dev/sda2[/@]
  src="${src%%\[*}"
  [[ -b "$src" ]] || return 0

  # Walk full inverse dependency chain (handles partitions, dm-crypt, LVM, Ventoy)
  lsblk -nspro NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" {print $1}'
}

detect_excluded_disks() {
  local -A excluded=()
  local mnt src disk

  # Exclude any disk backing live ISO boot media or current root
  for mnt in /run/archiso/bootmnt /run/archiso/copytoram /run/archiso/airootfs /lib/live/mount/medium /; do
    if mountpoint -q "$mnt" 2>/dev/null; then
      src="$(findmnt -no SOURCE "$mnt" 2>/dev/null || true)"
      while IFS= read -r disk; do
        [[ -n "$disk" ]] && excluded["$disk"]=1
      done < <(resolve_parent_disks "$src")
    fi
  done

  # Exclude any disk holding LABEL=cidata or an iso9660 live image (covers copytoram)
  local label dev
  for label in cidata CIDATA; do
    dev="$(blkid -L "$label" 2>/dev/null || true)"
    while IFS= read -r disk; do
      [[ -n "$disk" ]] && excluded["$disk"]=1
    done < <(resolve_parent_disks "$dev")
  done
  if [[ -n "$CIDATA_DEV" ]]; then
    while IFS= read -r disk; do
      [[ -n "$disk" ]] && excluded["$disk"]=1
    done < <(resolve_parent_disks "$CIDATA_DEV")
  fi
  while IFS= read -r dev; do
    while IFS= read -r disk; do
      [[ -n "$disk" ]] && excluded["$disk"]=1
    done < <(resolve_parent_disks "$dev")
  done < <(blkid -t TYPE=iso9660 -o device 2>/dev/null || true)

  # Also exclude any disk that contains a partition mounted under /run/archiso
  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    while IFS= read -r disk; do
      [[ -n "$disk" ]] && excluded["$disk"]=1
    done < <(resolve_parent_disks "$src")
  done < <(findmnt -rn -o SOURCE,TARGET 2>/dev/null | awk '$2 ~ /^\/run\/archiso/ {print $1}')

  local k
  for k in "${!excluded[@]}"; do
    printf '%s\n' "$k"
  done
}

list_installable_disks() {
  local -A excluded=()
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && excluded["$d"]=1
  done < <(detect_excluded_disks)

  local line name size model tran type ro
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="" size="" model="" tran="" type="" ro=""
    # Parse lsblk --pairs (KEY="VALUE") safely without eval
    while [[ "$line" =~ ([A-Z]+)=\"([^\"]*)\"(.*) ]]; do
      case "${BASH_REMATCH[1]}" in
        NAME)  name="${BASH_REMATCH[2]}" ;;
        SIZE)  size="${BASH_REMATCH[2]}" ;;
        MODEL) model="${BASH_REMATCH[2]}" ;;
        TRAN)  tran="${BASH_REMATCH[2]}" ;;
        TYPE)  type="${BASH_REMATCH[2]}" ;;
        RO)    ro="${BASH_REMATCH[2]}" ;;
      esac
      line="${BASH_REMATCH[3]}"
    done

    [[ "$type" == "disk" ]] || continue
    [[ "$ro" == "0" ]] || continue
    [[ -n "$name" && -z "${excluded[$name]:-}" ]] || continue
    # Skip zero-size or non-storage virtual disks
    [[ "$size" != "0B" && -n "$size" ]] || continue
    [[ "$name" == /dev/zram* || "$name" == /dev/loop* || "$name" == /dev/ram* || "$name" == /dev/sr* ]] && continue

    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    model="${model:-Unknown Drive}"
    tran="${tran:-disk}"
    printf '%s\t%s\t%s\t%s\n' "$name" "$size" "$model" "$tran"
  done < <(lsblk -dpno NAME,SIZE,MODEL,TRAN,TYPE,RO -P 2>/dev/null)
}

is_reserved_username() {
  local user="$1"
  case "$user" in
    root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|\
    list|irc|gnats|nobody|ftp|http|adm|shutdown|halt|operator|dbus|messagebus|\
    polkitd|avahi|colord|geoclue|git|greeter|greetd|lightdm|sddm|gdm|rtkit|\
    pipewire|seat|tss|uuidd|ntp|nm-openconnect|nm-openvpn|systemd-network|\
    systemd-resolve|systemd-timesync|systemd-coredump|systemd-oom|\
    systemd-journal-remote|archiso|live|wheel|sudo|users|video|audio|input|\
    storage|network|optical|rfkill)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_username() {
  local user="$1"
  if [[ ! "$user" =~ ^[a-z][a-z0-9_-]{0,30}$ ]]; then
    return 1
  fi
  if is_reserved_username "$user"; then
    return 1
  fi
  return 0
}

validate_hostname() {
  local host="$1"
  [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

validate_timezone() {
  local tz="$1"
  [[ -n "$tz" && "$tz" != /* && "$tz" != *..* && -f "/usr/share/zoneinfo/$tz" ]]
}

# -----------------------------------------------------------------------------
# Pre-Flight Checks & Connectivity / Wi-Fi Wizard
# -----------------------------------------------------------------------------

check_internet() {
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 5 --head https://archlinux.org >/dev/null 2>&1; then
      return 0
    fi
  fi
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}

strip_ansi() {
  sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g'
}

wifi_setup_wizard() {
  if ! command -v iwctl >/dev/null 2>&1; then
    die "No internet connection and 'iwctl' is not available. Connect Ethernet and retry."
  fi

  local wifi_dev=""
  local path
  for path in /sys/class/net/*/wireless; do
    if [[ -d "$path" ]]; then
      wifi_dev="$(basename "$(dirname "$path")")"
      break
    fi
  done

  if [[ -z "$wifi_dev" ]]; then
    die "No internet connection and no Wi-Fi adapter detected. Connect Ethernet and retry."
  fi

  ui_warn "No internet connection detected. Launching Wi-Fi setup on ${wifi_dev}..."

  while true; do
    iwctl station "$wifi_dev" scan >/dev/null 2>&1 || true
    sleep 2

    local -a ssids=()
    local line ssid
    while IFS= read -r line; do
      # Skip headers/borders/empty lines in `iwctl station <dev> get-networks`
      [[ -z "$line" ]] && continue
      [[ "$line" == *"Available networks"* || "$line" == *"Network name"* || "$line" == *"----"* ]] && continue
      # Remove leading active '>' marker and trailing security/signal columns
      ssid="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]>]+//' | sed -E 's/[[:space:]]+(psk|open|8021x|wep)[[:space:]].*$//' | sed -E 's/[[:space:]]+$//')"
      [[ -n "$ssid" ]] && ssids+=("$ssid")
    done < <(iwctl station "$wifi_dev" get-networks 2>/dev/null | strip_ansi)

    local chosen_ssid=""
    if [[ ${#ssids[@]} -eq 0 ]]; then
      ui_warn "No Wi-Fi networks found."
      printf 'Enter SSID manually (or leave blank to rescan, "q" to abort): '
      read -r chosen_ssid
      [[ "$chosen_ssid" == "q" ]] && die "Aborted by user while offline."
      [[ -z "$chosen_ssid" ]] && continue
    else
      if has_gum && is_tty; then
        chosen_ssid="$(printf '%s\n' "${ssids[@]}" "Rescan networks" "Enter SSID manually" "Abort" | gum choose --header "Select Wi-Fi network (${wifi_dev}):")"
      else
        printf '\nAvailable Wi-Fi networks (%s):\n' "$wifi_dev"
        local i
        for i in "${!ssids[@]}"; do
          printf '  %d) %s\n' "$((i + 1))" "${ssids[$i]}"
        done
        printf '  r) Rescan   m) Enter manually   q) Abort\n'
        local choice
        printf 'Select network: '
        read -r choice
        case "$choice" in
          r|R) continue ;;
          q|Q) die "Aborted by user while offline." ;;
          m|M)
            printf 'Enter SSID: '
            read -r chosen_ssid
            ;;
          *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ssids[@]} )); then
              chosen_ssid="${ssids[$((choice - 1))]}"
            else
              ui_warn "Invalid selection."
              continue
            fi
            ;;
        esac
      fi

      case "$chosen_ssid" in
        "Rescan networks") continue ;;
        "Abort") die "Aborted by user while offline." ;;
        "Enter SSID manually")
          if has_gum && is_tty; then
            chosen_ssid="$(gum input --header "Wi-Fi SSID:" --placeholder "MyNetwork")"
          else
            printf 'Enter SSID: '
            read -r chosen_ssid
          fi
          ;;
      esac
    fi

    [[ -n "$chosen_ssid" ]] || continue

    local wifi_pass=""
    if has_gum && is_tty; then
      wifi_pass="$(gum input --password --header "Passphrase for '${chosen_ssid}' (leave blank for open network):" --placeholder "Passphrase")"
    else
      printf 'Passphrase for %s (leave blank for open network): ' "$chosen_ssid"
      read -rs wifi_pass
      printf '\n'
    fi

    ui_info "Connecting to '${chosen_ssid}'..."
    if [[ -n "$wifi_pass" ]]; then
      iwctl --passphrase "$wifi_pass" station "$wifi_dev" connect "$chosen_ssid" || ui_warn "iwctl connection attempt returned non-zero"
    else
      iwctl station "$wifi_dev" connect "$chosen_ssid" || ui_warn "iwctl connection attempt returned non-zero"
    fi

    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if check_internet; then
        ui_ok "Connected to '${chosen_ssid}' — internet is online."
        return 0
      fi
      sleep 1
    done

    ui_warn "Connected interface did not reach the internet yet. Retry or choose another network."
  done
}

preflight_checks() {
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ "$EUID" -ne 0 ]]; then
      die "This installer must be run as root on an Arch Linux Live ISO."
    fi
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
      die "UEFI firmware not detected (/sys/firmware/efi/efivars missing). Boot the ISO in UEFI mode."
    fi
  fi

  if [[ "$DRY_RUN" -eq 0 ]]; then
    if ! check_internet; then
      if [[ "$UNATTENDED" -eq 1 ]]; then
        ui_info "Waiting up to 15s for network connectivity..."
        local i
        for i in $(seq 1 15); do
          if check_internet; then
            break
          fi
          sleep 1
        done
        check_internet || die "No internet connection in unattended mode."
      else
        wifi_setup_wizard
      fi
    fi

    # Sync system clock early so pacman signatures & TLS succeed
    if command -v timedatectl >/dev/null 2>&1; then
      timedatectl set-ntp true >/dev/null 2>&1 || true
    fi

    # Ensure gum is installed for interactive mode
    if [[ "$UNATTENDED" -eq 0 ]] && ! has_gum; then
      ui_info "Installing gum for interactive installer UI..."
      pacman -Sy --needed --noconfirm gum >>"$INSTALL_LOG" 2>&1 \
        || die "Failed to install gum via pacman. Check internet/mirrors."
    fi
  fi
}

check_live_tools() {
  local -a required=(sgdisk wipefs lsblk blkid partprobe mkfs.fat mkfs.btrfs pacstrap genfstab arch-chroot)
  if [[ "$USE_LUKS" == "1" ]]; then
    required+=(cryptsetup)
  fi
  local missing=()
  local tool
  for tool in "${required[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required Arch Live ISO tool(s): ${missing[*]}"
  fi
}

# -----------------------------------------------------------------------------
# Interactive gum Wizard
# -----------------------------------------------------------------------------

detect_geo_timezone() {
  local tz=""
  if command -v curl >/dev/null 2>&1; then
    tz="$(curl -fsS --max-time 3 https://ipapi.co/timezone 2>/dev/null || true)"
    if ! validate_timezone "$tz"; then
      tz="$(curl -fsS --max-time 3 https://ipinfo.io/timezone 2>/dev/null || true)"
    fi
  fi
  if validate_timezone "$tz"; then
    printf '%s\n' "$tz"
  else
    printf 'UTC\n'
  fi
}

prompt_password_confirmed() {
  local prompt_label="$1"
  local allow_short="${2:-0}"
  local p1 p2
  while true; do
    p1="$(gum input --password --header "$prompt_label" --placeholder "Enter secret")"
    if [[ -z "$p1" ]]; then
      ui_warn "Value cannot be empty."
      continue
    fi
    if [[ "$allow_short" -eq 0 && ${#p1} -lt 6 ]]; then
      ui_warn "Passphrase is very short (< 6 chars). Consider using a stronger one."
    fi
    p2="$(gum input --password --header "Confirm ${prompt_label}" --placeholder "Re-enter to confirm")"
    if [[ "$p1" != "$p2" ]]; then
      ui_warn "Entries did not match. Please try again."
      continue
    fi
    printf '%s' "$p1"
    return 0
  done
}

run_interactive_wizard() {
  print_logo

  # 1. Keyboard layout (applied live immediately for passphrase/password typing!)
  if [[ -z "$KEYMAP" ]]; then
    local km_choice
    km_choice="$(gum choose --header "1. Select keyboard layout:" \
      "us" "uk" "de" "fr" "es" "it" "pt-latin1" "se" "no" "dk" "fi" "nl" "ch" "pl" "jp106" "dvorak" "colemak" "Other (search all)")"
    if [[ "$km_choice" == "Other (search all)" ]]; then
      if command -v localectl >/dev/null 2>&1; then
        KEYMAP="$(localectl list-keymaps | gum filter --header "Search keyboard layout:" --placeholder "Type keymap name...")"
      else
        KEYMAP="$(gum input --header "Enter console keymap:" --value "us")"
      fi
    else
      KEYMAP="$km_choice"
    fi
  fi
  if [[ "$DRY_RUN" -eq 0 ]] && command -v loadkeys >/dev/null 2>&1; then
    loadkeys "$KEYMAP" 2>/dev/null || ui_warn "Could not load live keymap '${KEYMAP}'; continuing."
  fi

  # 2. Target disk (excluding live ISO boot media)
  if [[ -z "$TARGET_DISK" ]]; then
    local -a disk_options=()
    local d_name d_size d_model d_tran
    while IFS=$'\t' read -r d_name d_size d_model d_tran; do
      [[ -n "$d_name" ]] || continue
      disk_options+=("${d_name}  |  ${d_size}  |  ${d_model} (${d_tran})")
    done < <(list_installable_disks)

    [[ ${#disk_options[@]} -gt 0 ]] || die "No eligible installation disks found (live ISO boot media excluded)."

    local disk_sel
    disk_sel="$(printf '%s\n' "${disk_options[@]}" | gum choose --header "2. Select target disk (ALL DATA ON THIS DISK WILL BE ERASED):")"
    TARGET_DISK="${disk_sel%% *}"
  fi

  # 3. LUKS2 encryption toggle + passphrase
  if [[ -z "$USE_LUKS" ]]; then
    if gum confirm --default=true --affirmative="Encrypt with LUKS2 (Recommended)" --negative="No encryption" \
      "3. Enable full-disk LUKS2 encryption? (Enables seamless autologin after boot unlock)"; then
      USE_LUKS="1"
    else
      USE_LUKS="0"
    fi
  fi
  if [[ "$USE_LUKS" == "1" && -z "$LUKS_PASSPHRASE" ]]; then
    LUKS_PASSPHRASE="$(prompt_password_confirmed "3b. Disk encryption (LUKS2) passphrase:" 0)"
  fi

  # 4. Bootloader
  if [[ -z "$BOOTLOADER" ]]; then
    local bl_choice
    bl_choice="$(gum choose --header "4. Select UEFI bootloader:" \
      "limine       (Recommended — fast, themed, modern)" \
      "systemd-boot (Minimal Arch standard)")"
    BOOTLOADER="${bl_choice%% *}"
  fi

  # 5. Timezone (geo-IP suggestion + gum filter)
  if [[ -z "$TIMEZONE" ]]; then
    local suggested_tz
    suggested_tz="$(detect_geo_timezone)"
    if [[ "$suggested_tz" != "UTC" ]] && gum confirm --default=true "5. Use detected timezone '${suggested_tz}'?"; then
      TIMEZONE="$suggested_tz"
    else
      local -a tz_list=()
      mapfile -t tz_list < <(
        find /usr/share/zoneinfo -mindepth 1 -maxdepth 3 \( -type f -o -type l \) \
          ! -path '*/posix/*' ! -path '*/right/*' ! -name '*.tab' ! -name '*.list' \
          ! -name 'leapseconds' ! -name 'tzdata.zi' ! -name 'Factory' \
          -printf '%P\n' 2>/dev/null | sort -u
      )
      TIMEZONE="$(printf '%s\n' "${tz_list[@]}" | gum filter --header "5. Select timezone:" --placeholder "e.g. America/New_York, Europe/Berlin, Asia/Tokyo...")"
    fi
  fi

  # 6. Username (strict regex + reserved blocklist)
  if [[ -z "$TARGET_USER" ]]; then
    while true; do
      local candidate
      candidate="$(gum input --header "6. Create user account (lowercase letters, digits, '-' or '_'):" --placeholder "alex")"
      if validate_username "$candidate"; then
        TARGET_USER="$candidate"
        break
      fi
      ui_warn "Invalid or reserved username '${candidate}'. Must start with [a-z], max 31 chars, and not be a system account."
    done
  fi

  # 7. User password
  if [[ -z "$USER_PASSWORD" ]]; then
    USER_PASSWORD="$(prompt_password_confirmed "7. Password for user '${TARGET_USER}':" 1)"
  fi

  # 8. Hostname
  if [[ -z "$TARGET_HOSTNAME" ]]; then
    while true; do
      local host_cand
      host_cand="$(gum input --header "8. System hostname:" --value "kaye")"
      if validate_hostname "$host_cand"; then
        TARGET_HOSTNAME="$host_cand"
        break
      fi
      ui_warn "Invalid hostname '${host_cand}'. Use letters, digits, and hyphens only."
    done
  fi

  # 9. Theme
  if [[ -z "$THEME" ]]; then
    THEME="$(gum choose --header "9. Select Kaye OS desktop theme:" "catppuccin" "tokyo-night" "gruvbox")"
  fi

  # 10. Browser
  if [[ -z "$BROWSER" ]]; then
    BROWSER="$(gum choose --header "10. Select default web browser:" "firefox" "chromium" "skip")"
  fi
}

apply_defaults_and_validate() {
  USE_LUKS="${USE_LUKS:-1}"
  BOOTLOADER="${BOOTLOADER:-limine}"
  KEYMAP="${KEYMAP:-us}"
  TIMEZONE="${TIMEZONE:-UTC}"
  TARGET_HOSTNAME="${TARGET_HOSTNAME:-kaye}"
  THEME="${THEME:-catppuccin}"
  BROWSER="${BROWSER:-firefox}"
  ROOT_PASSWORD="${ROOT_PASSWORD:-$USER_PASSWORD}"

  [[ -n "$TARGET_DISK" ]] || die "Target disk (KAYE_DISK) is required."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    [[ -b "$TARGET_DISK" ]] || die "Target disk is not a valid block device: $TARGET_DISK"
    # Double-check target disk is NOT a live ISO boot disk
    local excl
    while IFS= read -r excl; do
      if [[ -n "$excl" && "$excl" == "$TARGET_DISK" ]]; then
        die "Refusing to wipe live ISO / cidata disk: $TARGET_DISK"
      fi
    done < <(detect_excluded_disks)
  fi

  case "$USE_LUKS" in
    0|1) ;;
    *) die "Invalid KAYE_LUKS value: $USE_LUKS (expected 0 or 1)" ;;
  esac

  if [[ "$USE_LUKS" == "1" && -z "$LUKS_PASSPHRASE" ]]; then
    die "KAYE_LUKS_PASSPHRASE is required when LUKS2 encryption is enabled."
  fi

  case "$BOOTLOADER" in
    limine|systemd-boot) ;;
    *) die "Unsupported bootloader '${BOOTLOADER}'. Expected 'limine' or 'systemd-boot'." ;;
  esac

  validate_timezone "$TIMEZONE" || die "Invalid timezone '${TIMEZONE}' (not found in /usr/share/zoneinfo)."
  validate_username "$TARGET_USER" || die "Invalid or reserved username: '${TARGET_USER}'."
  [[ -n "$USER_PASSWORD" ]] || die "User password (KAYE_PASSWORD) is required."
  validate_hostname "$TARGET_HOSTNAME" || die "Invalid hostname: '${TARGET_HOSTNAME}'."

  case "$THEME" in
    catppuccin|tokyo-night|gruvbox) ;;
    *) die "Unsupported theme '${THEME}'. Expected catppuccin, tokyo-night, or gruvbox." ;;
  esac

  case "$BROWSER" in
    firefox|chromium|skip) ;;
    *) die "Unsupported browser '${BROWSER}'. Expected firefox, chromium, or skip." ;;
  esac
}

show_summary_and_confirm() {
  local disk_desc="$TARGET_DISK"
  if [[ -b "$TARGET_DISK" ]]; then
    local d_size d_model
    d_size="$(lsblk -ndo SIZE "$TARGET_DISK" 2>/dev/null || true)"
    d_model="$(lsblk -ndo MODEL "$TARGET_DISK" 2>/dev/null | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' || true)"
    d_model="${d_model//|/ }"
    [[ -n "$d_size" ]] && disk_desc="${TARGET_DISK} (${d_size}${d_model:+, $d_model})"
  fi

  local luks_desc="Disabled"
  local login_desc="tuigreet Greeter"
  if [[ "$USE_LUKS" == "1" ]]; then
    luks_desc="LUKS2 (argon2id)"
    login_desc="Autologin (unlocked at boot)"
  fi

  local summary_rows
  summary_rows="$(cat <<EOF
Setting|Value
Target Disk|${disk_desc//|/ }
Filesystem|Btrfs (@ @home @log @pkg @.snapshots) + 1 GiB FAT32 ESP
Encryption|${luks_desc}
Bootloader|${BOOTLOADER}
Login Mode|${login_desc}
Keyboard Layout|${KEYMAP//|/ }
Timezone|${TIMEZONE//|/ }
Username|${TARGET_USER//|/ }
Hostname|${TARGET_HOSTNAME//|/ }
Theme|${THEME}
Default Browser|${BROWSER}
EOF
)"

  printf '\n'
  if has_gum && is_tty; then
    gum style --foreground "$CLR_ACCENT" --bold "Installation Summary"
    printf '%s\n' "$summary_rows" | gum table --print --separator "|" --border rounded --border.foreground "$CLR_ACCENT"
  else
    printf '=== Installation Summary ===\n'
    printf '%s\n' "$summary_rows" | awk -F'|' 'NR>1 {printf "  %-18s: %s\n", $1, $2}'
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    local autologin="0"
    [[ "$USE_LUKS" == "1" ]] && autologin="1"
    local efi_p root_p hooks cmdline
    efi_p="$(partition_path "$TARGET_DISK" 1)"
    root_p="$(partition_path "$TARGET_DISK" 2)"
    if [[ "$USE_LUKS" == "1" ]]; then
      hooks="systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck"
      cmdline="rd.luks.name=<LUKS_UUID>=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3"
    else
      hooks="systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck"
      cmdline="root=UUID=<ROOT_UUID> rootflags=subvol=@ rw quiet splash loglevel=3"
    fi
    printf '\n[DRY RUN] Resolved installation plan (no changes made):\n'
    printf '  EFI Partition : %s (1 GiB FAT32 -> /boot)\n' "$efi_p"
    printf '  Root Partition: %s (%s)\n' "$root_p" "$luks_desc"
    printf '  mkinitcpio    : HOOKS=(%s)\n' "$hooks"
    printf '  Kernel Cmdline: %s\n' "$cmdline"
    printf '  Track 1 Env   : KAYE_CHROOT=1 KAYE_NONINTERACTIVE=1 KAYE_THEME=%s KAYE_BROWSER=%s KAYE_AUTOLOGIN=%s KAYE_LOG_FILE=/var/log/kaye-install.log\n' \
      "$THEME" "$BROWSER" "$autologin"
    return 0
  fi

  if [[ "$UNATTENDED" -eq 1 ]]; then
    if [[ "$CONFIRM_WIPE" != "1" && -z "$CIDATA_TMP_CFG" ]]; then
      die "Unattended install requires KAYE_CONFIRM_WIPE=yes in config file to authorize wiping ${TARGET_DISK}."
    fi
    ui_warn "Unattended mode active — proceeding to wipe ${TARGET_DISK} in 5 seconds (Ctrl+C to abort)..."
    sleep 5
    return 0
  fi

  printf '\n'
  if has_gum && is_tty; then
    gum style \
      --foreground "$CLR_RED" \
      --border double \
      --border-foreground "$CLR_RED" \
      --padding "0 2" \
      --bold \
      "WARNING: ALL DATA ON ${TARGET_DISK} WILL BE PERMANENTLY DESTROYED!"
    if ! gum confirm --default=false \
      --affirmative="Yes, wipe ${TARGET_DISK} and install" \
      --negative="Abort" \
      "Proceed with wiping ${TARGET_DISK} and installing Kaye OS?"; then
      ui_warn "Installation cancelled by user. No changes were made."
      exit 0
    fi
  else
    printf 'WARNING: ALL DATA ON %s WILL BE PERMANENTLY DESTROYED!\n' "$TARGET_DISK"
    printf 'Type WIPE to continue: '
    local ans
    read -r ans
    if [[ "$ans" != "WIPE" ]]; then
      ui_warn "Installation cancelled by user. No changes were made."
      exit 0
    fi
  fi
}

# -----------------------------------------------------------------------------
# Automated Arch Linux Provisioning Steps
# -----------------------------------------------------------------------------

step_partition_disk() {
  ui_step 1 8 "Partitioning ${TARGET_DISK} (GPT + 1 GiB EFI + Linux Root)"

  # Refuse if any partition on TARGET_DISK is currently mounted
  local mounted_parts
  mounted_parts="$(lsblk -nr -o MOUNTPOINT "$TARGET_DISK" 2>/dev/null | grep -v '^$' || true)"
  if [[ -n "$mounted_parts" ]]; then
    die "Target disk ${TARGET_DISK} has mounted partition(s): ${mounted_parts}. Unmount them first."
  fi

  if [[ -e /dev/mapper/cryptroot ]]; then
    cryptsetup close cryptroot 2>/dev/null || die "/dev/mapper/cryptroot is already active and busy."
  fi

  wipefs -af "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1
  sgdisk --zap-all "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1
  sgdisk --clear "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1
  sgdisk --new=1:0:+1G --typecode=1:ef00 --change-name=1:"EFI" "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1
  sgdisk --new=2:0:0   --typecode=2:8300 --change-name=2:"KAYE" "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1

  partprobe "$TARGET_DISK" >>"$INSTALL_LOG" 2>&1 || true
  udevadm settle --timeout=10 2>/dev/null || sleep 2

  EFI_PART="$(partition_path "$TARGET_DISK" 1)"
  ROOT_PART="$(partition_path "$TARGET_DISK" 2)"

  local tries=0
  while [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; do
    tries=$((tries + 1))
    [[ $tries -le 20 ]] || die "Partition devices did not appear: ${EFI_PART}, ${ROOT_PART}"
    sleep 0.5
  done

  wipefs -af "$EFI_PART" >>"$INSTALL_LOG" 2>&1 || true
  wipefs -af "$ROOT_PART" >>"$INSTALL_LOG" 2>&1 || true
  ui_ok "Created GPT partitions: ${EFI_PART} (EFI), ${ROOT_PART} (Root)"
}

step_format_and_mount() {
  ui_step 2 8 "Formatting EFI, Encryption (LUKS2), and Btrfs Subvolumes"

  mkfs.fat -F 32 -n EFI "$EFI_PART" >>"$INSTALL_LOG" 2>&1

  if [[ "$USE_LUKS" == "1" ]]; then
    ui_info "Creating LUKS2 volume (argon2id) on ${ROOT_PART}..."
    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat \
      --batch-mode \
      --type luks2 \
      --pbkdf argon2id \
      --cipher aes-xts-plain64 \
      --key-size 512 \
      --hash sha512 \
      --label KAYE_CRYPT \
      --key-file - \
      "$ROOT_PART" >>"$INSTALL_LOG" 2>&1

    printf '%s' "$LUKS_PASSPHRASE" | cryptsetup open \
      --key-file - \
      "$ROOT_PART" cryptroot >>"$INSTALL_LOG" 2>&1

    LUKS_OPENED=1
    BTRFS_DEV="/dev/mapper/cryptroot"
    LUKS_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
    [[ -n "$LUKS_UUID" ]] || die "Failed to read LUKS UUID from ${ROOT_PART}"
    ui_ok "LUKS2 encrypted container opened at ${BTRFS_DEV}"
  else
    BTRFS_DEV="$ROOT_PART"
  fi

  ui_info "Formatting Btrfs filesystem and creating subvolumes..."
  mkfs.btrfs -f -L KAYE "$BTRFS_DEV" >>"$INSTALL_LOG" 2>&1

  mount "$BTRFS_DEV" /mnt
  btrfs subvolume create /mnt/@ >>"$INSTALL_LOG" 2>&1
  btrfs subvolume create /mnt/@home >>"$INSTALL_LOG" 2>&1
  btrfs subvolume create /mnt/@log >>"$INSTALL_LOG" 2>&1
  btrfs subvolume create /mnt/@pkg >>"$INSTALL_LOG" 2>&1
  btrfs subvolume create /mnt/@.snapshots >>"$INSTALL_LOG" 2>&1
  umount /mnt

  local btrfs_opts="rw,noatime,compress=zstd"
  mount -o "${btrfs_opts},subvol=@" "$BTRFS_DEV" /mnt
  MOUNTED=1

  mkdir -p /mnt/boot /mnt/home /mnt/var/log /mnt/var/cache/pacman/pkg /mnt/.snapshots
  mount -o "${btrfs_opts},subvol=@home" "$BTRFS_DEV" /mnt/home
  mount -o "${btrfs_opts},subvol=@log" "$BTRFS_DEV" /mnt/var/log
  mount -o "${btrfs_opts},subvol=@pkg" "$BTRFS_DEV" /mnt/var/cache/pacman/pkg
  mount -o "${btrfs_opts},subvol=@.snapshots" "$BTRFS_DEV" /mnt/.snapshots
  mount -o umask=0077 "$EFI_PART" /mnt/boot

  ROOT_UUID="$(blkid -s UUID -o value "$BTRFS_DEV")"
  [[ -n "$ROOT_UUID" ]] || die "Failed to read Btrfs root UUID from ${BTRFS_DEV}"
  ui_ok "Mounted Btrfs subvolumes (@, @home, @log, @pkg, @.snapshots) and ESP at /mnt/boot"
}

detect_microcode_pkg() {
  if grep -q 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
    printf 'amd-ucode\n'
  elif grep -q 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
    printf 'intel-ucode\n'
  fi
}

step_pacstrap() {
  ui_step 3 8 "Installing Arch Linux Base System (pacstrap)"

  local -a pkgs=(
    base
    linux
    linux-firmware
    btrfs-progs
    dosfstools
    git
    sudo
    networkmanager
    efibootmgr
  )

  local ucode
  ucode="$(detect_microcode_pkg || true)"
  [[ -n "$ucode" ]] && pkgs+=("$ucode")

  if [[ "$USE_LUKS" == "1" ]]; then
    pkgs+=(cryptsetup)
  fi
  if [[ "$BOOTLOADER" == "limine" ]]; then
    pkgs+=(limine)
  fi

  ui_info "Packages: ${pkgs[*]}"
  pacstrap -K /mnt "${pkgs[@]}" 2>&1 | tee -a "$INSTALL_LOG"
  ui_ok "Base Arch Linux system installed"
}

step_genfstab() {
  ui_step 4 8 "Generating /etc/fstab"
  genfstab -U /mnt >>/mnt/etc/fstab
  # Strip subvolid=<N> so Snapper Btrfs rollbacks work seamlessly
  sed -i -E 's/subvolid=[0-9]+,//g; s/,subvolid=[0-9]+//g' /mnt/etc/fstab
  ui_ok "Generated /mnt/etc/fstab (UUID-based, Snapper-compatible)"
}

step_configure_base_system() {
  ui_step 5 8 "Configuring System Base, User Account, and Initramfs"

  # Timezone & hardware clock
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /mnt/etc/localtime
  arch-chroot /mnt hwclock --systohc

  # Locale (en_US.UTF-8)
  if grep -qE '^#?en_US\.UTF-8 UTF-8' /mnt/etc/locale.gen; then
    sed -i -E 's/^#(en_US\.UTF-8 UTF-8)/\1/' /mnt/etc/locale.gen
  else
    printf 'en_US.UTF-8 UTF-8\n' >>/mnt/etc/locale.gen
  fi
  arch-chroot /mnt locale-gen >>"$INSTALL_LOG" 2>&1
  printf 'LANG=en_US.UTF-8\n' >/mnt/etc/locale.conf

  # Console keymap (read by sd-vconsole hook)
  printf 'KEYMAP=%s\n' "$KEYMAP" >/mnt/etc/vconsole.conf

  # Hostname & /etc/hosts
  printf '%s\n' "$TARGET_HOSTNAME" >/mnt/etc/hostname
  cat >/mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}
EOF

  # User creation, passwords, and wheel sudoers
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$TARGET_USER"
  printf '%s:%s\n' "$TARGET_USER" "$USER_PASSWORD" | arch-chroot /mnt chpasswd
  printf 'root:%s\n' "$ROOT_PASSWORD" | arch-chroot /mnt chpasswd

  cat >/mnt/etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
  chmod 0440 /mnt/etc/sudoers.d/10-wheel
  arch-chroot /mnt visudo -cf /etc/sudoers.d/10-wheel >>"$INSTALL_LOG" 2>&1

  # Enable NetworkManager so the installed system has networking out of the box
  arch-chroot /mnt systemctl enable NetworkManager.service >>"$INSTALL_LOG" 2>&1

  # Configure systemd-based mkinitcpio hooks directly in /etc/mkinitcpio.conf
  # (so Track 1's 04-boot-and-plymouth.sh can cleanly insert 'plymouth' into HOOKS)
  local hooks_line
  if [[ "$USE_LUKS" == "1" ]]; then
    hooks_line="HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)"
  else
    hooks_line="HOOKS=(systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)"
  fi

  if grep -qE '^[[:space:]]*HOOKS=' /mnt/etc/mkinitcpio.conf; then
    sed -i -E "s|^[[:space:]]*HOOKS=.*|${hooks_line}|" /mnt/etc/mkinitcpio.conf
  else
    printf '\n%s\n' "$hooks_line" >>/mnt/etc/mkinitcpio.conf
  fi

  ui_info "Building initial initramfs (mkinitcpio -P)..."
  arch-chroot /mnt mkinitcpio -P 2>&1 | tee -a "$INSTALL_LOG"
  ui_ok "Base system, user '${TARGET_USER}', and initramfs configured"
}

step_install_bootloader() {
  ui_step 6 8 "Installing Bootloader (${BOOTLOADER})"

  if [[ "$USE_LUKS" == "1" ]]; then
    KERNEL_CMDLINE="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet splash loglevel=3"
  else
    KERNEL_CMDLINE="root=UUID=${ROOT_UUID} rootflags=subvol=@ rw quiet splash loglevel=3"
  fi

  if [[ "$BOOTLOADER" == "limine" ]]; then
    mkdir -p /mnt/boot/EFI/BOOT /mnt/boot/EFI/limine
    cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/BOOTX64.EFI
    cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/limine/BOOTX64.EFI

    # Remove stale Kaye OS NVRAM boot entries (best-effort; UEFI fallback path still boots)
    local bootnum
    while IFS= read -r bootnum; do
      [[ -n "$bootnum" ]] && efibootmgr --delete-bootnum --bootnum "$bootnum" >>"$INSTALL_LOG" 2>&1 || true
    done < <(efibootmgr 2>/dev/null | awk '/^Boot[0-9A-Fa-f]{4}.*Kaye OS/ {gsub(/^Boot|\*.*$/, "", $1); print $1}' || true)

    efibootmgr --create \
      --disk "$TARGET_DISK" \
      --part 1 \
      --label "Kaye OS" \
      --loader '\EFI\limine\BOOTX64.EFI' \
      --unicode >>"$INSTALL_LOG" 2>&1 \
      || ui_warn "Could not register UEFI NVRAM entry (EFI/BOOT/BOOTX64.EFI fallback is installed)."

    cat >/mnt/boot/limine.conf <<EOF
# Kaye OS — Limine Bootloader Configuration
timeout: 3
quiet: no
default_entry: 1
interface_branding: Kaye OS
interface_branding_colour: 89b4fa
interface_help_colour: 6c7086
term_background: 001e1e2e
term_foreground: cdd6f4
term_background_bright: 313244
term_foreground_bright: ffffff
term_palette: 1e1e2e;f38ba8;a6e3a1;f9e2af;89b4fa;cba6f7;94e2d5;cdd6f4
term_palette_bright: 585b70;f38ba8;a6e3a1;f9e2af;89b4fa;cba6f7;94e2d5;ffffff

/Kaye OS
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: ${KERNEL_CMDLINE}
    module_path: boot():/initramfs-linux.img

/Kaye OS (Fallback)
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: ${KERNEL_CMDLINE}
    module_path: boot():/initramfs-linux-fallback.img
EOF
    ui_ok "Installed Limine UEFI bootloader with Kaye OS branding (/boot/limine.conf)"
  else
    arch-chroot /mnt bootctl install >>"$INSTALL_LOG" 2>&1

    cat >/mnt/boot/loader/loader.conf <<'EOF'
default  kaye.conf
timeout  3
console-mode max
editor   no
EOF

    mkdir -p /mnt/boot/loader/entries
    cat >/mnt/boot/loader/entries/kaye.conf <<EOF
title   Kaye OS
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options ${KERNEL_CMDLINE}
EOF

    cat >/mnt/boot/loader/entries/kaye-fallback.conf <<EOF
title   Kaye OS (Fallback)
linux   /vmlinuz-linux
initrd  /initramfs-linux-fallback.img
options ${KERNEL_CMDLINE}
EOF
    ui_ok "Installed systemd-boot with Kaye OS entries (/boot/loader/entries/kaye.conf)"
  fi
}

resolve_local_kaye_source() {
  if [[ -n "$SOURCE_OVERRIDE" ]]; then
    [[ -f "$SOURCE_OVERRIDE/install/all.sh" ]] || die "--source directory missing install/all.sh: $SOURCE_OVERRIDE"
    printf '%s\n' "$SOURCE_OVERRIDE"
    return 0
  fi
  if [[ -f "/opt/kaye/install/all.sh" ]]; then
    printf '/opt/kaye\n'
    return 0
  fi
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/install/all.sh" ]]; then
    printf '%s\n' "$SCRIPT_DIR"
    return 0
  fi
  return 1
}

step_install_kaye_desktop() {
  ui_step 7 8 "Installing Kaye OS Desktop Environment inside Chroot"

  local target_kaye_dir="/mnt/home/${TARGET_USER}/kaye"
  local local_src=""
  if local_src="$(resolve_local_kaye_source)"; then
    ui_info "Copying bundled Kaye OS repository from ${local_src}..."
    mkdir -p "$target_kaye_dir"
    tar -C "$local_src" \
      --exclude='./.git' \
      --exclude='./core/target' \
      --exclude='./iso/out' \
      --exclude='./iso/work' \
      --exclude='*.bak' \
      --exclude='*.tmp' \
      -cf - . | tar -C "$target_kaye_dir" -xf -
  else
    ui_info "Cloning Kaye OS (${KAYE_REPO} @ ${KAYE_REF})..."
    arch-chroot /mnt sudo -u "$TARGET_USER" \
      git clone --branch "$KAYE_REF" "$KAYE_REPO" "/home/${TARGET_USER}/kaye" 2>&1 | tee -a "$INSTALL_LOG"
  fi

  arch-chroot /mnt chown -R "${TARGET_USER}:${TARGET_USER}" "/home/${TARGET_USER}/kaye"
  chmod +x "$target_kaye_dir"/install/*.sh 2>/dev/null || true

  # Pre-create chroot install log writable by TARGET_USER
  touch /mnt/var/log/kaye-install.log
  arch-chroot /mnt chown "${TARGET_USER}:${TARGET_USER}" /var/log/kaye-install.log

  # Temporary passwordless sudo for non-interactive Track 1 execution (always removed by trap)
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$TARGET_USER" >"$SUDOERS_TMP"
  chmod 0440 "$SUDOERS_TMP"
  arch-chroot /mnt visudo -cf /etc/sudoers.d/99-kaye-install >>"$INSTALL_LOG" 2>&1

  local autologin="0"
  [[ "$USE_LUKS" == "1" ]] && autologin="1"

  ui_info "Running Kaye OS installer (theme=${THEME}, browser=${BROWSER}, autologin=${autologin})..."
  arch-chroot /mnt sudo -u "$TARGET_USER" -H env \
    HOME="/home/${TARGET_USER}" \
    USER="$TARGET_USER" \
    LOGNAME="$TARGET_USER" \
    KAYE_CHROOT=1 \
    KAYE_NONINTERACTIVE=1 \
    KAYE_THEME="$THEME" \
    KAYE_BROWSER="$BROWSER" \
    KAYE_AUTOLOGIN="$autologin" \
    KAYE_LOG_FILE="/var/log/kaye-install.log" \
    bash "/home/${TARGET_USER}/kaye/install/all.sh"

  # Immediately remove temporary NOPASSWD sudoers file
  rm -f "$SUDOERS_TMP"
  ui_ok "Kaye OS desktop installation completed inside chroot"
}

step_finalize_and_unmount() {
  ui_step 8 8 "Finalizing Installation & Unmounting"

  # Preserve live-ISO install log on the installed target system
  if [[ -f "$INSTALL_LOG" ]]; then
    cp "$INSTALL_LOG" /mnt/var/log/kaye-arch-install.log 2>/dev/null || true
  fi

  sync
  umount -R /mnt
  MOUNTED=0

  if [[ "$USE_LUKS" == "1" && "$LUKS_OPENED" -eq 1 ]]; then
    cryptsetup close cryptroot
    LUKS_OPENED=0
  fi

  ui_ok "All filesystems cleanly unmounted"

  printf '\n'
  if has_gum && is_tty; then
    gum style \
      --foreground "$CLR_GREEN" \
      --border rounded \
      --border-foreground "$CLR_GREEN" \
      --padding "1 3" \
      --bold \
      "Kaye OS installation complete!" \
      "" \
      "Remove the installation media before rebooting." \
      "Logs saved to /var/log/kaye-arch-install.log and /var/log/kaye-install.log."
  else
    printf '====================================================\n'
    printf '  Kaye OS installation complete!\n'
    printf '  Remove the installation media before rebooting.\n'
    printf '====================================================\n'
  fi

  if [[ "$AUTO_REBOOT" == "1" ]]; then
    ui_info "Auto-reboot enabled — rebooting in 5 seconds..."
    sleep 5
    reboot
  elif [[ "$UNATTENDED" -eq 0 ]] && is_tty; then
    if has_gum; then
      if gum confirm --default=true "Reboot into Kaye OS now?"; then
        reboot
      fi
    else
      printf 'Reboot into Kaye OS now? [Y/n]: '
      local ans
      read -r ans
      if [[ -z "$ans" || "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
        reboot
      fi
    fi
  fi
}

# -----------------------------------------------------------------------------
# Main Entrypoint
# -----------------------------------------------------------------------------

main() {
  parse_args "$@"

  # Auto-detect LABEL=cidata drive if no explicit --config was passed
  detect_cidata_config

  # Load config file if specified or auto-detected
  if [[ -n "$CONFIG_FILE" ]]; then
    load_config_file "$CONFIG_FILE"
  fi

  # TTY-safe handoff when piped (e.g. curl ... | bash) in interactive mode
  if [[ "$UNATTENDED" -eq 0 && "$DRY_RUN" -eq 0 && ! -t 0 ]]; then
    if [[ -r /dev/tty ]]; then
      exec </dev/tty
    else
      die "No interactive TTY available. Pass --config <file> --unattended for non-interactive installs."
    fi
  fi

  # Initialize log file (best-effort if non-root dry-run)
  if [[ -w "$(dirname "$INSTALL_LOG")" || -w "$INSTALL_LOG" ]]; then
    : >"$INSTALL_LOG" 2>/dev/null || true
    chmod 0600 "$INSTALL_LOG" 2>/dev/null || true
  fi

  preflight_checks

  if [[ "$UNATTENDED" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    run_interactive_wizard
  fi

  apply_defaults_and_validate

  if [[ "$DRY_RUN" -eq 0 ]]; then
    check_live_tools
  fi

  show_summary_and_confirm

  if [[ "$DRY_RUN" -eq 1 ]]; then
    exit 0
  fi

  step_partition_disk
  step_format_and_mount
  step_pacstrap
  step_genfstab
  step_configure_base_system
  step_install_bootloader
  step_install_kaye_desktop
  step_finalize_and_unmount

  # Explicit exit guarantees bash never reads further stdin after exec </dev/tty
  exit 0
}

main "$@"
