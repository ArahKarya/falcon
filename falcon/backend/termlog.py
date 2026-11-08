"""Terminal proses FPGA untuk halaman Setup (hanya baca).

Satu bus log di memori (ring buffer): tiap baris punya id naik, waktu, sumber, tingkat, teks.
Sumber baris:
  * keluaran asli skrip tetap (fpgactl.sh / stackctl.sh), dibaca BARIS DEMI BARIS saat proses berjalan,
  * kejadian otomatis backend (link papan, demo traffic, generator).

Prinsip:
  * HANYA BACA. Tidak ada jalur perintah dari klien ke sini.
  * Teks DISARING sebelum masuk buffer: IMSI disamarkan, jalur absolut host dipendekkan, rahasia dibuang.
  * Hanya di memori (hilang saat restart). Tidak ditulis ke disk.
"""
from __future__ import annotations

import asyncio
import collections
import os
import re
import time

MAX_LINES = int(os.environ.get("FALCON_TERM_LINES", "500"))
MAX_LEN = 220
_buf: "collections.deque[dict]" = collections.deque(maxlen=MAX_LINES)
_seq = [0]
_subs: "set[asyncio.Queue]" = set()

# ---- penyaring --------------------------------------------------------------
_IMSI = re.compile(r"(?<!\d)(\d{3})(\d{12})(?!\d)")                 # 15 digit berurutan
_SECRET = re.compile(r"(?i)\b(pass(?:word|wd)?|sandi|token|secret|api[_-]?key|authorization|cookie)\b\s*[:=]\s*\S+")
_BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]+")
_HOME = re.compile(r"/(?:home|Users)/[^/\s]+")
_DATA = re.compile(r"/data/[A-Za-z0-9_.\-]+/")
_ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

# Baris iMPACT yang hanya kebisingan (tabel preferensi, pesan lisensi/driver berulang).
_NOISE = re.compile(r"^(Preference Table|Name\s+Setting|StartupClock|AutoSignature|KeepSVF|ConcurrentMode|UseHighz|"
                    r"ConfigOnFailure|UserLevel|MessageLevel|svfUseTime|SpiByteSwap|AutoInfer|SvfPlayDisplayComments|"
                    r"-{10,}|iMPACT Version|iMPACT log file|File version of|If you are using the Platform|"
                    r"Installation Guide|PLD file version|Firmware hex file|ESN device|\*{3} WARNING)")

# Frasa asli iMPACT/skrip -> ringkasan Indonesia + tingkat. Urutan = prioritas.
_MAP = [
    (re.compile(r"Connecting to cable"),            "Menghubungkan ke kabel JTAG (Platform Cable USB II)", "info"),
    (re.compile(r"Cable connection established"),   "Kabel JTAG tersambung", "ok"),
    (re.compile(r"Firmware version = (\d+)"),       None, "info"),
    (re.compile(r"Identifying chain contents.*xc5vlx50t"), "Rantai JTAG terbaca: Xilinx xc5vlx50t terdeteksi", "ok"),
    (re.compile(r"Identifying chain contents"),     "Membaca isi rantai JTAG", "info"),
    (re.compile(r"Added Device xc5vlx50t"),         "Perangkat xc5vlx50t ditambahkan ke sesi iMPACT", "info"),
    (re.compile(r"Loading file '([^']+)'"),         None, "info"),
    (re.compile(r"Startup Clock has been changed"), "Clock startup diubah ke JtagClk (di memori, berkas asli tak berubah)", "info"),
    (re.compile(r"UserID read from"),               "UserID bitstream terbaca", "info"),
    (re.compile(r"Programming device", re.I),       "Memprogram FPGA (mengirim bitstream lewat JTAG)", "info"),
    (re.compile(r"Programmed successfully"),        "Pemrograman FPGA BERHASIL", "ok"),
    (re.compile(r"Checking done pin"),              "Pin DONE diperiksa", "info"),
    (re.compile(r"DONE pin OK"),                    "Pin DONE tinggi: FPGA terkonfigurasi", "ok"),
    (re.compile(r"PROGRAM FAILED|ERROR:iMPACT", re.I), None, "err"),
    (re.compile(r"telemetri masuk"),                "Telemetri dari papan terlihat di jaringan", "ok"),
    (re.compile(r"tunggu telemetri"),               "Menunggu telemetri papan (maks 25 dtk)", "info"),
]


