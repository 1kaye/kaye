#!/usr/bin/env bash
set -euo pipefail

PKGS=()

# CPU microcode detection
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
  PKGS+=(amd-ucode)
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
  PKGS+=(intel-ucode)
fi

# GPU detection via lspci
GPU_INFO="$(lspci -nn 2>/dev/null | grep -iE 'VGA|3D|Display' || true)"

if echo "$GPU_INFO" | grep -qiE 'AMD|ATI|Radeon'; then
  echo "==> Detected AMD GPU"
  PKGS+=(mesa vulkan-radeon libva-mesa-driver)
fi

if echo "$GPU_INFO" | grep -qi 'Intel'; then
  echo "==> Detected Intel GPU"
  PKGS+=(mesa vulkan-intel intel-media-driver)
fi

if echo "$GPU_INFO" | grep -qi 'NVIDIA'; then
  echo "==> Detected NVIDIA GPU"
  # Turing+ (GTX 16xx / RTX 20xx+) supports nvidia-open-dkms.
  PKGS+=(linux-headers nvidia-open-dkms nvidia-utils)
fi

if (( ${#PKGS[@]} > 0 )); then
  echo "==> Installing hardware packages: ${PKGS[*]}"
  sudo pacman -S --needed --noconfirm "${PKGS[@]}"
else
  echo "==> No extra hardware packages detected (likely VM)."
fi
