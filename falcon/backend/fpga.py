"""Muat ulang gateware ke papan FPGA lewat scripts/fpga/fpgactl.sh (aksi tetap: status, load).

Aktif bila FALCON_FPGACTL menunjuk skrip yang ada. Tanpa itu (mis. demo di host tanpa JTAG) status = "not-installed".
Backend tidak pernah menerima nama berkas atau perintah dari klien: bitstream ditentukan skrip.
"""
from __future__ import annotations

import asyncio
import json
import os
import time

CTL = os.environ.get("FALCON_FPGACTL", "").strip()
job = {"phase": "idle", "msg": "", "since": 0, "log": []}
_cache = {"t": 0.0, "v": None}
_lock = asyncio.Lock()


def installed() -> bool:
    return bool(CTL) and os.path.exists(CTL)


def _set(phase: str, msg: str = "") -> None:
    job.update({"phase": phase, "msg": msg, "since": int(time.time())})
    if msg:
        job["log"] = (job["log"] + ["%s  %s" % (time.strftime("%H:%M:%S"), msg)])[-10:]


async def _run(action: str, timeout: int):
    assert action in ("status", "load")
    p = await asyncio.create_subprocess_exec(
        "bash", CTL, action, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout)
    except asyncio.TimeoutError:
        p.kill()
        return 124, "", "timeout %ds" % timeout
    return p.returncode, out.decode(errors="replace").strip(), err.decode(errors="replace").strip()


async def status(max_age: float = 5.0) -> dict:
    if not installed():
        return {"installed": False}
    if _cache["v"] is not None and time.time() - _cache["t"] < max_age:
        return _cache["v"]
    rc, out, _ = await _run("status", 25)
    try:
        v = json.loads(out)
        v["installed"] = True
    except ValueError:
        v = {"installed": True, "error": "status gagal"}
    _cache.update({"t": time.time(), "v": v})
    return v


def busy() -> bool:
    return job["phase"] == "loading"


# alasan gagal -> kalimat untuk operator (kode keluar fpgactl.sh)
_WHY = {
    2: "bitstream tidak ditemukan di host lab",
    3: "kabel JTAG tidak terdeteksi (cek USB ke papan)",
    4: "shim USB untuk iMPACT tidak ada",
    5: "iMPACT gagal memprogram papan (cek papan menyala dan kabel JTAG)",
    6: "gateware terprogram tetapi telemetri belum terlihat (cek kabel ethernet papan; bila perlu cold boot penuh)",
    9: "operasi lain sedang berjalan",
    124: "melebihi batas waktu",
}


async def load() -> None:
    async with _lock:
        try:
            _set("loading", "memuat gateware ke papan lewat JTAG (±40 dtk)")
            rc, _, err = await _run("load", 150)
            if rc == 0:
                _set("done", "gateware termuat dan telemetri masuk")
            else:
                tail = err.splitlines()[-1] if err else ""
                _set("error", "%s%s" % (_WHY.get(rc, "gagal (kode %d)" % rc), (" — " + tail[:90]) if tail else ""))
        finally:
            _cache["t"] = 0.0
