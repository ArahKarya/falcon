#!/usr/bin/env python3
"""Uji traffic5g: bentuk paket vs pcap rujukan, distribusi ukuran/laju/komposisi, burst, anomali, determinisme."""
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "falcon", "backend"))
import gtpu_pcap          # noqa: E402
import traffic5g as T     # noqa: E402

REF = os.path.join(HERE, "..", "fpga", "tb", "vectors", "ref_gtpu_qfi.pcap")
ok = fail = 0


def chk(name, cond, extra=""):
    global ok, fail
    if cond:
        ok += 1
        print("PASS", name)
    else:
        fail += 1
        print("FAIL", name, extra)


def run(g, secs, dt=0.02):
    pk = []
    for _ in range(int(secs / dt)):
        pk += g.next_batch(dt)
    return pk


# 1. bentuk di-kawat identik dgn generator rujukan (50 paket nyata dari pcap contoh)
ref = gtpu_pcap.gtpu_payloads(REF)
same = 0
for p in ref:
    h = T.parse_gtpu(p)
    q = T.build_gtpu(h["teid"], h["qfi"], p[T.GTPU_HDR_LEN:])
    same += (q == p)
chk("bentuk byte-identik dgn %d paket rujukan" % len(ref), len(ref) == 50 and same == len(ref), "%d/%d" % (same, len(ref)))
h = T.parse_gtpu(ref[0])
chk("rujukan: flags 0x34, mtype 0xFF, ext 0x85", (h["flags"], h["mtype"], h["ext"]) == (0x34, 0xFF, 0x85))

# 2. tiap paket yang dibangkitkan valid & length konsisten
g = T.Generator(pps=800, ues=64, seed=1)
pk = run(g, 10)
bad = [1 for pl, _, _ in pk if (lambda h: h["flags"] != 0x34 or h["mtype"] != 0xFF or h["ext"] != 0x85
                                or h["length"] != len(pl) - 8 or len(pl) > 1500 or len(pl) < T.GTPU_HDR_LEN + 20)(T.parse_gtpu(pl))]
chk("semua paket valid (flags/ext/length/MTU)", pk and not bad, "%d buruk dari %d" % (len(bad), len(pk)))

# 2b. TIDAK ADA paket melebihi payload UDP maksimum (kalau lebih, kernel memecah -> gateware kehilangan byte)
g = T.Generator(pps=4000, burst=0.0, seed=11)
big = [len(pl) for pl, _, _ in run(g, 30) if len(pl) > T.UDP_PAYLOAD_MAX]
chk("tak ada paket > %d byte (cegah fragmentasi IP)" % T.UDP_PAYLOAD_MAX, not big, "%d paket, maks %s" % (len(big), max(big) if big else 0))
for app in T.load_profiles():
    gg = T.Generator(pps=2000, mix={app: 1.0}, ues=4, burst=0.0, seed=12)
    mx = max(len(pl) for pl, _, _ in run(gg, 10))
    chk("%s: ukuran maks %d <= %d" % (app, mx, T.UDP_PAYLOAD_MAX), mx <= T.UDP_PAYLOAD_MAX)

# 3. laju rata-rata ~ target (burst dimatikan agar murni)
for target in (100, 500, 2000, 4000):
    g = T.Generator(pps=target, burst=0.0, seed=2)
    n = len(run(g, 20))
    chk("laju %d pps: terukur %.1f" % (target, n / 20.0), abs(n / 20.0 - target) <= target * 0.01 + 1)

# 4. komposisi sesuai mix
g = T.Generator(pps=2000, burst=0.0, seed=3)
pk = run(g, 30)
cnt = collections.Counter(a for _, _, a in pk)
tot = sum(cnt.values())
worst = max(abs(cnt[a] / tot - w) for a, w in g.mix.items())
chk("komposisi paket ~ mix (selisih maks %.3f)" % worst, worst < 0.03)

# 5. distribusi ukuran per aplikasi ~ histogram profil
prof = T.load_profiles()
for app in ("netflix", "battlegrounds", "zoom"):
    g = T.Generator(pps=1000, mix={app: 1.0}, burst=0.0, ues=8, seed=4)
    sz = [len(p) - T.GTPU_HDR_LEN for p, _, _ in run(g, 40)]
    b = prof[app]["stats"]["packet_size"]["buckets"]
    n = sum(b.values())
    edges = [(0, 99), (100, 299), (300, 599), (600, 899), (900, 1199), (1200, 99999)]
    keys = ["<100", "100-299", "300-599", "600-899", "900-1199", ">=1200"]
    d = 0.0
    for (lo, hi), k in zip(edges, keys):
        frac = sum(1 for s in sz if lo <= s <= hi) / len(sz)
        d = max(d, abs(frac - b[k] / n))
    chk("%s: ukuran ~ histogram profil (selisih maks %.3f)" % (app, d), d < 0.03)
    st = prof[app]["stats"]["packet_size"]
    chk("%s: ukuran dalam [min,max] profil" % app, min(sz) >= max(20, st["min"]) and max(sz) <= min(st["max"], T.MAX_INNER))

