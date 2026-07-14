#!/usr/bin/env python3
"""send_gtpu.py — inject synthetic GTP-U packets to the FALCON board (FPGA).

Reads frame vectors from fpga/tb/vectors/imsi_frames.txt (hex per line),
strips Eth+IP+UDP header (42B) -> GTP-U payload, sends as UDP to the board.

Usage: send_gtpu.py [n] [pps]
  n   = packet count (default 10000)
  pps = packets/sec; 0 = full-speed (default 0)
"""
import socket, time, sys, os

BOARD = ("192.168.0.20", 2152)
HOST_SRC = "192.168.0.101"

# vector path relative to repo root (script in scripts/, go up 1 level)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VEC = os.path.join(REPO, "fpga", "tb", "vectors", "imsi_frames.txt")

frames = []
with open(VEC) as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 3:
            frame = bytes.fromhex(parts[2])
            frames.append(frame[42:])   # strip Eth14+IP20+UDP8 -> GTP-U
print(f"loaded {len(frames)} GTP-U payloads from {VEC}")

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((HOST_SRC, 0))
n = int(sys.argv[1]) if len(sys.argv) > 1 else 10000
pps = int(sys.argv[2]) if len(sys.argv) > 2 else 0
delay = (1.0 / pps) if pps > 0 else 0
t0 = time.time()
for i in range(n):
    s.sendto(frames[i % len(frames)], BOARD)
    if delay:
        time.sleep(delay)
dt = time.time() - t0
print(f"sent {n} GTP-U in {dt:.2f}s = {n/dt:.0f} pps to {BOARD}")
