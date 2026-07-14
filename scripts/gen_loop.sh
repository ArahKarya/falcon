#!/bin/bash
# gen_loop.sh — continuous GTP-U generator loop for FALCON dashboard live view.
# Inject batch, brief pause, repeat forever. Script dir = repo scripts/.
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "FALCON continuous generator started PID=$$"
while true; do
  python3 "$HERE/send_gtpu.py" 40000 12000
  sleep 2
done