# 6. TEID unik per sesi, QFI mengikuti profil
g = T.Generator(pps=500, ues=64, seed=5)
teids = [s.teid for s in g.sessions]
chk("TEID unik (%d sesi)" % len(teids), len(set(teids)) == len(teids) <= 64)
chk("QFI sesuai profil", all(s.qfi == prof[s.app]["qfi"] for s in g.sessions))
pk = run(g, 5)
ta = g.teid_apps()
chk("TEID paket terdaftar & app cocok", all(t in ta and ta[t]["app"] == a for _, t, a in pk))

# 7. determinisme (benih sama -> urutan sama; benih beda -> beda)
a = run(T.Generator(pps=300, seed=9), 3)
b = run(T.Generator(pps=300, seed=9), 3)
c = run(T.Generator(pps=300, seed=10), 3)
chk("benih sama -> identik", [x[0] for x in a] == [x[0] for x in b])
chk("benih beda -> berbeda", [x[0] for x in a] != [x[0] for x in c])

# 8. burst: laju total berfluktuasi mengikuti burst_trace; burst=0 rata
g1 = T.Generator(pps=1000, burst=1.0, mix={"netflix": 1.0}, ues=4, seed=6)
g0 = T.Generator(pps=1000, burst=0.0, mix={"netflix": 1.0}, ues=4, seed=6)
per1 = [len(run(g1, 1)) for _ in range(30)]
per0 = [len(run(g0, 1)) for _ in range(30)]
chk("burst=1: laju per detik bervariasi (min %d, maks %d)" % (min(per1), max(per1)), max(per1) - min(per1) > 150)
chk("burst=1: rata-rata tetap ~target (%.0f)" % (sum(per1) / len(per1)), abs(sum(per1) / len(per1) - 1000) < 150)
g2 = T.Generator(pps=1000, burst=1.0, mix={"teams": 1.0}, ues=4, seed=6)
per2 = [len(run(g2, 1)) for _ in range(15)]
chk("trace pendek (teams, 4 titik) diabaikan: laju rata", max(per2) - min(per2) <= 2, str(per2))
chk("burst=0: laju per detik rata (min %d, maks %d)" % (min(per0), max(per0)), max(per0) - min(per0) <= 2)

# 9. anomali: lonjakan hanya pada app target, lalu pulih
g = T.Generator(pps=1000, burst=0.0, seed=7)
base = collections.Counter(a for _, _, a in run(g, 10))
g.inject(factor=8, seconds=10, app="roblox")
spike = collections.Counter(a for _, _, a in run(g, 10))
after = collections.Counter(a for _, _, a in run(g, 10))
chk("lonjakan roblox x%.1f" % (spike["roblox"] / base["roblox"]), spike["roblox"] > base["roblox"] * 3)
chk("app lain tak ikut melonjak", abs(spike["zoom"] / base["zoom"] - 1) < 0.5)
chk("pulih setelah anomali habis", after["roblox"] < base["roblox"] * 1.4)
try:
    g.inject(50, 5)
    chk("tolak factor di luar batas", False)
except ValueError:
    chk("tolak factor di luar batas", True)
try:
    g.inject(2, 5, app="tidak-ada")
    chk("tolak app tak dikenal", False)
except ValueError:
    chk("tolak app tak dikenal", True)

# 10. pembukuan byte = jumlah byte payload (yang dihitung gateware sebagai total_bytes)
g = T.Generator(pps=700, seed=8)
pk = run(g, 6)
chk("sent_bytes == jumlah byte payload", g.sent_bytes == sum(len(p) for p, _, _ in pk) and g.sent_pkts == len(pk))
chk("per_app menjumlah ke total", sum(v[0] for v in g.per_app.values()) == g.sent_pkts)

# 11. validasi masukan
for kw, label in (({"mix": {"xx": 1}}, "mix tak dikenal"), ({"ues": 0}, "ues=0"), ({"ues": 5000}, "ues=5000")):
    try:
        T.Generator(**kw)
        chk("tolak " + label, False)
    except ValueError:
        chk("tolak " + label, True)
chk("preset ada & valid", all(T.Generator(mix=m, ues=16).sessions for m in T.MIX_PRESETS.values()))

print("---- %d lulus, %d gagal" % (ok, fail))
sys.exit(1 if fail else 0)
