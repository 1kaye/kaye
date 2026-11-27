#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
# shellcheck source=install/lib/ui.sh
source "$KAYE_DIR/install/lib/ui.sh"

if (( EUID == 0 )); then
  kaye_ui_error "Do not run install/all.sh as root. Run as your regular user with sudo privileges."
  exit 1
fi

if [[ ! -f /etc/arch-release ]] || ! command -v pacman >/dev/null 2>&1; then
  kaye_ui_error "Kaye OS requires Arch Linux."
  exit 1
fi

# Resolve chroot mode and canonical environment contract.
kaye_is_chroot || true
export KAYE_CHROOT

if [[ -z "${KAYE_NONINTERACTIVE:-}" ]]; then
  if [[ "$KAYE_CHROOT" == "1" ]] || [[ ! -t 0 ]]; then
    KAYE_NONINTERACTIVE=1
  else
    KAYE_NONINTERACTIVE=0
  fi
fi
export KAYE_NONINTERACTIVE

KAYE_THEME="${KAYE_THEME:-catppuccin}"
KAYE_BROWSER="${KAYE_BROWSER:-firefox}"
KAYE_AUTOLOGIN="${KAYE_AUTOLOGIN:-auto}"

# Validate environment overrides early.
case "$KAYE_THEME" in
  catppuccin | tokyo-night | gruvbox) ;;
  *)
    kaye_ui_error "Invalid KAYE_THEME '$KAYE_THEME' (expected: catppuccin, tokyo-night, gruvbox)."
    exit 1
    ;;
esac

case "$KAYE_BROWSER" in
  firefox | chromium | skip) ;;
  *)
    kaye_ui_error "Invalid KAYE_BROWSER '$KAYE_BROWSER' (expected: firefox, chromium, skip)."
    exit 1
    ;;
esac

case "$KAYE_AUTOLOGIN" in
  1 | 0 | auto) ;;
  *)
    kaye_ui_error "Invalid KAYE_AUTOLOGIN '$KAYE_AUTOLOGIN' (expected: 1, 0, auto)."
    exit 1
    ;;
esac

# Detect LUKS root so the wizard can show the recommended login mode.
LUKS_ROOT_DETECTED=0
if kaye_is_luks_root; then
  LUKS_ROOT_DETECTED=1
fi

describe_login_mode() {
  case "$1" in
    1) printf 'greetd autologin -> Hyprland (UWSM)' ;;
    0) printf 'greetd + tuigreet greeter -> Hyprland (UWSM)' ;;
    auto)
      if (( LUKS_ROOT_DETECTED == 1 )); then
        printf 'Auto -> greetd autologin (LUKS detected)'
      else
        printf 'Auto -> greetd + tuigreet greeter'
      fi
      ;;
  esac
}

# Interactive pre-flight wizard (skipped when KAYE_NONINTERACTIVE=1).
if [[ "$KAYE_NONINTERACTIVE" != "1" ]]; then
  kaye_ui_banner "Kaye OS Installer (Arch Linux + Hyprland + Quickshell + Rust)"

  KAYE_THEME="$(kaye_ui_choose "Select Kaye OS Theme" "$KAYE_THEME" \
    "catppuccin" \
    "tokyo-night" \
    "gruvbox")"

  KAYE_BROWSER="$(kaye_ui_choose "Select Default Web Browser" "$KAYE_BROWSER" \
    "firefox" \
    "chromium" \
    "skip")"

  auto_label="auto — Recommended (tuigreet greeter)"
  if (( LUKS_ROOT_DETECTED == 1 )); then
    auto_label="auto — Recommended (LUKS autologin)"
  fi
  autologin_label="autologin — Always log straight into Hyprland"
  greeter_label="greeter — Always show tuigreet login prompt"

  default_login_label="$auto_label"
  case "$KAYE_AUTOLOGIN" in
    1) default_login_label="$autologin_label" ;;
    0) default_login_label="$greeter_label" ;;
  esac

  chosen_login="$(kaye_ui_choose "Select Session Login Mode (greetd + UWSM)" "$default_login_label" \
    "$auto_label" \
    "$autologin_label" \
    "$greeter_label")"

  case "$chosen_login" in
    autologin*) KAYE_AUTOLOGIN="1" ;;
    greeter*) KAYE_AUTOLOGIN="0" ;;
    *) KAYE_AUTOLOGIN="auto" ;;
  esac

  env_mode="Live system"
  [[ "$KAYE_CHROOT" == "1" ]] && env_mode="Chroot"

  resolved_log="$(kaye_resolve_log_file)"

  kaye_ui_header "Installation Summary"
  kaye_ui_table <<EOF
