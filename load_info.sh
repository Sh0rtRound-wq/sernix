#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# load_info.sh — auto-detect hardware and write config.nix
# Run as your normal user (not sudo) — no root needed.
# Flags:
#   --stub   write stub content to config.nix and hardware-configuration.nix
#            (use before pushing flake changes from any device, then rerun normally)
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.nix"
HW_DST="$SCRIPT_DIR/hardware-configuration.nix"

# ── --stub mode ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--stub" ]]; then
  cat > "$CONFIG" <<'NIXEOF'
# Stub — run bash load_info.sh to populate with real machine config
{
  hostname     = "nixos";
  powerProfile = "balanced";
  cpuVendor    = "amd";
  gpu          = "amd";
  nvidiaBusId  = "";
  amdBusId     = "";
  intelBusId   = "";
}
NIXEOF
  cat > "$HW_DST" <<'NIXEOF'
# Stub — run bash load_info.sh to populate with real hardware config
{ config, lib, pkgs, modulesPath, ... }: {}
NIXEOF
  git -C "$SCRIPT_DIR" update-index --no-assume-unchanged "$CONFIG" "$HW_DST" 2>/dev/null || true
  git -C "$SCRIPT_DIR" add "$CONFIG" "$HW_DST" 2>/dev/null || true
  echo "Stubs written. Safe to commit and push. Run load_info.sh again after to restore."
  exit 0
fi

# Ensure NixOS system binaries are on PATH
export PATH="/run/current-system/sw/bin:/run/wrappers/bin:$PATH"

if ! command -v lspci &>/dev/null; then
  echo "error: lspci not found — run: nix-shell -p pciutils --run './load_info.sh'"
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

hex2dec() { printf '%d' "0x${1}"; }

pci_nixos() {
  local bus dev func
  bus=$(echo "$1"  | cut -d: -f1)
  dev=$(echo "$1"  | cut -d: -f2 | cut -d. -f1)
  func=$(echo "$1" | cut -d: -f2 | cut -d. -f2)
  printf "PCI:%d:%d:%d" "$(hex2dec "$bus")" "$(hex2dec "$dev")" "$(hex2dec "$func")"
}

nix_str() {
  grep "$1" "$2" 2>/dev/null | grep -oP '"\K[^"]+(?=")' | head -1 || true
}

get_addr() { echo "$1" | grep -oE '^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' || true; }

# ── Preserve values from existing config.nix ─────────────────────────────────

CURRENT_POWER="balanced"
if [ -f "$CONFIG" ] && ! grep -q "# Stub" "$CONFIG"; then
  p=$(nix_str "powerProfile" "$CONFIG"); [ -n "$p" ] && CURRENT_POWER="$p"
fi

# ── Detect hardware ───────────────────────────────────────────────────────────

HOSTNAME_VAL=$(hostname)

if grep -qm1 "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
  CPU_VENDOR="amd"
else
  CPU_VENDOR="intel"
fi

GPU_LIST=$(lspci | grep -E "VGA compatible controller|3D controller|Display controller|Class 030[012]" || true)

NVIDIA_LINE=$(echo "$GPU_LIST" | grep -iE "(nvidia|10de)" | head -1 || true)
AMD_LINE=$(  echo "$GPU_LIST" | grep -iE "(amd|ati|1002)" | head -1 || true)
INTEL_LINE=$(echo "$GPU_LIST" | grep -iE "(intel|8086)"   | head -1 || true)

NVIDIA_BUS="" AMD_BUS="" INTEL_BUS=""

if [ -n "$NVIDIA_LINE" ] && [ -n "$AMD_LINE" ]; then
  GPU_MODE="prime-nvidia-amd"
  NVIDIA_BUS=$(pci_nixos "$(get_addr "$NVIDIA_LINE")")
  AMD_BUS=$(  pci_nixos "$(get_addr "$AMD_LINE")")
elif [ -n "$NVIDIA_LINE" ] && [ -n "$INTEL_LINE" ]; then
  GPU_MODE="prime-nvidia-intel"
  NVIDIA_BUS=$(pci_nixos "$(get_addr "$NVIDIA_LINE")")
  INTEL_BUS=$( pci_nixos "$(get_addr "$INTEL_LINE")")
elif [ -n "$NVIDIA_LINE" ]; then
  GPU_MODE="nvidia"
  NVIDIA_BUS=$(pci_nixos "$(get_addr "$NVIDIA_LINE")")
elif [ -n "$AMD_LINE" ]; then
  GPU_MODE="amd"
elif [ -n "$INTEL_LINE" ]; then
  GPU_MODE="intel"
else
  echo "warning: no GPU detected — defaulting to 'amd'."
  GPU_MODE="amd"
fi

# ── Preview & confirm ─────────────────────────────────────────────────────────

echo ""
echo "Detected:"
echo "  hostname:  $HOSTNAME_VAL"
echo "  power:     $CURRENT_POWER"
echo "  cpu:       $CPU_VENDOR"
echo "  gpu mode:  $GPU_MODE"
[ -n "$NVIDIA_BUS" ] && echo "  nvidia bus: $NVIDIA_BUS"
[ -n "$AMD_BUS"    ] && echo "  amd bus:    $AMD_BUS"
[ -n "$INTEL_BUS"  ] && echo "  intel bus:  $INTEL_BUS"
echo ""
printf "Write to config.nix? [Y/n] "
read -r CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Write config.nix ──────────────────────────────────────────────────────────

cat > "$CONFIG" <<NIXEOF
# ════════════════════════════════════════════════════════════════════════════
# Run ./load_info.sh to auto-detect and fill all fields from hardware
# ════════════════════════════════════════════════════════════════════════════
{
  hostname     = "$HOSTNAME_VAL";   # machine hostname
  powerProfile = "$CURRENT_POWER"; # "performance", "balanced", or "power-saver"
  cpuVendor    = "$CPU_VENDOR";    # "amd" or "intel"
  gpu          = "$GPU_MODE";      # "amd", "intel", "nvidia", "prime-nvidia-amd", "prime-nvidia-intel"
  nvidiaBusId  = "$NVIDIA_BUS";   # PRIME only, e.g. "PCI:196:0:0"
  amdBusId     = "$AMD_BUS";      # PRIME only
  intelBusId   = "$INTEL_BUS";    # PRIME only
}
NIXEOF

echo "Done. config.nix written."
git -C "$SCRIPT_DIR" update-index --assume-unchanged "$CONFIG" 2>/dev/null || true

# ── Populate hardware-configuration.nix ──────────────────────────────────────
HW_SRC="/etc/nixos/hardware-configuration.nix"
if [ -f "$HW_SRC" ]; then
  cp "$HW_SRC" "$HW_DST"
  git -C "$SCRIPT_DIR" update-index --assume-unchanged "$HW_DST" 2>/dev/null || true
  echo "Copied hardware-configuration.nix from $HW_SRC"
else
  echo "warning: $HW_SRC not found — run 'nixos-generate-config' first"
fi
