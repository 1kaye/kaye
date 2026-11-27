#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_KAYE_LOGGING_LOADED:-}" ]]; then
  return 0
fi
_KAYE_LOGGING_LOADED=1

kaye_timestamp() {
  printf '%(%Y-%m-%d %H:%M:%S)T' -1
}

kaye_is_chroot() {
  if [[ -n "${KAYE_CHROOT:-}" ]]; then
    [[ "$KAYE_CHROOT" == "1" ]]
    return
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -r >/dev/null 2>&1; then
    export KAYE_CHROOT=1
    return 0
  fi

  export KAYE_CHROOT=0
  return 1
}

kaye_is_luks_root() {
  local root_src root_dev
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_dev="${root_src%%\[*}"

  if [[ -z "$root_dev" ]]; then
    return 1
  fi

  if command -v lsblk >/dev/null 2>&1; then
    if lsblk -s -no TYPE "$root_dev" 2>/dev/null | grep -qx 'crypt'; then
      return 0
    fi
  fi

  if [[ "$root_dev" == /dev/mapper/* ]] && command -v cryptsetup >/dev/null 2>&1; then
    if cryptsetup status "${root_dev##*/}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

kaye_resolve_log_file() {
  if [[ -n "${KAYE_LOG_FILE:-}" ]]; then
    printf '%s\n' "$KAYE_LOG_FILE"
    return 0
  fi

  if [[ -n "${KAYE_INSTALL_LOG:-}" ]]; then
    printf '%s\n' "$KAYE_INSTALL_LOG"
    return 0
  fi

  if kaye_is_chroot; then
    printf '%s\n' "/var/log/kaye-install.log"
  else
    printf '%s\n' "$HOME/.local/state/kaye/install.log"
  fi
}

kaye_log_init() {
  local requested_log log_dir
  requested_log="$(kaye_resolve_log_file)"
  log_dir="$(dirname "$requested_log")"

  if mkdir -p "$log_dir" 2>/dev/null && touch "$requested_log" 2>/dev/null; then
    export KAYE_LOG_FILE="$requested_log"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && \
    sudo mkdir -p "$log_dir" 2>/dev/null && \
    sudo touch "$requested_log" 2>/dev/null && \
    sudo chmod 666 "$requested_log" 2>/dev/null; then
    export KAYE_LOG_FILE="$requested_log"
  else
    export KAYE_LOG_FILE="$HOME/.local/state/kaye/install.log"
    mkdir -p "$(dirname "$KAYE_LOG_FILE")"
    touch "$KAYE_LOG_FILE"
  fi

  export KAYE_INSTALL_LOG="$KAYE_LOG_FILE"
  export KAYE_INSTALL_START_EPOCH="${KAYE_INSTALL_START_EPOCH:-$EPOCHSECONDS}"

  if [[ "${_KAYE_LOG_HEADER_WRITTEN:-0}" != "1" ]]; then
    _KAYE_LOG_HEADER_WRITTEN=1
    printf '[%s] === Kaye OS Install Started (chroot=%s, user=%s) ===\n' \
      "$(kaye_timestamp)" "${KAYE_CHROOT:-0}" "$(id -un)" >>"$KAYE_LOG_FILE"
  fi
}

kaye_log_write() {
  local level="$1"
  shift
  local msg="$*"
  local line
  line="[$(kaye_timestamp)] [$level] $msg"
  if [[ -n "${KAYE_LOG_FILE:-}" ]] && [[ -w "$KAYE_LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$KAYE_LOG_FILE"
  fi
}

kaye_log_info() {
  kaye_log_write "INFO" "$*"
}

kaye_log_warn() {
  kaye_log_write "WARN" "$*"
}

kaye_log_error() {
  kaye_log_write "ERROR" "$*"
}

kaye_log_finish() {
  local end_epoch duration mins secs
  end_epoch="$EPOCHSECONDS"
  if [[ -n "${KAYE_INSTALL_START_EPOCH:-}" ]]; then
    duration=$((end_epoch - KAYE_INSTALL_START_EPOCH))
    mins=$((duration / 60))
    secs=$((duration % 60))
    kaye_log_write "INFO" "=== Kaye OS Install Completed in ${mins}m ${secs}s ==="
  else
    kaye_log_write "INFO" "=== Kaye OS Install Completed ==="
  fi
}

kaye_sudo_keepalive_start() {
  if (( EUID == 0 )) || ! command -v sudo >/dev/null 2>&1; then
    return 0
  fi

  if ! sudo -n true 2>/dev/null; then
    if [[ "${KAYE_NONINTERACTIVE:-0}" != "1" ]] && [[ ! -t 0 ]] && [[ -r /dev/tty ]]; then
      sudo -v </dev/tty
    else
      sudo -v
    fi
  fi

  local parent_pid="$$"
  (
    while kill -0 "$parent_pid" 2>/dev/null; do
      sudo -n true 2>/dev/null || exit 0
      sleep 50
    done
  ) &
  KAYE_SUDO_KEEPALIVE_PID="$!"
  export KAYE_SUDO_KEEPALIVE_PID
}

kaye_sudo_keepalive_stop() {
  if [[ -n "${KAYE_SUDO_KEEPALIVE_PID:-}" ]]; then
    kill "$KAYE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$KAYE_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    unset KAYE_SUDO_KEEPALIVE_PID
  fi
}

kaye_err_trap_handler() {
  local exit_code="$1"
  local failed_file="$2"
  local failed_line="$3"
  local failed_cmd="$4"

  trap - ERR

  # If orchestrated by all.sh, preserve the exact inner script/line/command.
  if [[ "${KAYE_ERR_TOP_LEVEL:-0}" == "1" ]] && [[ -n "${KAYE_ERR_STATE_FILE:-}" ]] && [[ -s "$KAYE_ERR_STATE_FILE" ]]; then
    local saved_file="" saved_line="" saved_code="" saved_cmd=""
    IFS=$'\t' read -r saved_file saved_line saved_code saved_cmd <"$KAYE_ERR_STATE_FILE" || true
    if [[ -n "$saved_file" ]]; then
      failed_file="$saved_file"
      failed_line="$saved_line"
      exit_code="${saved_code:-$exit_code}"
      failed_cmd="${saved_cmd:-$failed_cmd}"
    fi
  elif [[ -n "${KAYE_ERR_STATE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$failed_file" "$failed_line" "$exit_code" "$failed_cmd" >"$KAYE_ERR_STATE_FILE" 2>/dev/null || true
  fi

  kaye_log_error "Failed at ${failed_file}:${failed_line} (exit ${exit_code}): ${failed_cmd}"

  # When running inside all.sh as a child step, let all.sh render the error box once.
  if [[ "${KAYE_IN_ALL_SH:-0}" == "1" ]] && [[ "${KAYE_ERR_TOP_LEVEL:-0}" != "1" ]]; then
    exit "$exit_code"
  fi

  local resume_cmd
  if [[ -n "${KAYE_PATH:-}" ]]; then
    resume_cmd="bash ${KAYE_PATH}/install/all.sh"
  else
    resume_cmd="bash ~/kaye/install/all.sh"
  fi

  if declare -F kaye_ui_error_box >/dev/null 2>&1; then
    kaye_ui_error_box "$failed_file" "$failed_line" "$exit_code" "$failed_cmd" "${KAYE_LOG_FILE:-}" "$resume_cmd"
  else
    {
      echo
      echo "============================================================"
      echo "  Kaye OS Installer Failed"
      echo "============================================================"
      echo "  Script  : $failed_file"
      echo "  Line    : $failed_line"
      echo "  Exit    : $exit_code"
      echo "  Command : $failed_cmd"
      if [[ -n "${KAYE_LOG_FILE:-}" ]] && [[ -f "$KAYE_LOG_FILE" ]]; then
        echo "  Log     : $KAYE_LOG_FILE"
        echo
        echo "--- Last 25 lines of $KAYE_LOG_FILE ---"
        tail -n 25 "$KAYE_LOG_FILE" || true
        echo "------------------------------------------------------------"
      fi
      echo "  Resume  : $resume_cmd"
      echo "============================================================"
    } >&2
  fi

  exit "$exit_code"
}

kaye_enable_err_trap() {
  set -E
  trap 'kaye_err_trap_handler "$?" "${BASH_SOURCE[0]:-$0}" "$LINENO" "$BASH_COMMAND"' ERR
}

kaye_run_step() {
  local step_num="$1"
  local total_steps="$2"
  local label="$3"
  local script_path="$4"
  local rc=0

  if [[ -n "${KAYE_ERR_STATE_FILE:-}" ]]; then
    : >"$KAYE_ERR_STATE_FILE"
  fi

  kaye_log_info "[$step_num/$total_steps] Starting $(basename "$script_path") — $label"

  if declare -F kaye_ui_spin >/dev/null 2>&1 && declare -F kaye_has_gum_tty >/dev/null 2>&1 && kaye_has_gum_tty && [[ "${KAYE_VERBOSE:-0}" != "1" ]]; then
    kaye_ui_spin "[$step_num/$total_steps] $label" bash -c 'bash "$1" </dev/null >>"$2" 2>&1' _ "$script_path" "$KAYE_LOG_FILE" || rc=$?
  else
    printf '==> [%s/%s] %s\n' "$step_num" "$total_steps" "$label"
    if [[ "${KAYE_VERBOSE:-0}" == "1" ]]; then
      bash "$script_path" </dev/null 2>&1 | tee -a "$KAYE_LOG_FILE" || rc="${PIPESTATUS[0]}"
    else
      bash "$script_path" </dev/null >>"$KAYE_LOG_FILE" 2>&1 || rc=$?
    fi
  fi

  if (( rc == 0 )); then
    kaye_log_info "[$step_num/$total_steps] Completed $(basename "$script_path")"
    if declare -F kaye_ui_ok >/dev/null 2>&1; then
      kaye_ui_ok "[$step_num/$total_steps] $label"
    fi
    return 0
  fi

  kaye_log_error "[$step_num/$total_steps] Failed $(basename "$script_path") (exit $rc)"
  return "$rc"
}
