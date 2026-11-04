"""Kontrol stack LTE simulasi (Open5GS + srsRAN) lewat scripts/stack/stackctl.sh.

Hanya aksi tetap yang boleh dipanggil (status/up/capture/down). Aktif bila FALCON_STACK_DIR menunjuk
direktori stack yang ada; selain itu status = "not-installed" (mis. demo publik di RPi).
"""
from __future__ import annotations

import asyncio
import json
import os
import time

STACK_DIR = os.environ.get("FALCON_STACK_DIR", "").strip()
CTL = os.environ.get("FALCON_STACKCTL",
                     os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "stack", "stackctl.sh"))
PCAP = os.path.join(STACK_DIR, "pcap", "stack-lte.pcap") if STACK_DIR else ""
_ALLOWED = {"status", "up", "capture", "down"}

job = {"phase": "idle", "msg": "", "since": 0, "log": []}
_cache = {"t": 0.0, "v": None}
_lock = asyncio.Lock()


def installed() -> bool:
    return bool(STACK_DIR) and os.path.isdir(STACK_DIR) and os.path.exists(CTL)


def _set(phase: str, msg: str = "") -> None:
    job.update({"phase": phase, "msg": msg, "since": int(time.time())})
    if msg:
        job["log"] = (job["log"] + ["%s  %s" % (time.strftime("%H:%M:%S"), msg)])[-12:]


async def _run(action: str, *args: str, timeout: int = 120):
    assert action in _ALLOWED
    env = dict(os.environ, FALCON_STACK_DIR=STACK_DIR)
    p = await asyncio.create_subprocess_exec(
        "bash", CTL, action, *args, env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout)
    except asyncio.TimeoutError:
        p.kill()
        return 124, "", "timeout %ds" % timeout
    return p.returncode, out.decode(errors="replace").strip(), err.decode(errors="replace").strip()


async def status(max_age: float = 4.0) -> dict:
    if not installed():
        return {"state": "not-installed", "detail": "FALCON_STACK_DIR belum diatur / stack tidak ada di host ini."}
    if _cache["v"] is not None and time.time() - _cache["t"] < max_age:
        return _cache["v"]
    rc, out, err = await _run("status", timeout=30)
    try:
        v = json.loads(out)
    except ValueError:
        v = {"state": "error", "detail": (err or out or "status gagal")[-200:]}
    _cache.update({"t": time.time(), "v": v})
    return v


def busy() -> bool:
    return job["phase"] in ("up", "capture", "down")


async def prepare(keep_running: bool, secs: int = 12, pps: int = 120) -> None:
    """Nyalakan stack -> tangkap GTP-U -> (opsional) matikan stack untuk hemat RAM."""
    async with _lock:
        try:
            _set("up", "menyalakan EPC + eNB + UE (±40-60 dtk)")
            rc, _, err = await _run("up", timeout=240)
            if rc != 0:
                _set("error", "gagal menyalakan stack: " + (err.splitlines()[-1] if err else "rc=%d" % rc))
                return
            _set("capture", "UE attach OK; menangkap GTP-U S1-U %d dtk" % secs)
            rc, _, err = await _run("capture", str(secs), str(pps), timeout=secs + 60)
            if rc != 0:
                _set("error", "tangkapan gagal: " + (err.splitlines()[-1] if err else "rc=%d" % rc))
                return
            if not keep_running:
                _set("down", "tangkapan selesai; mematikan stack (hemat RAM)")
                await _run("down", timeout=90)
            _set("done", "siap diputar ulang ke board")
        finally:
            _cache["t"] = 0.0


async def shutdown() -> None:
    async with _lock:
        _set("down", "mematikan stack")
        rc, _, err = await _run("down", timeout=90)
        _cache["t"] = 0.0
        _set("idle" if rc == 0 else "error", "stack mati" if rc == 0 else "down gagal: " + err[-120:])
