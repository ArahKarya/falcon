#!/usr/bin/env python3
"""XST menolak sinyal yang dipakai SEBELUM dideklarasikan (iverilog lebih longgar). Cek cepat sebelum sintesis ISE (~6 menit).
Memeriksa: setiap nama 'wire/reg' bervektor yang dideklarasikan di berkas, tidak boleh muncul di berkas lebih awal dari deklarasinya."""
import re, sys
bad = 0
for path in sys.argv[1:]:
    lines = open(path).read().split("\n")
    decl = {}
    for i, l in enumerate(lines):
        code = l.split("//")[0]
        m = re.match(r"\s*(?:wire|reg)\s*(?:\[[^\]]+\])?\s*(.+?);", code)
        if m:
            for nm in re.split(r"\s*,\s*", m.group(1)):
                nm = nm.split("=")[0].strip()
                if re.fullmatch(r"[A-Za-z_]\w*", nm) and nm not in decl:
                    decl[nm] = i
    for nm, di in decl.items():
        pat = re.compile(r"\b" + re.escape(nm) + r"\b")
        for j in range(0, di):
            if pat.search(lines[j].split("//")[0]):
                print(f"{path}:{j+1}: '{nm}' dipakai sebelum dideklarasi (baris {di+1})"); bad += 1; break
print("urutan deklarasi:", "OK" if not bad else f"{bad} masalah")
sys.exit(1 if bad else 0)
