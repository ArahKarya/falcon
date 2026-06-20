#!/usr/bin/env python3
"""Generate vektor uji byte-exact dari contract.py (ground truth host).

Output: fpga/tb/vectors/golden.txt — tiap baris:
  <msg_type_hex> <dgram_hex_full>
Dipakai testbench VHDL (tb_telemetry_packer) untuk membandingkan output packer
FPGA terhadap encoding host. Jika cocok byte-per-byte → kontrak tersinkron.

Nilai input HARUS identik dengan yang di-drive testbench VHDL.
"""
import os, sys
HERE = os.path.dirname(__file__)
sys.path.insert(0, os.path.join(HERE, "..", "..", "falcon"))
from shared import contract as C

# nilai uji tetap (deterministik) — DRIVE SAMA di tb VHDL
TS          = 0x11223344
TOTAL_IMSI  = 142
UL_PPS      = 18000
DL_PPS      = 9500
ACTIVE_TEID = 130
TOTAL_BYTES = 0x0000000200000001      # u64 jelas non-trivial
DROP        = 7

TEID        = 0xA1B2C3D4
IMSI        = "310410123456789"        # 15 char (pad ke 16)
QFI         = 7
STATE       = 1                         # ACTIVE
UL_PKTS     = 1200
DL_PKTS     = 980

EV_TYPE     = 1                         # CreateSession
EV_DIR      = 0                         # UL
EV_TEID     = 0xAABBCCDD
EV_PLEN     = 312
EV_TS       = 0x55667788

# protocol: input ke contract = persen float; FPGA pakai basis 10000 (raw).
# Pilih nilai yang exact di basis 10000 supaya tak ada isu pembulatan.
P_GTPU, P_GTPC, P_PFCP, P_BSSGP, P_OTHER = 78.20, 9.10, 6.40, 3.00, 3.30


def main():
    out_dir = os.path.join(HERE, "vectors")
    os.makedirs(out_dir, exist_ok=True)

    rows = []
    rows.append(("01", C.pack_global(TS, TOTAL_IMSI, UL_PPS, DL_PPS,
                                     ACTIVE_TEID, TOTAL_BYTES, DROP)))
    rows.append(("02", C.pack_teid(TEID, IMSI, QFI, STATE, UL_PKTS, DL_PKTS)))
    rows.append(("03", C.pack_event(EV_TYPE, EV_DIR, EV_TEID, EV_PLEN, EV_TS)))
    rows.append(("04", C.pack_protocol(P_GTPU, P_GTPC, P_PFCP, P_BSSGP, P_OTHER)))

    path = os.path.join(out_dir, "golden.txt")
    with open(path, "w") as f:
        for mtype, dgram in rows:
            f.write(f"{mtype} {dgram.hex()}\n")

    print(f"[golden] tulis {len(rows)} vektor -> {path}")
    for mtype, dgram in rows:
        print(f"  0x{mtype}  len={len(dgram):2d}B  {dgram.hex()}")
        # sanity: roundtrip decode
        dec = C.decode(dgram)
        print(f"        decode: {dec['type']}")


if __name__ == "__main__":
    main()
