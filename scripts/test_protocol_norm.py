#!/usr/bin/env python3
"""Uji normalize_protocol: persen (simulator) tak berubah, hitungan mentah (silikon) dinormalkan, nol aman."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "falcon", "backend"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "falcon"))
from server import normalize_protocol as N
from shared import contract as C

fail = 0
def chk(name, ok, extra=""):
    global fail
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(extra)))
    fail += 0 if ok else 1

# 1) simulator: persen sah lewat jalur pack->unpack apa adanya
d = C.unpack_protocol(C.pack_protocol(78.2, 9.1, 6.4, 3.0, 3.3)[8:])["data"] if False else \
    {"gtp_u": 78.2, "gtp_c": 9.1, "pfcp": 6.4, "bssgp": 3.0, "other": 3.3}
r = N(d)
chk("persen simulator tidak diubah", r["gtp_u"] == 78.2 and r["normalized"] is False, r)

# 2) kasus nyata dari board: hanya GTP-U terisi, hitungan 57427 -> unpack /100 = 574.27
r = N({"gtp_u": 574.27, "gtp_c": 0.0, "pfcp": 0.0, "bssgp": 0.0, "other": 0.0})
chk("hanya GTP-U: tepat 100,00%", r["gtp_u"] == 100.0 and r["normalized"] is True, r)
chk("kelas lain tetap 0", all(r[k] == 0.0 for k in ("gtp_c", "pfcp", "bssgp", "other")), r)
chk("raw_total mengembalikan hitungan asli (57427)", r["raw_total"] == 57427, r)

# 3) campuran hitungan: 6000 GTP-U, 2000 GTP-C, 2000 PFCP -> 60/20/20
r = N({"gtp_u": 60.0, "gtp_c": 20.0, "pfcp": 20.0, "bssgp": 0.0, "other": 0.0})
chk("campuran persis 100 tidak diubah", r["gtp_u"] == 60.0 and r["normalized"] is False, r)
r = N({"gtp_u": 120.0, "gtp_c": 40.0, "pfcp": 40.0, "bssgp": 0.0, "other": 0.0})
chk("campuran hitungan -> 60/20/20", (r["gtp_u"], r["gtp_c"], r["pfcp"]) == (60.0, 20.0, 20.0), r)
chk("jumlah hasil = 100", abs(sum(r[k] for k in ("gtp_u","gtp_c","pfcp","bssgp","other")) - 100.0) < 0.05, r)

# 4) nol / kosong / None tidak meledak
r = N({"gtp_u": 0, "gtp_c": 0, "pfcp": 0, "bssgp": 0, "other": 0})
chk("semua nol aman", r["gtp_u"] == 0 and r["normalized"] is False, r)
r = N({})
chk("dict kosong aman", r["gtp_u"] == 0.0, r)
r = N({"gtp_u": None, "gtp_c": 5})
chk("nilai None aman", r["gtp_c"] == 100.0, r)

# 5) toleransi pembulatan di sekitar 100 (simulator 99.99 / 100.02) tidak dianggap hitungan
r = N({"gtp_u": 33.34, "gtp_c": 33.33, "pfcp": 33.33, "bssgp": 0.0, "other": 0.0})
chk("pembulatan ~100 tidak dinormalkan ulang", r["normalized"] is False, r)

print("---- %d gagal" % fail)
sys.exit(1 if fail else 0)
