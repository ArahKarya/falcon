#!/usr/bin/env bash
# Compile semua RTL + jalankan kedua testbench (packer byte-exact + parser).
set -e
cd "$(dirname "$0")/../.."   # repo root
if [ -d .venv ]; then . .venv/bin/activate; fi

echo "[golden] regen vektor dari contract.py"
python fpga/tb/gen_golden.py >/dev/null

WORK=fpga/sim/work; mkdir -p "$WORK"; rm -f "$WORK"/*.cf 2>/dev/null || true

echo "[analyze] semua RTL + TB (GHDL std=08)"
ghdl -a --std=08 --workdir="$WORK" \
  fpga/rtl/falcon_pkg.vhd \
  fpga/rtl/telemetry_packer.vhd \
  fpga/rtl/gtpu_parser.vhd \
  fpga/rtl/protocol_classifier.vhd \
  fpga/rtl/stats_counter.vhd \
  fpga/rtl/falcon_top.vhd \
  fpga/tb/tb_telemetry_packer.vhd \
  fpga/tb/tb_gtpu_parser.vhd 2>&1 | grep -v "hides port" || true

echo ""
echo "========== TB 1: telemetry_packer (byte-exact vs contract.py) =========="
ghdl -e --std=08 --workdir="$WORK" tb_telemetry_packer
ghdl -r --std=08 --workdir="$WORK" tb_telemetry_packer --stop-time=10us \
  | grep -E "PASS|FAIL|ALL"

echo ""
echo "========== TB 2: gtpu_parser (ekstrak field GTP-U) =========="
ghdl -e --std=08 --workdir="$WORK" tb_gtpu_parser
ghdl -r --std=08 --workdir="$WORK" tb_gtpu_parser --stop-time=10us \
  | grep -E "PASS|FAIL|ALL"

echo ""
echo "[done] semua testbench selesai."
