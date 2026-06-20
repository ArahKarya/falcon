#!/usr/bin/env bash
# Jalankan testbench telemetry_packer (GHDL) — byte-exact lawan contract.py.
# Regenerasi golden dulu agar selalu sinkron dengan host.
set -e
cd "$(dirname "$0")/../.."   # -> repo root (fpga-dpi)

echo "[1/4] regen golden vectors dari contract.py"
if [ -d .venv ]; then . .venv/bin/activate; fi
python fpga/tb/gen_golden.py

WORK=fpga/sim/work
mkdir -p "$WORK"

echo "[2/4] analyze (GHDL --std=08)"
ghdl -a --std=08 --workdir="$WORK" \
  fpga/rtl/falcon_pkg.vhd \
  fpga/rtl/telemetry_packer.vhd \
  fpga/tb/tb_telemetry_packer.vhd

echo "[3/4] elaborate"
ghdl -e --std=08 --workdir="$WORK" tb_telemetry_packer

echo "[4/4] run"
ghdl -r --std=08 --workdir="$WORK" tb_telemetry_packer --stop-time=10us
