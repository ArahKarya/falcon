"""traffic5g — simulator trafik 5G user-plane (GTP-U + ekstensi QFI) berbasis profil aplikasi nyata.

JUJUR soal asal data: bentuk paket (flags 0x34, ekstensi PDU Session Container 0x85, QFI di byte 14)
dan 8 profil aplikasi (histogram ukuran, jeda antarpaket, pola burst per detik) diambil dari proyek
niloysh/5g-traffic-generator (MIT, profiles/LICENSE-5g-traffic-generator), yang profilnya diturunkan
dari rekaman trafik aplikasi nyata. Yang SINTETIS: urutan paket, isi paket, dan pembagian ke sesi UE.
Jadi ini 'trafik buatan berstatistik nyata', BUKAN trafik jaringan operator.

Modul murni (tanpa asyncio/socket): Generator.next_batch(dt) mengembalikan paket yang jatuh tempo
dalam dt detik. Pengirim (server.py) hanya mengalirkannya ke UDP :2152 board.
"""
from __future__ import annotations

import json
import os
import random
import struct
from typing import Dict, List, Optional, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILE_PATH = os.path.join(HERE, "profiles", "app_profiles.json")

GTPU_HDR_LEN = 16            # 8 dasar + 3 (seq,npdu,next) + 5 ekstensi QFI
UDP_PAYLOAD_MAX = 1472       # MTU 1500 - IPv4 20 - UDP 8. Lebih besar = kernel memecah jadi fragmen IP; fragmen
                             # ke-2 tak punya header UDP, jadi gateware tak menghitungnya (selisih byte terukur di papan).
BUCKETS = (("<100", None, 99), ("100-299", 100, 299), ("300-599", 300, 599),
           ("600-899", 600, 899), ("900-1199", 900, 1199), (">=1200", 1200, None))
TEID_BASE = 0x2000           # sama dengan pemetaan TEID di repo rujukan
MAX_INNER = UDP_PAYLOAD_MAX - GTPU_HDR_LEN   # = 1456: paket UE terbesar agar datagram UDP muat satu frame
TICK_MAX_BURST = 4000        # batas paket per next_batch agar tak membanjiri satu tick

# Komposisi bawaan = teid_share_per_app dari config/teid_map_1000.json repo rujukan.
MIX_DEFAULT = {"battlegrounds": 0.10, "roblox": 0.08, "geforce": 0.15, "zoom": 0.07, "teams": 0.07,
               "youtubelive": 0.18, "netflix": 0.18, "best-effort": 0.17}
MIX_PRESETS = {
    "campuran": MIX_DEFAULT,
    "video": {"netflix": 0.45, "youtubelive": 0.45, "best-effort": 0.10},
    "game": {"battlegrounds": 0.35, "roblox": 0.25, "geforce": 0.35, "best-effort": 0.05},
    "konferensi": {"zoom": 0.45, "teams": 0.45, "best-effort": 0.10},
}


def load_profiles(path: str = PROFILE_PATH) -> Dict[str, dict]:
    with open(path) as f:
        return json.load(f)


def build_gtpu(teid: int, qfi: int, inner: bytes) -> bytes:
    """GTP-U G-PDU berekstensi QFI, byte-identik dengan generator rujukan (diuji vs pcap contoh)."""
    ln = len(inner) + 8   # 3 (seq,npdu,next) + 5 (ekstensi) di luar 8 byte dasar
    return struct.pack(">BBHI", 0x34, 0xFF, ln, teid) + b"\x00\x00\x00\x85\x01\x10" + bytes([qfi & 0x3F, 0x00]) + inner


def parse_gtpu(pl: bytes) -> dict:
    return {"flags": pl[0], "mtype": pl[1], "length": struct.unpack(">H", pl[2:4])[0],
            "teid": struct.unpack(">I", pl[4:8])[0], "ext": pl[11], "qfi": pl[14] & 0x3F,
            "inner_len": len(pl) - GTPU_HDR_LEN}


class Session:
    __slots__ = ("teid", "app", "qfi", "phase", "weight")

    def __init__(self, teid: int, app: str, qfi: int, phase: int, weight: float):
        self.teid, self.app, self.qfi, self.phase, self.weight = teid, app, qfi, phase, weight