def clean(text: str) -> str:
    t = _ANSI.sub("", text).replace("\r", "").strip()
    t = _SECRET.sub(lambda m: m.group(1) + "=[disamarkan]", t)
    t = _BEARER.sub("bearer [disamarkan]", t)
    t = _IMSI.sub(lambda m: m.group(1) + "*" * 12, t)       # sama dgn aturan IMSI di PR #19
    t = _HOME.sub("~", t)
    t = _DATA.sub(".../", t)
    return t[:MAX_LEN]


def _translate(line: str):
    """-> (teks, level) atau None bila kebisingan."""
    if not line or _NOISE.match(line):
        return None
    for pat, text, level in _MAP:
        m = pat.search(line)
        if not m:
            continue
        if text is not None:
            return text, level
        if pat.pattern.startswith("Firmware"):
            return "Firmware kabel versi " + m.group(1), "info"
        if pat.pattern.startswith("Loading"):
            return "Memuat bitstream: " + os.path.basename(m.group(1)), "info"
        return line, level            # err: tampilkan baris asli (sudah disaring clean())
    low = line.lower()
    level = "err" if ("error" in low or "gagal" in low or "failed" in low) else \
            "warn" if ("warn" in low or "peringatan" in low) else "info"
    return line, level


def add(source: str, text: str, level: str = "info") -> dict | None:
    text = clean(str(text))
    if not text:
        return None
    _seq[0] += 1
    row = {"id": _seq[0], "ts": round(time.time(), 3), "src": source, "lvl": level, "text": text}
    _buf.append(row)
    for q in list(_subs):
        try:
            q.put_nowait(row)
        except asyncio.QueueFull:
            _subs.discard(q)
    return row


def add_raw(source: str, raw_line: str):
    """Baris mentah dari proses -> disaring, diterjemahkan, dicatat (kebisingan dibuang)."""
    line = clean(raw_line)
    tr = _translate(line)
    if tr:
        add(source, tr[0], tr[1])


def since(last_id: int = 0, source: str | None = None, limit: int = 300) -> list:
    rows = [r for r in _buf if r["id"] > last_id and (not source or r["src"] == source)]
    return rows[-limit:]


def subscribe() -> asyncio.Queue:
    q: asyncio.Queue = asyncio.Queue(maxsize=200)
    _subs.add(q)
    return q


def unsubscribe(q) -> None:
    _subs.discard(q)


def clear() -> None:
    _buf.clear()


async def stream_proc(source: str, *argv: str, env: dict | None = None, timeout: int = 120,
                      stdin_devnull: bool = True):
    """Jalankan proses tetap, alirkan stdout+stderr BARIS DEMI BARIS ke terminal. -> (rc, tail_stderr)."""
    p = await asyncio.create_subprocess_exec(
        *argv, env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
        stdin=asyncio.subprocess.DEVNULL if stdin_devnull else None)
    tail: "collections.deque[str]" = collections.deque(maxlen=6)

    async def pump():
        assert p.stdout is not None
        while True:
            b = await p.stdout.readline()
            if not b:
                return
            line = b.decode(errors="replace").rstrip("\n")
            if line.strip():
                tail.append(clean(line))
                add_raw(source, line)

    try:
        await asyncio.wait_for(asyncio.gather(pump(), p.wait()), timeout)
    except asyncio.TimeoutError:
        p.kill()
        add(source, "melebihi batas waktu %d dtk, proses dihentikan" % timeout, "err")
        return 124, "timeout %ds" % timeout
    return p.returncode, "\n".join(tail)
