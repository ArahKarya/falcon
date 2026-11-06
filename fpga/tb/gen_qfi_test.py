#!/usr/bin/env python3
"""gen_qfi_test.py — vektor uji parser untuk GTP-U BERHEADER EKSTENSI QFI (flags 0x34, ext 0x85).

Sumber frame: pcap contoh milik niloysh/5g-traffic-generator (MIT) yang disalin ke
vectors/ref_gtpu_qfi.pcap = bentuk di-kawat asli dari generator rujukan, bukan karangan kita.
Output vectors/qfi_frames.txt: '<teid_hex8> <dport_hex4> <frame_hex>' (format sama dgn imsi_frames.txt).
"""
import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(HERE, "vectors", "ref_gtpu_qfi.pcap")
out = os.path.join(HERE, "vectors", "qfi_frames.txt")
n = 0
with open(src, "rb") as f, open(out, "w") as o:
    f.read(24)
    while True:
        h = f.read(16)
        if len(h) < 16:
            break
        fr = f.read(struct.unpack("<I", h[8:12])[0])
        if len(fr) < 14 + 20 + 8 + 16 or fr[12:14] != b"\x08\x00" or fr[14 + 9] != 17:
            continue
        g = fr[42:]
        if g[0] != 0x34 or g[1] != 0xFF:
            continue
        o.write("%s %04x %s\n" % (g[4:8].hex(), struct.unpack(">H", fr[36:38])[0], fr.hex()))
        n += 1
print("[qfi] %d frame -> %s" % (n, out))
if n == 0:
    sys.exit(1)
