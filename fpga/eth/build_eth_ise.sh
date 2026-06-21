#!/usr/bin/env bash
# build_eth_ise.sh — synth + PAR + bitgen FALCON Ethernet Fase 0 (Genesys)
# Jalankan di mesin NOZ (ISE 14.7). Pakai verilog-ethernet source + 2 file kustom.
#
# Usage: bash build_eth_ise.sh
set -e

# --- paths ---
VE="/data/yayang/verilog-ethernet"        # verilog-ethernet repo root
ETH="$(cd "$(dirname "$0")" && pwd)"      # dir berisi genesys_fpga.v, fpga_core.v, genesys_eth.ucf
WORK="/data/yayang/falcon/fpga/eth/build"
TOP="genesys_fpga"
PART="xc5vlx50t-1-ff1136"

source /data/xilinx/14.7/ISE_DS/settings64.sh >/dev/null 2>&1

mkdir -p "$WORK"
cd "$WORK"

# --- daftar source (root verilog-ethernet rtl + axis lib) ---
R="$VE/rtl"
A="$VE/lib/axis/rtl"

SRC=(
  "$ETH/genesys_fpga.v"
  "$ETH/fpga_core.v"
  "$R/eth_mac_1g_gmii_fifo.v"
  "$R/eth_mac_1g_gmii.v"
  "$R/eth_mac_1g.v"
  "$R/axis_gmii_rx.v"
  "$R/axis_gmii_tx.v"
  "$R/lfsr.v"
  "$R/gmii_phy_if.v"
  "$R/ssio_sdr_in.v"
  "$R/ssio_sdr_out.v"
  "$R/iddr.v"
  "$R/oddr.v"
  "$R/eth_axis_rx.v"
  "$R/eth_axis_tx.v"
  "$R/udp_complete.v"
  "$R/udp_checksum_gen.v"
  "$R/udp.v"
  "$R/udp_ip_rx.v"
  "$R/udp_ip_tx.v"
  "$R/ip_complete.v"
  "$R/ip.v"
  "$R/ip_eth_rx.v"
  "$R/ip_eth_tx.v"
  "$R/ip_arb_mux.v"
  "$R/arp.v"
  "$R/arp_cache.v"
  "$R/arp_eth_rx.v"
  "$R/arp_eth_tx.v"
  "$R/eth_arb_mux.v"
  "$A/arbiter.v"
  "$A/priority_encoder.v"
  "$A/axis_fifo.v"
  "$A/axis_async_fifo.v"
  "$A/axis_async_fifo_adapter.v"
  "$A/sync_reset.v"
)

# --- generate XST project file ---
> "$TOP.prj"
for f in "${SRC[@]}"; do
  if [ ! -f "$f" ]; then echo "MISSING SOURCE: $f"; exit 1; fi
  echo "verilog work \"$f\"" >> "$TOP.prj"
done
echo "[build] project: $(wc -l < "$TOP.prj") source files"

# --- XST script ---
cat > "$TOP.xst" <<EOF
run
-ifn $TOP.prj
-ofn $TOP.ngc
-ofmt NGC
-p $PART
-top $TOP
-opt_mode Speed
-opt_level 1
EOF

echo "[xst] synthesizing..."
xst -ifn "$TOP.xst" -ofn "$TOP.syr" 2>&1 | tail -20

echo "[ngdbuild]..."
ngdbuild -p "$PART" -uc "$ETH/genesys_eth.ucf" "$TOP.ngc" "$TOP.ngd" 2>&1 | tail -10

echo "[map]..."
map -p "$PART" -w -o "${TOP}_map.ncd" "$TOP.ngd" "$TOP.pcf" 2>&1 | tail -10

echo "[par]..."
par -w "${TOP}_map.ncd" "${TOP}.ncd" "$TOP.pcf" 2>&1 | tail -15

echo "[bitgen]..."
bitgen -w "${TOP}.ncd" "${TOP}.bit" "$TOP.pcf" 2>&1 | tail -10

echo ""
echo "=== HASIL ==="
ls -la "${TOP}.bit" 2>/dev/null && echo "BITSTREAM OK: $WORK/${TOP}.bit" || echo "BITGEN GAGAL"
