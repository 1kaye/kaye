#!/usr/bin/env bash
set -euo pipefail

# Kaye OS — Bootable Archiso Builder (Track 2)
#
# Builds a bootable x86_64 Live ISO (kaye-os-<YYYY.MM.DD>-x86_64.iso) based on
# Arch Linux's official `releng` archiso profile with Kaye OS bundled under
# /opt/kaye and auto-launching the installer on tty1.
#
# Usage:
#   sudo ./iso/build.sh [--out-dir DIR] [--work-dir DIR] [--clean]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
RELENG_DIR="/usr/share/archiso/configs/releng"

OUT_DIR="${SCRIPT_DIR}/out"
WORK_DIR="${SCRIPT_DIR}/work"
CLEAN_WORK=0

usage() {
  cat <<'EOF'
Kaye OS — Bootable Archiso Builder

Usage:
  sudo ./iso/build.sh [OPTIONS]

Options:
  --out-dir <dir>   Output directory for the built ISO (default: iso/out)
  --work-dir <dir>  Working directory for archiso staging (default: iso/work)
  --clean           Remove working directory before and after building
  -h, --help        Show this help message and exit
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out-dir)
        [[ $# -ge 2 ]] || { printf 'Error: --out-dir requires a path\n' >&2; exit 1; }
        OUT_DIR="$2"
        shift 2
        ;;
      --work-dir)
        [[ $# -ge 2 ]] || { printf 'Error: --work-dir requires a path\n' >&2; exit 1; }
        WORK_DIR="$2"
        shift 2
        ;;
      --clean)
        CLEAN_WORK=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Error: Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "$EUID" -ne 0 ]]; then
    printf 'Error: iso/build.sh must be run as root (try: sudo %s)\n' "$0" >&2
    exit 1
  fi

  if ! command -v mkarchiso >/dev/null 2>&1; then
    printf 'Error: mkarchiso not found. Install archiso first: sudo pacman -S archiso\n' >&2
    exit 1
  fi

  if [[ ! -d "$RELENG_DIR" ]]; then
    printf 'Error: Archiso releng profile not found at %s\n' "$RELENG_DIR" >&2
    exit 1
  fi

  if [[ "$CLEAN_WORK" -eq 1 && -d "$WORK_DIR" ]]; then
    printf '==> Cleaning previous work directory: %s\n' "$WORK_DIR"
    rm -rf "$WORK_DIR"
  fi

  local profile_dir="${WORK_DIR}/profile"
  local mkarchiso_work="${WORK_DIR}/mkarchiso"

  mkdir -p "$OUT_DIR" "$WORK_DIR"
  rm -rf "$profile_dir" "$mkarchiso_work"

  printf '==> Copying Archiso releng template...\n'
  cp -a "$RELENG_DIR" "$profile_dir"

  printf '==> Merging Kaye OS live packages (%s)...\n' "${SCRIPT_DIR}/packages.x86_64"
  local pkg
  while IFS= read -r pkg || [[ -n "$pkg" ]]; do
    pkg="${pkg%%#*}"
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"
    pkg="${pkg%"${pkg##*[![:space:]]}"}"
    [[ -n "$pkg" ]] || continue
    if ! grep -qxF "$pkg" "${profile_dir}/packages.x86_64"; then
      printf '%s\n' "$pkg" >>"${profile_dir}/packages.x86_64"
    fi
  done <"${SCRIPT_DIR}/packages.x86_64"

  printf '==> Applying Kaye OS airootfs overlay...\n'
  cp -a "${SCRIPT_DIR}/overlay/airootfs/." "${profile_dir}/airootfs/"

  printf '==> Bundling Kaye OS repository into airootfs/opt/kaye...\n'
  local bundled_dir="${profile_dir}/airootfs/opt/kaye"
  mkdir -p "$bundled_dir"
  tar -C "$REPO_ROOT" \
    --exclude='./.git' \
    --exclude='./core/target' \
    --exclude='./iso/out' \
    --exclude='./iso/work' \
    --exclude='*.bak' \
    --exclude='*.bak.*' \
    --exclude='*.tmp' \
    -cf - . | tar -C "$bundled_dir" -xf -

  # Ensure key scripts have executable bits inside staged airootfs
  chmod 0755 "${profile_dir}/airootfs/usr/local/bin/kaye-iso-installer"
  chmod 0755 "${bundled_dir}/arch-install.sh"
  [[ -f "${bundled_dir}/boot.sh" ]] && chmod 0755 "${bundled_dir}/boot.sh"
  find "${bundled_dir}/install" -type f -name '*.sh' -exec chmod 0755 {} + 2>/dev/null || true

  printf '==> Configuring profiledef.sh for Kaye OS...\n'
  {
    printf '\n# --- Kaye OS Overrides ---\n'
    printf 'iso_name="kaye-os"\n'
    printf 'iso_label="KAYE_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%%s)}" +%%Y%%m)"\n'
    printf 'iso_publisher="Kaye OS <https://github.com/1kaye/kaye>"\n'
    printf 'iso_application="Kaye OS Live Installer"\n'
    printf 'file_permissions+=(\n'
    printf '  ["/usr/local/bin/kaye-iso-installer"]="0:0:755"\n'
    printf '  ["/opt/kaye/arch-install.sh"]="0:0:755"\n'
    if [[ -f "${bundled_dir}/boot.sh" ]]; then
      printf '  ["/opt/kaye/boot.sh"]="0:0:755"\n'
    fi
    local script_rel
    while IFS= read -r script_rel; do
      [[ -n "$script_rel" ]] || continue
      printf '  ["/opt/kaye/%s"]="0:0:755"\n' "$script_rel"
    done < <(cd "$bundled_dir" && find install -type f -name '*.sh' 2>/dev/null | sort)
    printf ')\n'
  } >>"${profile_dir}/profiledef.sh"

  printf '==> Running mkarchiso...\n'
  mkarchiso -v -w "$mkarchiso_work" -o "$OUT_DIR" "$profile_dir"

  if [[ "$CLEAN_WORK" -eq 1 ]]; then
    printf '==> Cleaning work directory: %s\n' "$WORK_DIR"
    rm -rf "$WORK_DIR"
  fi

  local built_iso
  built_iso="$(find "$OUT_DIR" -maxdepth 1 -type f -name 'kaye-os-*-x86_64.iso' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  if [[ -n "$built_iso" ]]; then
    printf '\n==> Build complete: %s\n' "$built_iso"
    sha256sum "$built_iso"
  else
    printf '\n==> Build finished. Check output directory: %s\n' "$OUT_DIR"
  fi
}

main "$@"
