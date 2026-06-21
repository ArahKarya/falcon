#!/usr/bin/env bash
# build_eth_ise.sh — synth + PAR + bitgen FALCON Ethernet Fase 0 (Genesys)
# Pakai verilog-ethernet commit c5b6202 (Jan 2016, ISE/XST-friendly, no $clog2).
# Jalankan di mesin NOZ (ISE 14.7).
set -e

VE="/data/yayang/verilog-ethernet-full"          # checkout c5b6202
ETH="$(cd "$(dirname "$0")" && pwd)"
WORK="/data/yayang/falcon/fpga/eth/build"
TOP="genesys_fpga"
PART="xc5vlx50t-1-ff1136"

source /data/xilinx/14.7/ISE_DS/settings64.sh >/dev/null 2>&1
mkdir -p "$WORK"; cd "$WORK"

R="$VE/rtl"; A="$VE/lib/axis/rtl"; EX="$VE/example/ATLYS/fpga/rtl"

SRC=(
  "$ETH/genesys_fpga.v"
  "$ETH/fpga_core.v"
  "$EX/sync_reset.v"
  "$ETH/v5io/gmii_phy_if.v"
  "$ETH/v5io/ssio_sdr_in.v"
  "$ETH/v5io/ssio_sdr_out.v"
  "$ETH/v5io/iddr.v"
  "$ETH/v5io/oddr.v"
  "$R/eth_mac_1g_fifo.v"
  "$R/eth_mac_1g.v"
  "$R/eth_mac_1g_rx.v"
  "$R/eth_mac_1g_tx.v"
  "$R/eth_crc_8.v"
  "$R/eth_axis_rx.v"
  "$R/eth_axis_tx.v"
  "$R/udp_complete.v"
  "$R/udp.v"
  "$R/udp_ip_rx.v"
  "$R/udp_ip_tx.v"
  "$R/ip_complete.v"
  "$R/ip.v"
  "$R/ip_eth_rx.v"
  "$R/ip_eth_tx.v"
  "$R/ip_arb_mux_2.v"
  "$R/ip_mux_2.v"
  "$R/arp.v"
  "$R/arp_cache.v"
  "$R/arp_eth_rx.v"
  "$R/arp_eth_tx.v"
  "$R/eth_arb_mux_2.v"
  "$R/eth_mux_2.v"
  "$A/arbiter.v"
  "$A/priority_encoder.v"
  "$A/axis_fifo.v"
  "$A/axis_async_frame_fifo.v"
)

> "$TOP.prj"
for f in "${SRC[@]}"; do
  [ -f "$f" ] || { echo "MISSING SOURCE: $f"; exit 1; }
  echo "verilog work \"$f\"" >> "$TOP.prj"
done
echo "[build] project: $(wc -l < "$TOP.prj") source files"

cat > "$TOP.xst" <<EOF
run
-ifn $TOP.prj
-ofn $TOP.ngc
-ofmt NGC
-p $PART
-top $TOP
-opt_mode Speed
-opt_level 1
-use_new_parser yes
EOF

echo "[xst] synthesizing..."
xst -ifn "$TOP.xst" -ofn "$TOP.syr" 2>&1 | tail -25
echo "[ngdbuild]..."
ngdbuild -p "$PART" -uc "$ETH/genesys_eth.ucf" "$TOP.ngc" "$TOP.ngd" 2>&1 | tail -12
echo "[map]..."
map -p "$PART" -w -o "${TOP}_map.ncd" "$TOP.ngd" "$TOP.pcf" 2>&1 | tail -12
echo "[par]..."
par -w "${TOP}_map.ncd" "${TOP}.ncd" "$TOP.pcf" 2>&1 | tail -18
echo "[bitgen]..."
bitgen -w "${TOP}.ncd" "${TOP}.bit" "$TOP.pcf" 2>&1 | tail -12

echo ""; echo "=== HASIL ==="
ls -la "${TOP}.bit" 2>/dev/null && echo "BITSTREAM OK: $WORK/${TOP}.bit" || echo "BITGEN GAGAL"
