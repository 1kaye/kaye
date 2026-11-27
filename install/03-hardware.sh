#!/usr/bin/env bash
set -euo pipefail

KAYE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export KAYE_PATH="$KAYE_DIR"

# shellcheck source=install/lib/logging.sh
source "$KAYE_DIR/install/lib/logging.sh"
kaye_enable_err_trap

PKGS=()
KMS_MODULES=()
HAS_NVIDIA=0

add_unique() {
  local -n _arr="$1"
  shift
  local item existing
  for item in "$@"; do
    for existing in "${_arr[@]}"; do
      if [[ "$existing" == "$item" ]]; then
        continue 2
      fi
    done
    _arr+=("$item")
  done
}

# 1. CPU microcode detection
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  echo "==> Detected AMD CPU"
  add_unique PKGS amd-ucode
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
  echo "==> Detected Intel CPU"
  add_unique PKGS intel-ucode
fi

# 2. GPU detection via lspci
GPU_INFO=""
GPU_DRIVERS=""
if command -v lspci >/dev/null 2>&1; then
  GPU_INFO="$(lspci -nn 2>/dev/null | grep -iE 'VGA|3D|Display' || true)"
  GPU_DRIVERS="$(lspci -k 2>/dev/null | grep -A3 -iE 'VGA|3D|Display' || true)"
else
  echo "Warning: lspci not found; skipping PCI GPU auto-detection." >&2
fi

if grep -qiE 'AMD|ATI|Radeon' <<<"$GPU_INFO"; then
  echo "==> Detected AMD GPU"
  add_unique PKGS mesa vulkan-radeon libva-mesa-driver
  add_unique KMS_MODULES amdgpu
fi

if grep -qi 'Intel' <<<"$GPU_INFO"; then
  echo "==> Detected Intel GPU"
  add_unique PKGS mesa vulkan-intel intel-media-driver
  if grep -q 'Kernel driver in use: xe' <<<"$GPU_DRIVERS"; then
    add_unique KMS_MODULES xe
  else
    add_unique KMS_MODULES i915
  fi
fi

if grep -qi 'NVIDIA' <<<"$GPU_INFO"; then
  echo "==> Detected NVIDIA GPU"
  HAS_NVIDIA=1
  # Turing+ (GTX 16xx / RTX 20xx+) supports nvidia-open-dkms.
  add_unique PKGS linux-headers nvidia-open-dkms nvidia-utils
  add_unique KMS_MODULES nvidia nvidia_modeset nvidia_uvm nvidia_drm
fi

if grep -qiE 'Virtio|QXL|VMware|VirtualBox|Bochs|Red Hat|QEMU' <<<"$GPU_INFO"; then
  echo "==> Detected virtualized GPU (VM)"
  add_unique PKGS mesa vulkan-virtio vulkan-swrast
fi

if (( ${#PKGS[@]} > 0 )); then
  echo "==> Installing hardware packages: ${PKGS[*]}"
  sudo pacman -S --needed --noconfirm "${PKGS[@]}"
else
  echo "==> No extra hardware packages detected."
fi

# 3. Write additive early KMS drop-in for mkinitcpio (rebuilt in 04-boot-and-plymouth.sh).
if (( ${#KMS_MODULES[@]} > 0 )); then
  echo "==> Configuring early KMS modules: ${KMS_MODULES[*]}"
  sudo install -d -m 755 /etc/mkinitcpio.conf.d
  sudo tee /etc/mkinitcpio.conf.d/10-kaye-kms.conf >/dev/null <<EOF
# Kaye OS — Early KMS modules (additive drop-in)
MODULES+=(${KMS_MODULES[*]})
EOF
fi

if (( HAS_NVIDIA == 1 )); then
  echo "==> Configuring NVIDIA DRM modesetting..."
  sudo install -d -m 755 /etc/modprobe.d
  sudo tee /etc/modprobe.d/10-kaye-nvidia.conf >/dev/null <<'EOF'
# Kaye OS — Enable Wayland & Plymouth DRM modesetting for NVIDIA
options nvidia_drm modeset=1 fbdev=1
EOF
fi
