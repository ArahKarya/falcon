#!/usr/bin/env bash
# run_rate_clear.sh — regresi: ul_pps harus per-interval (bukan kumulatif).
set -e
cd "$(dirname "$0")/../.."
WORK=fpga/sim/work; mkdir -p "$WORK"; rm -f "$WORK"/*.cf 2>/dev/null || true
[ -f fpga/tb/vectors/imsi_frames.txt ] || python3 fpga/tb/gen_imsi_test.py --n 8 >/dev/null
ghdl -a --std=08 --workdir="$WORK" \
  fpga/rtl/falcon_pkg.vhd fpga/rtl/telemetry_packer.vhd fpga/rtl/gtpu_parser.vhd \
  fpga/rtl/protocol_classifier.vhd fpga/rtl/stats_counter.vhd fpga/rtl/falcon_top.vhd \
  fpga/tb/tb_rate_clear.vhd 2>&1 | grep -v "hides port" || true
ABS="$(pwd)/$WORK"; cd fpga/tb
ghdl -e --std=08 --workdir="$ABS" -o tb_rate_clear tb_rate_clear 2>&1 | grep -v "hides port" || true
ghdl -r --std=08 --workdir="$ABS" tb_rate_clear --stop-time=200us 2>&1 | grep -E "PASS|FAIL|ALL|ul_pps|error"
