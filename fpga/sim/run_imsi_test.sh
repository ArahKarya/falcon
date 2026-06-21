#!/usr/bin/env bash
# run_imsi_test.sh — generate frame IMSI + jalankan tb_imsi_test (parser ekstraksi).
# Level 1: validasi parser ekstrak TEID tiap sesi IMSI via simulasi RTL ("board virtual").
set -e
cd "$(dirname "$0")/../.."   # repo root
if [ -d .venv ]; then . .venv/bin/activate; fi

N="${1:-8}"
echo "[imsi] generate $N frame GTP-U ber-IMSI"
python fpga/tb/gen_imsi_test.py --n "$N"

WORK=fpga/sim/work; mkdir -p "$WORK"; rm -f "$WORK"/*.cf 2>/dev/null || true

echo ""
echo "[analyze] RTL + tb_imsi_test (GHDL std=08)"
ghdl -a --std=08 --workdir="$WORK" \
  fpga/rtl/falcon_pkg.vhd \
  fpga/rtl/telemetry_packer.vhd \
  fpga/rtl/gtpu_parser.vhd \
  fpga/rtl/protocol_classifier.vhd \
  fpga/rtl/stats_counter.vhd \
  fpga/rtl/falcon_top.vhd \
  fpga/tb/tb_imsi_test.vhd 2>&1 | grep -v "hides port" || true

ghdl -e --std=08 --workdir="$WORK" tb_imsi_test

echo ""
echo "========== IMSI TEST: parser ekstrak TEID per sesi =========="
# cwd ke fpga/tb supaya path vectors/imsi_frames.txt ketemu + executable di sini
ABSWORK="$(pwd)/$WORK"
cd fpga/tb
ghdl -e --std=08 --workdir="$ABSWORK" -o tb_imsi_test tb_imsi_test 2>&1 | grep -v "hides port" || true
ghdl -r --std=08 --workdir="$ABSWORK" tb_imsi_test --stop-time=50us \
  | grep -E "PASS|FAIL|ALL|diproses"

echo ""
echo "[done] peta TEID<->IMSI: fpga/tb/vectors/imsi_map.csv"
