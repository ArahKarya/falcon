#!/usr/bin/env bash
#-----------------------------------------------------------------------------
# build_ise.sh — sintesis FALCON gateware untuk Virtex-5 dengan Xilinx ISE.
#
# JALANKAN DI MESIN BER-ISE (bukan RPi5). ISE 14.7 = versi terakhir yang
# mendukung Virtex-5. RPi5 hanya untuk simulasi (GHDL) — lihat fpga/sim/.
#
# Prasyarat: source settings ISE dulu, mis:
#   source /opt/Xilinx/14.7/ISE_DS/settings64.sh
#
# Device default: xc5vlx50t-1-ff1136 (Virtex-5 LXT, ML505). Ganti -p sesuai board.
#-----------------------------------------------------------------------------
set -e
cd "$(dirname "$0")"
HERE="$(pwd)"

DEVICE="${DEVICE:-xc5vlx50t-1-ff1136}"
TOP="falcon_top"
RTL="${HERE}/../rtl"
UCF="${HERE}/../constraints/falcon_top.ucf"
OUT="build"
mkdir -p "$OUT"; cd "$OUT"

# ---- 1. project file untuk XST ----
cat > ${TOP}.prj <<EOF
vhdl work ${RTL}/falcon_pkg.vhd
vhdl work ${RTL}/telemetry_packer.vhd
vhdl work ${RTL}/gtpu_parser.vhd
vhdl work ${RTL}/protocol_classifier.vhd
vhdl work ${RTL}/stats_counter.vhd
vhdl work ${RTL}/falcon_top.vhd
EOF

# ---- 2. XST script ----
cat > ${TOP}.xst <<EOF
run
-ifn ${TOP}.prj
-ofn ${TOP}.ngc
-ofmt NGC
-p ${DEVICE}
-top ${TOP}
-opt_mode Speed
-opt_level 1
EOF

echo "[1/4] XST synthesize -> ${TOP}.ngc"
xst -ifn ${TOP}.xst -ofn ${TOP}.syr

echo "[2/4] NGDBuild (+UCF)"
ngdbuild -p ${DEVICE} -uc ${UCF} ${TOP}.ngc ${TOP}.ngd

echo "[3/4] MAP + PAR (place & route)"
map -p ${DEVICE} -o ${TOP}_map.ncd ${TOP}.ngd ${TOP}.pcf
par -w ${TOP}_map.ncd ${TOP}.ncd ${TOP}.pcf

echo "[4/4] BitGen -> ${TOP}.bit"
bitgen -w ${TOP}.ncd ${TOP}.bit ${TOP}.pcf

echo "[done] bitstream: ${OUT}/${TOP}.bit"
echo "       cek timing: ${OUT}/${TOP}.twr (trce)"
