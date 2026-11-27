#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${_KAYE_UI_LOADED:-}" ]]; then
  return 0
fi
_KAYE_UI_LOADED=1

# Kaye OS palette (Catppuccin Mocha accents)
KAYE_COLOR_ACCENT="#89b4fa"
KAYE_COLOR_SUCCESS="#a6e3a1"
KAYE_COLOR_WARN="#f9e2af"
KAYE_COLOR_ERROR="#f38ba8"
KAYE_COLOR_MUTED="#6c7086"
KAYE_COLOR_TEXT="#cdd6f4"

kaye_has_gum_tty() {
  [[ "${KAYE_NONINTERACTIVE:-0}" != "1" ]] && [[ -t 0 && -t 1 ]] && command -v gum >/dev/null 2>&1
}

kaye_has_gum_stdout() {
  [[ -t 1 ]] && command -v gum >/dev/null 2>&1
}

kaye_ui_banner() {
  local subtitle="${1:-Kaye OS Installer — Arch Linux + Hyprland + Quickshell}"
  local logo_file="${KAYE_PATH:-}/branding/logo.txt"

  if [[ "${KAYE_NONINTERACTIVE:-0}" != "1" ]] && [[ -t 1 ]]; then
    clear || true
  fi

  if [[ -f "$logo_file" ]]; then
    if kaye_has_gum_stdout; then
      gum style --foreground "$KAYE_COLOR_ACCENT" --bold --margin "1 2 0 2" "$(cat "$logo_file")"
    else
      printf '\033[1;34m'
      cat "$logo_file"
      printf '\033[0m\n'
    fi
  fi

  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_TEXT" --margin "0 2 1 2" "$subtitle"
  else
    printf '  %s\n\n' "$subtitle"
  fi
}

kaye_ui_header() {
  local text="$1"
  if kaye_has_gum_stdout; then
    gum style \
      --foreground "$KAYE_COLOR_ACCENT" \
      --border rounded \
      --border-foreground "$KAYE_COLOR_ACCENT" \
      --padding "0 2" \
      --margin "1 0" \
      --bold \
      "$text"
  else
    printf '\n=== %s ===\n' "$text"
  fi
}

kaye_ui_step() {
  local num="$1"
  local total="$2"
  local title="$3"
  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_ACCENT" --bold "[$num/$total] $title"
  else
    printf '==> [%s/%s] %s\n' "$num" "$total" "$title"
  fi
}

kaye_ui_ok() {
  local msg="$*"
  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_SUCCESS" "✓ $msg"
  else
    printf '[ok] %s\n' "$msg"
  fi
}

kaye_ui_info() {
  local msg="$*"
  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_ACCENT" "• $msg"
  else
    printf '[info] %s\n' "$msg"
  fi
}

kaye_ui_warn() {
  local msg="$*"
  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_WARN" "! $msg" >&2
  else
    printf '[warn] %s\n' "$msg" >&2
  fi
}

kaye_ui_error() {
  local msg="$*"
  if kaye_has_gum_stdout; then
    gum style --foreground "$KAYE_COLOR_ERROR" --bold "✗ $msg" >&2
  else
    printf '[error] %s\n' "$msg" >&2
  fi
}

# Usage: kaye_ui_choose <header> <default> <opt1> [opt2 ...]
kaye_ui_choose() {
  local header="$1"
  local default_val="$2"
  shift 2
  local options=("$@")

  if kaye_has_gum_tty; then
    gum choose \
      --header "$header" \
      --selected "$default_val" \
      --cursor.foreground "$KAYE_COLOR_ACCENT" \
      --header.foreground "$KAYE_COLOR_ACCENT" \
      --selected.foreground "$KAYE_COLOR_SUCCESS" \
      "${options[@]}"
    return
  fi

  if [[ "${KAYE_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    printf '%s\n' "$default_val"
    return
  fi

  printf '\n%s\n' "$header" >&2
  local i=1 opt
  for opt in "${options[@]}"; do
    printf '  %d) %s\n' "$i" "$opt" >&2
    ((i++))
  done
  local choice=""
  read -r -p "Select [1-${#options[@]}] (default: $default_val): " choice || true
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
    printf '%s\n' "${options[$((choice - 1))]}"
  else
    printf '%s\n' "$default_val"
  fi
}

# Usage: kaye_ui_confirm <prompt> [default_yes: 1|0]
kaye_ui_confirm() {
  local prompt="$1"
  local default_yes="${2:-1}"

  if kaye_has_gum_tty; then
    local default_flag="--default=true"
    if [[ "$default_yes" == "0" ]]; then
      default_flag="--default=false"
    fi
    gum confirm "$prompt" \
      "$default_flag" \
      --prompt.foreground "$KAYE_COLOR_TEXT" \
      --selected.background "$KAYE_COLOR_ACCENT" \
      --selected.foreground "#1e1e2e"
    return
  fi

  if [[ "${KAYE_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]; then
    [[ "$default_yes" == "1" ]]
    return
  fi

  local hint="[Y/n]"
  [[ "$default_yes" == "0" ]] && hint="[y/N]"
  local reply=""
  read -r -p "$prompt $hint " reply || true
  case "${reply,,}" in
    y | yes) return 0 ;;
    n | no) return 1 ;;
    "") [[ "$default_yes" == "1" ]] ;;
    *) return 1 ;;
  esac
}

# Renders CSV lines (first line = header) passed on stdin.
kaye_ui_table() {
  if kaye_has_gum_stdout; then
    gum table --print --border rounded --border.foreground "$KAYE_COLOR_ACCENT"
  elif command -v column >/dev/null 2>&1; then
    column -t -s','
  else
    cat
  fi
}

# Usage: kaye_ui_spin <title> <cmd...>
kaye_ui_spin() {
  local title="$1"
  shift
  if kaye_has_gum_tty && [[ "${KAYE_VERBOSE:-0}" != "1" ]]; then
    gum spin \
      --spinner dot \
      --spinner.foreground "$KAYE_COLOR_ACCENT" \
      --title "$title" \
      -- "$@"
  else
    printf '==> %s\n' "$title"
    "$@"
  fi
}

kaye_ui_error_box() {
  local failed_file="$1"
  local failed_line="$2"
  local exit_code="$3"
  local failed_cmd="$4"
  local log_file="${5:-}"
  local resume_cmd="${6:-bash ~/kaye/install/all.sh}"

  {
    echo
    if kaye_has_gum_stdout; then
      gum style \
        --foreground "$KAYE_COLOR_ERROR" \
        --border double \
        --border-foreground "$KAYE_COLOR_ERROR" \
        --padding "1 2" \
        --bold \
        "Kaye OS Installer Failed" \
        "" \
        "Script  : $failed_file" \
        "Line    : $failed_line" \
        "Exit    : $exit_code" \
        "Command : $failed_cmd" \
        "Log     : ${log_file:-<none>}" \
        "Resume  : $resume_cmd"
    else
      echo "============================================================"
      echo "  Kaye OS Installer Failed"
      echo "============================================================"
      echo "  Script  : $failed_file"
      echo "  Line    : $failed_line"
      echo "  Exit    : $exit_code"
      echo "  Command : $failed_cmd"
      echo "  Log     : ${log_file:-<none>}"
      echo "  Resume  : $resume_cmd"
      echo "============================================================"
    fi

    if [[ -n "$log_file" ]] && [[ -f "$log_file" ]]; then
      echo
      echo "--- Last 25 lines of $log_file ---"
      tail -n 25 "$log_file" || true
      echo "------------------------------------------------------------"
    fi
  } >&2
}
