#!/usr/bin/env bash
# run_qfi_test.sh — parser vs GTP-U berheader ekstensi QFI (flags 0x34 + ext 0x85), frame dari generator rujukan.
set -e
cd "$(dirname "$0")/../.."
python3 fpga/tb/gen_qfi_test.py
WORK=fpga/sim/work; mkdir -p "$WORK"; rm -f "$WORK"/*.cf 2>/dev/null || true
ghdl -a --std=08 --workdir="$WORK" fpga/rtl/falcon_pkg.vhd fpga/rtl/telemetry_packer.vhd fpga/rtl/gtpu_parser.vhd \
  fpga/rtl/protocol_classifier.vhd fpga/rtl/stats_counter.vhd fpga/rtl/falcon_top.vhd fpga/tb/tb_qfi_test.vhd 2>&1 | grep -v "hides port" || true
ABSWORK="$(pwd)/$WORK"; cd fpga/tb
ghdl -e --std=08 --workdir="$ABSWORK" -o tb_qfi_test tb_qfi_test 2>&1 | grep -v "hides port" || true
ghdl -r --std=08 --workdir="$ABSWORK" tb_qfi_test --stop-time=500us | grep -E "FAIL|ALL|diproses|ADA"