class Generator:
    """Pembangkit trafik. Semua acak lewat satu RNG berbenih -> hasil dapat diulang (uji, demo)."""

    def __init__(self, pps: float = 500.0, mix: Optional[Dict[str, float]] = None, ues: int = 64,
                 seed: int = 5152, burst: float = 1.0, profiles: Optional[Dict[str, dict]] = None):
        self.profiles = profiles if profiles is not None else load_profiles()
        mix = dict(mix or MIX_DEFAULT)
        mix = {a: float(w) for a, w in mix.items() if a in self.profiles and float(w) > 0}
        if not mix:
            raise ValueError("komposisi kosong atau aplikasi tak dikenal")
        if not 1 <= int(ues) <= 1000:
            raise ValueError("ues harus 1..1000")
        self.pps = float(pps)
        self.burst = max(0.0, min(1.0, float(burst)))
        self.rng = random.Random(seed)
        tot = sum(mix.values())
        self.mix = {a: w / tot for a, w in mix.items()}
        self.t = 0.0                     # waktu simulasi (detik)
        self._carry = 0.0                # sisa paket pecahan antar tick
        self.sent_pkts = 0
        self.sent_bytes = 0              # byte payload GTP-U (yang dihitung gateware sebagai total_bytes)
        self.per_app: Dict[str, List[int]] = {a: [0, 0] for a in self.mix}
        self.per_teid: Dict[int, List[int]] = {}
        self._anom: List[dict] = []
        # alokasi sesi: jumlah UE per aplikasi mengikuti komposisi (minimal 1 per aplikasi bila muat)
        self.sessions: List[Session] = []
        counts = {a: max(1, round(self.mix[a] * ues)) for a in self.mix}
        while sum(counts.values()) > ues and max(counts.values()) > 1:
            counts[max(counts, key=counts.get)] -= 1
        i = 0
        for a, n in counts.items():
            prof = self.profiles[a]
            for _ in range(n):
                self.sessions.append(Session(TEID_BASE + i, a, int(prof.get("qfi", 9)),
                                             self.rng.randrange(0, 3600), self.rng.uniform(0.5, 1.5)))
                i += 1
        self.by_app: Dict[str, List[Session]] = {}
        for s in self.sessions:
            self.by_app.setdefault(s.app, []).append(s)
        # tabel ukuran per aplikasi
        self._sizes = {a: self._size_table(self.profiles[a]["stats"]["packet_size"]) for a in self.mix}
        self._shape = {a: self._trace_shape(self.profiles[a]["stats"]) for a in self.mix}

    # ---------- bentuk burst ----------
    MIN_TRACE = 30   # trace lebih pendek dari ini = potongan, bukan pola; diabaikan

    @classmethod
    def _trace_shape(cls, stats: dict) -> Optional[List[float]]:
        """burst_trace.pps dinormalkan ke rata-ratanya SENDIRI (hanya bentuk). Rata-rata trace di profil rujukan
        tak sama dengan 'pps' profil (rasio 0.02-1.04) dan 5 dari 8 trace hanya 4-26 titik, jadi pemakaian
        apa adanya (seperti generator rujukan: trace/pps) menjepit laju salah. Trace pendek -> None (tanpa burst)."""
        tr = (stats.get("burst_trace") or {}).get("pps") or []
        if len(tr) < cls.MIN_TRACE:
            return None
        m = sum(tr) / len(tr)
        if m <= 0:
            return None
        return [x / m for x in tr]

    # ---------- ukuran ----------
    @staticmethod
    def _size_table(ps: dict) -> List[Tuple[int, int, int]]:
        lo_all, hi_all = max(20, int(ps.get("min", 20))), min(MAX_INNER, int(ps.get("max", MAX_INNER)))
        tab = []
        for name, lo, hi in BUCKETS:
            n = int(ps.get("buckets", {}).get(name, 0))
            if n <= 0:
                continue
            a = max(lo_all, lo if lo is not None else lo_all)
            b = min(hi_all, hi if hi is not None else hi_all)
            if a <= b:
                tab.append((n, a, b))
        if not tab:
            tab = [(1, lo_all, max(lo_all, hi_all))]
        return tab

    def sample_size(self, app: str) -> int:
        tab = self._sizes[app]
        r = self.rng.randrange(sum(n for n, _, _ in tab))
        for n, a, b in tab:
            if r < n:
                return self.rng.randint(a, b)
            r -= n
        return tab[-1][2]

    # ---------- laju ----------
    def _burst_mult(self, app: str, ph: int = 0) -> float:
        """Pengali laju dari BENTUK burst_trace (rata-rata 1.0), dijepit 0.2..5, diskalakan oleh self.burst."""
        sh = self._shape[app]
        if sh is None or self.burst <= 0:
            return 1.0
        m = min(5.0, max(0.2, sh[(int(self.t) + ph) % len(sh)]))
        return 1.0 + self.burst * (m - 1.0)

    def _anom_mult(self, app: str, teid: int) -> float:
        m = 1.0
        for an in self._anom:
            if an["until"] <= self.t:
                continue
            if (an["app"] is None or an["app"] == app) and (an["teid"] is None or an["teid"] == teid):
                m *= an["factor"]
        return m

    def inject(self, factor: float, seconds: float, app: Optional[str] = None, teid: Optional[int] = None) -> dict:
        """Lonjakan laju terkendali (mirip anomaly injection repo rujukan): kalikan laju app/TEID tertentu."""
        if app is not None and app not in self.mix:
            raise ValueError("aplikasi tidak ada dalam komposisi")
        if teid is not None and teid not in {s.teid for s in self.sessions}:
            raise ValueError("TEID tidak ada")
        if not 1.0 <= float(factor) <= 20.0 or not 1 <= float(seconds) <= 600:
            raise ValueError("factor 1..20, seconds 1..600")
        an = {"app": app, "teid": teid, "factor": float(factor), "until": self.t + float(seconds)}
        self._anom = [a for a in self._anom if a["until"] > self.t] + [an]
        return an

    def active_anomalies(self) -> List[dict]:
        return [dict(a, remaining=round(a["until"] - self.t, 1)) for a in self._anom if a["until"] > self.t]

    def weights(self) -> List[Tuple[Session, float]]:
        out = []
        for s in self.sessions:
            w = self.mix[s.app] / len(self.by_app[s.app]) * s.weight
            out.append((s, w * self._burst_mult(s.app, s.phase) * self._anom_mult(s.app, s.teid)))
        return out

    # ---------- keluaran ----------
    def _inner(self, size: int) -> bytes:
        body = bytes(self.rng.getrandbits(8) for _ in range(max(0, size - 20)))
        # kepala IPv4 minimal yang masuk akal (tak dipakai gateware, tapi Wireshark tak mengeluh)
        return struct.pack(">BBHHHBBH4s4s", 0x45, 0, size, self.rng.getrandbits(16), 0x4000, 64,
                           self.rng.choice((6, 17)), 0, b"\x0a\x2d\x00\x01", b"\x08\x08\x08\x08")[:20] + body

    def next_batch(self, dt: float) -> List[Tuple[bytes, int, str]]:
        """Paket yang jatuh tempo selama dt detik: [(payload_gtpu, teid, app)]. Memajukan waktu simulasi."""
        ws = self.weights()
        wsum = sum(w for _, w in ws)
        base = sum(self.mix[s.app] / len(self.by_app[s.app]) * s.weight for s, _ in ws)
        # laju total ikut pola burst/anomali relatif terhadap kondisi tanpa modulasi
        rate = self.pps * (wsum / base if base > 0 else 1.0)
        self._carry += rate * dt
        n = int(self._carry)
        self._carry -= n
        n = min(n, TICK_MAX_BURST)
        out = []
        if n > 0 and wsum > 0:
            picks = self.rng.choices([s for s, _ in ws], weights=[w for _, w in ws], k=n)
            for s in picks:
                pl = build_gtpu(s.teid, s.qfi, self._inner(self.sample_size(s.app)))
                out.append((pl, s.teid, s.app))
                self.sent_pkts += 1
                self.sent_bytes += len(pl)
                pa = self.per_app[s.app]
                pa[0] += 1
                pa[1] += len(pl)
                pt = self.per_teid.setdefault(s.teid, [0, 0])
                pt[0] += 1
                pt[1] += len(pl)
        self.t += dt
        return out

    def snapshot(self) -> dict:
        return {"pps_target": self.pps, "sessions": len(self.sessions), "sent_pkts": self.sent_pkts,
                "sent_bytes": self.sent_bytes, "t": round(self.t, 1),
                "mix": {a: round(w, 3) for a, w in self.mix.items()},
                "per_app": {a: {"pkts": v[0], "bytes": v[1]} for a, v in self.per_app.items()},
                "anomalies": self.active_anomalies()}

    def teid_apps(self) -> Dict[int, dict]:
        return {s.teid: {"app": s.app, "qfi": s.qfi} for s in self.sessions}
