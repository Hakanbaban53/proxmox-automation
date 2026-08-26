#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verify that the physical host CPU supports x86-64-v3
# (AVX2 / BMI2 / FMA / MOVBE) - required by the Ubuntu 26.04
# 'amd64v3' cloud image variant.
#
# Run this on the machine that runs the VMs (the laptop in a nested-virt lab).
# ---------------------------------------------------------------------------
set -euo pipefail

flags="$(grep -m1 '^flags' /proc/cpuinfo)"

missing=()
for feature in avx2 bmi2 fma movbe; do
  grep -qw "$feature" <<<"$flags" || missing+=("$feature")
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "OK: CPU exposes all x86-64-v3 features (avx2 bmi2 fma movbe)."
  echo "You can use the amd64v3 cloud image:"
  echo "  https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64v3.img"
  exit 0
else
  echo "MISSING x86-64-v3 features: ${missing[*]}"
  echo "Use the baseline amd64 image instead:"
  echo "  https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
  exit 1
fi