Setting,Value
Theme,$KAYE_THEME
Browser,$KAYE_BROWSER
Login Mode,$(describe_login_mode "$KAYE_AUTOLOGIN")
Environment,$env_mode
Repository,$KAYE_DIR
Log File,$resolved_log
EOF
  echo

  if ! kaye_ui_confirm "Proceed with Kaye OS installation?" 1; then
    kaye_ui_warn "Installation cancelled."
    exit 0
  fi
else
  kaye_ui_banner "Kaye OS Non-Interactive Installer"
  kaye_ui_info "Theme=$KAYE_THEME  Browser=$KAYE_BROWSER  Autologin=$KAYE_AUTOLOGIN  Chroot=$KAYE_CHROOT"
fi

export KAYE_THEME KAYE_BROWSER KAYE_AUTOLOGIN

# Acquire sudo credentials and start keepalive before initializing logs and running steps.
kaye_sudo_keepalive_start
kaye_log_init

KAYE_ERR_STATE_FILE="$(mktemp "${TMPDIR:-/tmp}/kaye-err.XXXXXX")"
export KAYE_ERR_STATE_FILE
export KAYE_IN_ALL_SH=1
KAYE_ERR_TOP_LEVEL=1

cleanup() {
  kaye_sudo_keepalive_stop
  if [[ -n "${KAYE_ERR_STATE_FILE:-}" ]] && [[ -f "$KAYE_ERR_STATE_FILE" ]]; then
    rm -f "$KAYE_ERR_STATE_FILE"
  fi
}
trap cleanup EXIT
kaye_enable_err_trap

kaye_log_info "Config: theme=$KAYE_THEME browser=$KAYE_BROWSER autologin=$KAYE_AUTOLOGIN chroot=$KAYE_CHROOT repo=$KAYE_DIR"

STEPS=(
  "01-packages.sh|Installing packages, AUR tools & Rust toolchain"
  "02-services.sh|Configuring services, firewall, ZRAM, Snapper & PAM"
  "03-hardware.sh|Detecting CPU microcode, GPU drivers & early KMS"
  "04-boot-and-plymouth.sh|Configuring Plymouth boot splash & bootloader"
  "05-login.sh|Configuring greetd/tuigreet UWSM session login"
  "06-core-and-dotfiles.sh|Building Kaye CLI & installing dotfiles"
  "07-desktop-defaults.sh|Configuring GTK/Qt, portals, MIME & first-run hook"
  "08-theme.sh|Applying initial Kaye OS theme ($KAYE_THEME)"
)

TOTAL_STEPS="${#STEPS[@]}"
kaye_ui_header "Installing Kaye OS ($TOTAL_STEPS steps)"

step_index=0
for entry in "${STEPS[@]}"; do
  ((step_index++))
  script_name="${entry%%|*}"
  step_label="${entry#*|}"
  kaye_run_step "$step_index" "$TOTAL_STEPS" "$step_label" "$KAYE_DIR/install/$script_name"
done

kaye_log_finish

echo
kaye_ui_header "Kaye OS Setup Complete!"
kaye_ui_ok "Theme applied: $KAYE_THEME"
kaye_ui_ok "Login configured: $(describe_login_mode "$KAYE_AUTOLOGIN")"
kaye_ui_info "Install log saved to: $KAYE_LOG_FILE"
kaye_ui_info "Shortcuts: Super+Space = Kaye Menu, Super+Enter = Foot, Super+B = Browser"

if [[ "$KAYE_CHROOT" != "1" ]] && [[ "$KAYE_NONINTERACTIVE" != "1" ]]; then
  echo
  if kaye_ui_confirm "Reboot now to enter Kaye OS?" 0; then
    sudo systemctl reboot
  else
    kaye_ui_info "Reboot whenever you are ready to launch Kaye OS."
  fi
fi
