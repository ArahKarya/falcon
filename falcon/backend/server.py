#!/usr/bin/env python3
"""FALCON Backend — UDP telemetry collector + WebSocket push + REST snapshot.
Mirror PRD §6-7.2. Satu proses asyncio.

- UDP :50000  -> decode (shared.contract) -> update state -> broadcast WS
- WS  :8080/ws -> push JSON real-time ke dashboard
- HTTP:8080    -> REST snapshot + serve dashboard statis

Usage: python3 server.py
"""
import asyncio, json, time, sys, os, collections, subprocess
from aiohttp import web
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from shared import contract as C
import auth
import stack
import fpga
import gtpu_pcap
import traffic5g

UDP_PORT = int(os.environ.get("FALCON_UDP_PORT", 50000))
HTTP_PORT = int(os.environ.get("FALCON_HTTP_PORT", 8080))
# FALCON_MODE   : "live" (board nyata, default) | "sim" (simulator; dashboard menampilkan banner SIMULASI)
# FALCON_PUBLIC : "1" => deploy publik: endpoint kontrol generator (POST start/stop) ditolak 403
MODE = os.environ.get("FALCON_MODE", "live").lower()
# FALCON_DEMO_TRAFFIC="sim5g:30:90:120[:preset[:ues]]" => sama, tetapi sumber simulator 5G (traffic5g), mis. sim5g:30:90:120:campuran:48
# FALCON_DEMO_TRAFFIC="burst:30:90:120" => backend sendiri menembakkan traffic GTP-U sintetis ke board
#   (aktif <on> detik @ <pps> paket/dtk, jeda <off> detik). Dashboard menampilkan badge "TRAFIK UJI SINTETIS".
#   Kosong/off = mati. Target: FALCON_DEMO_TARGET (default 192.168.0.20:2152).
DEMO_SPEC = os.environ.get("FALCON_DEMO_TRAFFIC", "").strip()
DEMO_TARGET = os.environ.get("FALCON_DEMO_TARGET", "192.168.0.20:2152")
PUBLIC = os.environ.get("FALCON_PUBLIC", "0") == "1"
DASH_DIR = os.path.join(os.path.dirname(__file__), "..", "dashboard")
GEN_CTL = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "falcon-gen")

PROTO_KEYS = ("gtp_u", "gtp_c", "pfcp", "bssgp", "other")


def normalize_protocol(d: dict) -> dict:
    """Jadikan distribusi protokol selalu PERSEN (0..100, jumlah 100).

    Kontrak telemetri 0x04 menyebut basis 10000 (persen x 100), dan simulator mengirim itu. Gateware
    saat ini mengirim HITUNGAN MENTAH 16-bit per kelas (lihat falcon_top.vhd: lo16(s_gu)...), sehingga
    pembagian /100 pada unpack menghasilkan angka seperti 574,27 'persen'. Cara membedakannya:
    bila jumlah kelas ~100 (+-1) berarti sudah persen; selain itu dianggap hitungan (x100 dari unpack)
    dan dinormalkan terhadap totalnya. Catatan: hitungan 16-bit melingkar di 65535, jadi pada trafik
    lama rasio bisa bergeser sampai gateware mengirim persen langsung (lihat DOKUMENTASI, batasan).
    """
    vals = {k: float(d.get(k, 0) or 0) for k in PROTO_KEYS}
    total = sum(vals.values())
    if total <= 0:
        return dict(vals, raw_total=0, normalized=False)
    if abs(total - 100.0) <= 1.0:
        return dict(vals, raw_total=round(total * 100), normalized=False)
    return dict({k: round(v / total * 100.0, 2) for k, v in vals.items()},
                raw_total=round(total * 100), normalized=True)

# ---- in-memory state ----
HISTORY_MAX = 900          # titik history (1 titik/detik => 15 menit)
LINK_TIMEOUT = 3.0         # detik tanpa datagram => board dianggap Disconnected
state = {
    "last_rx": 0.0, "prev_global": None, "alert_last": {},
    "global": {}, "protocol": {},
    "teid": {},                      # teid -> latest dict
    "events": collections.deque(maxlen=100),
    "history": collections.deque(maxlen=HISTORY_MAX),   # ring-buffer global stats ~15 menit @1Hz (chart + sparkline)
    "evt_counter": {"CreateSession": 0, "ModifySession": 0, "DeleteSession": 0, "Error": 0},
    "started": time.time(), "msg_count": 0, "err_count": 0,
    "rawlog": collections.deque(maxlen=200),   # raw datagram feed (FPGA log)
}
TYPE_NAMES = {0x01: "GLOBAL", 0x02: "TEID", 0x03: "EVENT", 0x04: "PROTOCOL"}
_raw_seq = [0]
VERSION = "1.2.0"
TEID_TTL = int(os.environ.get("FALCON_TEID_TTL", "15"))  # detik; sesi tak update dianggap mati
ws_clients = set()


async def broadcast(msg: dict):
    if not ws_clients:
        return
    data = json.dumps(msg)
    dead = []
    for ws in ws_clients:
        try:
            await ws.send_str(data)
        except Exception:
            dead.append(ws)
    for ws in dead:
        ws_clients.discard(ws)


SEVERITY = {"CreateSession": "INFO", "ModifySession": "INFO", "DeleteSession": "WARN", "Error": "CRITICAL",
            "G-PDU": "INFO", "EchoRequest": "INFO", "EchoResponse": "INFO", "EndMarker": "INFO",
            "ErrorIndication": "WARN"}
# Kode numerik dari gateware = tipe pesan GTP-U (3GPP TS 29.281 §6.1). Sumber: kolom `event` di datagram 0x03.
GTPU_MSG_NAMES = {"1": "EchoRequest", "2": "EchoResponse", "26": "ErrorIndication",
                  "254": "EndMarker", "255": "G-PDU"}
DROP_WARN_PCT = 1.0
DROP_CRIT_PCT = 5.0


# ---- KPI sesi & label IMSI simulasi -------------------------------------------------------------
# Gateware belum mengisi total_imsi / active_teid (Fase 2: butuh session table + parser GTP-C). Backend mengisi:
#  * active_teid  = jumlah TEID yang MASIH hidup di tabel (sampel gateware, 1 datagram TEID per 64 paket). Nyata, tapi sampel.
#  * IMSI         = label FIKTIF per TEID, HANYA saat sumber trafik buatan (demo/simulator). Pada trafik live tidak ada
#                   IMSI karangan: tanpa gateware, nilainya tetap kosong/0. Nilai dari gateware selalu menang.
# Prefiks 001-01 = PLMN uji resmi (ITU), tak mungkin milik operator nyata.
SYNTH_PLMN = "00101"


# ---- Penyamaran IMSI di semua keluaran ------------------------------------------------------------
# IMSI = pengenal pelanggan (data pribadi). Backend menyimpan nilai penuh di memori (perlu untuk hitung unik),
# tetapi KE LUAR (REST, snapshot, WebSocket, rawlog, ekspor) hanya 3 digit depan (MCC) yang keluar; sisanya '*'.
# Berlaku juga untuk IMSI asli dari gateware kelak, bukan hanya label simulasi. Tak bisa dimatikan lewat API.
IMSI_SHOW = max(0, int(os.environ.get("FALCON_IMSI_SHOW", "3")))


def mask_imsi(v) -> str:
    s = str(v or "").strip()
    if not s:
        return ""
    return s[:IMSI_SHOW] + "*" * max(len(s) - IMSI_SHOW, 0)


def public_teid(d: dict) -> dict:
    """Salinan baris TEID aman-keluar: tanpa field internal '_*', IMSI disamarkan."""
    o = {k: v for k, v in d.items() if not k.startswith("_")}
    if "imsi" in o:
        o["imsi"] = mask_imsi(o["imsi"])
    return o


def synthetic_source_active() -> bool:
    return MODE == "sim" or bool(demo.get("enabled"))


def synth_imsi(teid) -> str:
    """IMSI fiktif 15 digit, deterministik per TEID (stabil antar-restart), prefiks PLMN uji."""
    import hashlib
    h = int(hashlib.sha1(str(teid).encode()).hexdigest(), 16)
    return SYNTH_PLMN + str(h % 10**10).zfill(10)


def _has_real_imsi(v) -> bool:
    s = str(v or "").strip()
    return bool(s) and set(s) != {"0"}


def derive_rates(g: dict, ts: int):
    """Hitung bps, delta drop & drop-rate% dari selisih dua datagram 0x01 berurutan.
    Counter reset (nilai turun) => rate 0, bukan negatif."""
    prev = state["prev_global"]
    bps = 0.0; ddrop = 0; drop_rate = 0.0
    if prev is not None:
        dt = max(ts - prev["ts"], 1)
        db = g.get("total_bytes", 0) - prev["total_bytes"]
        dd = g.get("drop_count", 0) - prev["drop_count"]
        if db >= 0:
            bps = db * 8 / dt
        if dd >= 0:
            ddrop = dd
            if g.get("mac_counters") and prev.get("mac_ok") is not None:
                # Counter MAC menghitung FRAME (semua yang masuk MAC), jadi pembaginya frame MAC, bukan paket GTP-U.
                dok = g.get("mac_frames_ok", 0) - prev["mac_ok"]
                if dok >= 0 and (dok + ddrop) > 0:
                    drop_rate = min(100.0, ddrop / (dok + ddrop) * 100)
            else:
                pkts = (g.get("uplink_pps", 0) + g.get("downlink_pps", 0)) * dt
                if pkts > 0:
                    drop_rate = min(100.0, ddrop / pkts * 100)
    state["prev_global"] = {"ts": ts, "total_bytes": g.get("total_bytes", 0), "drop_count": g.get("drop_count", 0),
                            "mac_ok": g.get("mac_frames_ok") if g.get("mac_counters") else None}
    return bps, ddrop, drop_rate


def maybe_alert(name: str, severity: str, ts: int, detail: str, cooldown: int = 10):
    """Alert sintetis server-side (DropSpike dst), dibatasi cooldown agar feed tak banjir."""
    now = time.time()
    if now - state["alert_last"].get(name, 0) < cooldown:
        return None
    state["alert_last"][name] = now
    ev = {"event": name, "severity": severity, "direction": "-", "teid": "-", "packet_len": 0,
          "detail": detail, "ts": ts, "synthetic": True}
    state["events"].appendleft(ev)
    return ev


def update_state(msg: dict):
    t = msg["type"]
    if t == "global":
        ts = msg.get("ts") or int(time.time())
        bps, ddrop, drop_rate = derive_rates(msg["data"], ts)
        msg["data"].update({"bps": round(bps), "drop_delta": ddrop, "drop_rate": round(drop_rate, 3)})
        # KPI sesi: tulis ke msg["data"] juga supaya WebSocket & REST sama (pelajaran donut protokol)
        expire_teids()
        alive = list(state["teid"].values())
        if not msg["data"].get("active_teid"):
            msg["data"]["active_teid"] = len(alive)
            msg["data"]["active_teid_derived"] = True
        if not msg["data"].get("total_imsi") and synthetic_source_active():
            msg["data"]["total_imsi"] = len({d.get("imsi") for d in alive if d.get("imsi_synthetic")})
            msg["data"]["imsi_synthetic"] = True
        g = {**msg["data"], "ts": ts}
        state["global"] = g
        if drop_rate >= DROP_CRIT_PCT:
            msg["alert"] = maybe_alert("DropSpike", "CRITICAL", ts, f"drop {drop_rate:.1f}% (+{ddrop} pkt)")
        elif drop_rate >= DROP_WARN_PCT:
            msg["alert"] = maybe_alert("DropSpike", "WARN", ts, f"drop {drop_rate:.1f}% (+{ddrop} pkt)")
        # rekam histori ringan utk sparkline (UL/DL/throughput/drop)
        state["history"].append({
            "ts": g.get("ts") or int(time.time()),
            "ul": g.get("uplink_pps", 0),
            "dl": g.get("downlink_pps", 0),
            "bytes": g.get("total_bytes", 0),
            "drop": g.get("drop_count", 0),
            "bps": g.get("bps", 0),
            "drop_rate": g.get("drop_rate", 0),
        })
    elif t == "protocol":
        # msg["data"] ikut dibroadcast ke WebSocket: tulis hasil normalisasi di sini supaya REST & WS sama.
        msg["data"] = normalize_protocol(msg["data"])
        state["protocol"] = {**msg["data"], "ts": msg.get("ts", int(time.time()))}
    elif t == "teid":
        d = msg["data"]; d["_seen"] = time.time()
        if _has_real_imsi(d.get("imsi")):
            d["imsi_synthetic"] = False
        elif synthetic_source_active():
            d["imsi"] = synth_imsi(d["teid"])
            d["imsi_synthetic"] = True
        state["teid"][d["teid"]] = d
    elif t == "event":
        ev = {**msg["data"], "ts": msg.get("ts")}
        raw_ev = str(ev.get("event"))
        if raw_ev in GTPU_MSG_NAMES:
            ev["event_code"] = raw_ev
            ev["event"] = msg["data"]["event"] = GTPU_MSG_NAMES[raw_ev]
        ev["severity"] = SEVERITY.get(ev.get("event"), "INFO")
        msg["data"]["severity"] = ev["severity"]
        state["events"].appendleft(ev)
        name = ev.get("event")
        if name in state["evt_counter"]:
            state["evt_counter"][name] += 1


def expire_teids():
    now = time.time()
    for k in [k for k, v in state["teid"].items() if now - v.get("_seen", now) > TEID_TTL]:
        del state["teid"][k]


# ---- UDP protocol ----
class TelemetryProto(asyncio.DatagramProtocol):
    def __init__(self, loop):
        self.loop = loop
    def datagram_received(self, data, addr):
        state["msg_count"] += 1
        state["last_rx"] = time.time()
        _raw_seq[0] += 1
        tid = data[0] if len(data) > 0 else -1
        rawrec = {
            "seq": _raw_seq[0],
            "ts": time.time(),
            "src": f"{addr[0]}:{addr[1]}",
            "type_id": tid,
            "type": TYPE_NAMES.get(tid, f"0x{tid:02X}" if tid >= 0 else "?"),
            "len": len(data),
            "hex": (data[:8].hex() + "…" if tid == C.TYPE_TEID else data[:16].hex()),
            "err": False,
        }
        try:
            msg = C.decode(data)
        except Exception as e:
            state["err_count"] += 1
            rawrec["err"] = True
            state["rawlog"].append(rawrec)
            asyncio.ensure_future(broadcast({"type": "rawlog", "data": rawrec}))
            return  # malformed-safe: skip, jangan crash
        # enrich rawrec with decoded teid if present
        if msg.get("type") == "teid":
            rawrec["teid"] = msg["data"].get("teid")
        elif msg.get("type") == "event":
            rawrec["teid"] = msg["data"].get("teid")
        state["rawlog"].append(rawrec)
        update_state(msg)
        # strip internal field sebelum kirim
        if msg["type"] == "teid":
            msg["data"] = public_teid(msg["data"])
        elif msg["type"] == "event":
            msg["counter"] = dict(state["evt_counter"])   # sertakan counter terkini
        alert = msg.pop("alert", None)
        asyncio.ensure_future(broadcast(msg))
        if alert:
            asyncio.ensure_future(broadcast({"type": "event", "ts": alert["ts"], "data": alert,
                                             "counter": dict(state["evt_counter"])}))
        asyncio.ensure_future(broadcast({"type": "rawlog", "data": rawrec}))


# ---- HTTP / WS handlers ----
async def ws_handler(request):
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    ws_clients.add(ws)
    # kirim snapshot awal
    await ws.send_str(json.dumps({"type": "snapshot", "data": snapshot()}))
    try:
        async for _ in ws:
            pass
    finally:
        ws_clients.discard(ws)
    return ws


def link_status():
    age = time.time() - state["last_rx"] if state["last_rx"] else None
    return {"connected": age is not None and age <= LINK_TIMEOUT,
            "last_rx_age": None if age is None else round(age, 1),
            "last_rx": state["last_rx"] or None}


async def link_watcher():
    """Broadcast status link FPGA ~1Hz; UI menampilkan Disconnected bila board diam (>LINK_TIMEOUT)."""
    while True:
        await asyncio.sleep(1.0)
        await broadcast({"type": "link", "data": link_status()})


def snapshot():
    expire_teids()
    return {
        "link": link_status(),
        "global": state["global"],
        "protocol": state["protocol"],
        "teid": [public_teid(d) for d in state["teid"].values()],
        "events": list(state["events"])[:20],
        "history": list(state["history"]),
        "evt_counter": state["evt_counter"],
        "uptime_s": int(time.time() - state["started"]),
        "msg_count": state["msg_count"], "err_count": state["err_count"],
        "ws_clients": len(ws_clients),
        "version": VERSION,
        "rawlog": list(state["rawlog"])[-50:],
    }


async def api_health(r):   return web.json_response({"status": "ok", "uptime_s": int(time.time()-state["started"]), "msg_count": state["msg_count"], "err_count": state["err_count"]})
async def api_global(r):   return web.json_response(state["global"])
async def api_teid(r):     expire_teids(); return web.json_response([public_teid(d) for d in state["teid"].values()])
async def api_events(r):
    lim = int(r.query.get("limit", 20))
    return web.json_response(list(state["events"])[:lim])
async def api_protocol(r): return web.json_response(state["protocol"])
async def api_snapshot(r): return web.json_response(snapshot())
async def api_history(r):
    """?window=<detik> => hanya titik dalam N detik terakhir (default semua)."""
    h = list(state["history"])
    try:
        w = int(r.query.get("window", 0))
    except ValueError:
        w = 0
    if w > 0:
        h = h[-w:]
    return web.json_response(h)
async def api_link(r):     return web.json_response(link_status())
async def api_evtcounter(r): return web.json_response(state["evt_counter"])
def _gen(action):
    """run falcon-gen <action>, return (ok, output)."""
    try:
        r = subprocess.run(["bash", GEN_CTL, action], capture_output=True, text=True, timeout=15)
        out = (r.stdout + r.stderr).strip()
        return r.returncode == 0, out
    except Exception as e:
        return False, str(e)

def _deny_public():
    return web.json_response({"ok": False, "error": "generator control disabled on public deployment"}, status=403)

demo = {"enabled": False, "active": False, "pps": 0, "on_s": 0, "off_s": 0, "next_flip": 0, "sent": 0,
        "source": "synthetic"}
sim5g = {"gen": None, "cfg": None}     # generator trafik5g aktif + konfigurasinya


def _load_payloads():
    """Payload GTP-U sintetis (sesuai silikon: tanpa header Eth/IP/UDP). 20 TEID tetap -> tabel sesi stabil.
    Format: flags 0x30, type 0xFF (G-PDU), length, TEID, lalu isi acak berukuran bervariasi."""
    import random, struct
    rnd = random.Random(2152)
    out = []
    for i in range(20):
        teid = 0x1000 + i * 0x111
        for plen in (4, 12, 64, 180):
            body = bytes(rnd.getrandbits(8) for _ in range(plen))
            out.append(struct.pack(">BBHI", 0x30, 0xFF, plen, teid) + body)
    return out


DEMO_LIMITS = {"pps": (1, 5000), "on_s": (1, 3600), "off_s": (0, 3600)}
_demo_task = [None]


async def demo_traffic_task(on_s: int, off_s: int, pps: int, source: str = "synthetic"):
    """Kirim GTP-U sintetis ke board: aktif on_s detik @ pps, jeda off_s detik (0 = terus-menerus)."""
    import socket
    host, port = DEMO_TARGET.rsplit(":", 1)
    if source == "sim-5g":
        await _sim5g_loop(on_s, off_s, host, int(port))
        return
    if source == "stack-lte":
        try:
            payloads = gtpu_pcap.gtpu_payloads(stack.PCAP)
        except (OSError, ValueError) as e:
            print(f"[FALCON-BE] replay stack: pcap tak terbaca ({e})")
            return
        if not payloads:
            print("[FALCON-BE] replay stack: tidak ada GTP-U di pcap, dimatikan")
            return
    else:
        payloads = _load_payloads()
        if not payloads:
            print("[FALCON-BE] demo traffic: vektor payload tidak ditemukan, dimatikan")
            return
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    demo.update({"enabled": True, "pps": pps, "on_s": on_s, "off_s": off_s, "source": source,
                 "pool": len(payloads)})
    loop = asyncio.get_event_loop()
    i = 0
    print(f"[FALCON-BE] demo traffic AKTIF: {on_s}s on @ ~{pps} pps, {off_s}s off -> {DEMO_TARGET}")
    try:
        while True:
            demo["active"] = True
            end = loop.time() + on_s
            demo["next_flip"] = int(time.time() + on_s)
            gap = 1.0 / pps
            nxt = loop.time()
            while loop.time() < end:
                try:
                    sock.sendto(payloads[i % len(payloads)], (host, int(port)))
                    demo["sent"] += 1
                except OSError:
                    pass
                i += 1
                nxt += gap
                delay = nxt - loop.time()
                await asyncio.sleep(delay if delay > 0 else 0)
            if off_s <= 0:
                continue
            demo["active"] = False
            demo["next_flip"] = int(time.time() + off_s)
            await asyncio.sleep(off_s)
    finally:
        demo.update({"enabled": False, "active": False})
        sock.close()


async def _sim5g_loop(on_s: int, off_s: int, host: str, port: int):
    """Sumber 'sim-5g': generator traffic5g (profil aplikasi nyata) dialirkan ke board, jadwal aktif/jeda sama."""
    import socket
    g = sim5g["gen"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    demo.update({"enabled": True, "pps": int(g.pps), "on_s": on_s, "off_s": off_s, "source": "sim-5g",
                 "pool": len(g.sessions)})
    loop = asyncio.get_event_loop()
    tick = 0.02
    print(f"[FALCON-BE] sim-5g AKTIF: {len(g.sessions)} sesi, ~{g.pps:.0f} pps, {on_s}s on / {off_s}s off -> {DEMO_TARGET}")
    try:
        while True:
            demo["active"] = True
            demo["next_flip"] = int(time.time() + on_s)
            end = loop.time() + on_s
            nxt = loop.time()
            while loop.time() < end:
                for pl, _teid, _app in g.next_batch(tick):
                    try:
                        sock.sendto(pl, (host, port))
                        demo["sent"] += 1
                    except OSError:
                        pass
                nxt += tick
                d = nxt - loop.time()
                await asyncio.sleep(d if d > 0 else 0)
            if off_s <= 0:
                continue
            demo["active"] = False
            demo["next_flip"] = int(time.time() + off_s)
            await asyncio.sleep(off_s)
    finally:
        demo.update({"enabled": False, "active": False})
        sock.close()


def demo_start(on_s: int, off_s: int, pps: int, source: str = "synthetic"):
    demo_stop(clear_sim=(source != "sim-5g"))
    _demo_task[0] = asyncio.ensure_future(demo_traffic_task(on_s, off_s, pps, source))


def demo_stop(clear_sim: bool = True):
    t = _demo_task[0]
    if t and not t.done():
        t.cancel()
    _demo_task[0] = None
    demo.update({"enabled": False, "active": False, "source": "synthetic", "pool": 0})
    if clear_sim:
        sim5g.update({"gen": None, "cfg": None})


async def api_demo(r):
    return web.json_response(demo)


async def api_measure(r):
    """Penjelasan jujur tiap angka: sumber, satuan, dan keterbatasan gateware saat ini."""
    return web.json_response({"version": VERSION, "mode": MODE, "items": [
        {"k": "uplink_pps", "name": "Uplink / Downlink", "unit": "paket/dtk", "status": "valid",
         "note": "Paket GTP-U yang diterima gateware per interval emit 1 detik (counter di-reset tiap emit 0x01)."},
        {"k": "total_bytes", "name": "Throughput GTP-U (payload)", "unit": "byte / bps", "status": "valid",
         "note": "Jumlah byte payload GTP-U (tanpa header Ethernet/IP/UDP, yang dibuang MAC). Kumulatif sejak bitstream di-load. bps = selisih per detik."},
        {"k": "sessions", "name": "Sesi Aktif (TEID)", "unit": "TEID", "status": "sebagian",
         "note": "Jumlah TEID yang masih hidup di tabel. Gateware mengirim SAMPEL (satu datagram TEID per 64 paket, TEID paket terakhir), jadi sesi berpaket jarang bisa terlambat muncul; sesi dianggap mati setelah %d detik tanpa update. Kolom active_teid dari gateware masih 0, jadi angka ini dihitung backend." % TEID_TTL},
        {"k": "drop", "name": "Drop", "unit": "frame", "status": "sebagian",
         "note": "Gateware menghitung frame yang dibuang di JALUR MASUK MAC: FIFO RX penuh (overflow) dan frame tak valid. Ini cakupan drop yang nyata, tetapi BUKAN seluruh kemungkinan paket hilang: paket yang hilang di kabel/switch sebelum papan, atau dibuang NIC host, tidak terlihat. Pada bitstream lama (tanpa counter MAC) nilainya selalu 0 dan itu bukan bukti tak ada drop. Dashboard menandai 'counter MAC aktif' hanya bila gateware benar-benar mengirimnya."},
        {"k": "imsi", "name": "IMSI Aktif", "unit": "pengguna", "status": "simulasi",
         "note": "Gateware belum mengekstrak IMSI (butuh parser GTP-C, Fase 2); di paket data GTP-U memang tidak ada IMSI. Saat sumber trafik BUATAN (demo/simulator), backend memberi label FIKTIF per TEID (PLMN uji 001-01) agar tampilan lengkap; ditandai SIM. Pada trafik live nilai tetap 0, tidak dikarang."},
        {"k": "protocol", "name": "Distribusi Protokol", "unit": "%", "status": "sebagian",
         "note": "Gateware mengirim hitungan mentah 16-bit per kelas; backend menormalkan ke persen. Hanya GTP-U yang terisi; GTP-C, PFCP, BSSGP butuh classifier port lain yang belum menerima traffic. Hitungan 16-bit melingkar di 65535, jadi rasio bisa bergeser pada trafik lama."},
        {"k": "events", "name": "Event", "unit": "kejadian", "status": "sebagian",
         "note": "Kode event = tipe pesan GTP-U (255=G-PDU). Event sinyal (Create/Delete Session) butuh GTP-C yang belum diparse."},
    ]})


async def api_gen_status(r):
    if PUBLIC and not _session(r):
        return web.json_response({"running": False, "detail": "disabled", "disabled": True})
    ok, out = _gen("status")
    running = out.startswith("RUNNING")
    return web.json_response({"running": running, "detail": out})

async def api_gen_start(r):
    ok, out = _gen("start")
    return web.json_response({"ok": ok, "detail": out, "running": ("STARTED" in out or "ALREADY_RUNNING" in out)})

async def api_gen_stop(r):
    ok, out = _gen("stop")
    return web.json_response({"ok": ok, "detail": out, "running": False})

async def api_version(r):  return web.json_response({"name": "FALCON", "version": VERSION, "udp_port": UDP_PORT, "http_port": HTTP_PORT,
                              "mode": MODE, "public": PUBLIC, "demo": bool(DEMO_SPEC)})
async def api_rawlog(r):
    lim = int(r.query.get("limit", 100))
    return web.json_response(list(state["rawlog"])[-lim:])


# ---------------------------------------------------------------- auth + halaman
PAGES = os.path.join(os.path.dirname(__file__), "..", "dashboard")
# Halaman yang boleh dilihat tanpa login. Selainnya wajib operator (lihat gate).
OPEN_PATHS = {"/", "/login", "/api/login", "/api/logout", "/api/me", "/api/version", "/api/health",
              "/api/link", "/api/demo", "/api/measure", "/api/snapshot", "/api/history", "/api/events",
              "/api/events/counter", "/api/stats/global", "/api/stats/teid", "/api/stats/protocol",
              "/api/rawlog", "/api/generator/status", "/ws"}


def _session(r):
    return auth.get_session(r.cookies.get(auth.COOKIE))


def _client_ip(r):
    return r.headers.get("CF-Connecting-IP") or r.headers.get("X-Forwarded-For", "").split(",")[0].strip() or r.remote or "?"


@web.middleware
async def gate(request, handler):
    path = request.path
    if path.startswith("/static/") or path in OPEN_PATHS:
        return await handler(request)
    sess = _session(request)
    if not sess:
        if path.startswith("/api/"):
            return web.json_response({"ok": False, "error": "login diperlukan"}, status=401)
        raise web.HTTPFound("/login?next=" + path)
    if request.method != "GET" and sess["role"] != "operator":
        return web.json_response({"ok": False, "error": "hanya operator"}, status=403)
    request["sess"] = sess
    return await handler(request)


async def api_login(r):
    ip = _client_ip(r)
    wait = auth.locked(ip)
    if wait:
        return web.json_response({"ok": False, "error": f"terlalu banyak percobaan, coba lagi {wait} dtk"}, status=429)
    try:
        d = await r.json()
    except Exception:
        return web.json_response({"ok": False, "error": "format salah"}, status=400)
    user, pw = str(d.get("username", ""))[:64], str(d.get("password", ""))[:256]
    role = auth.verify(user, pw)
    if not role:
        auth.note_fail(ip)
        await asyncio.sleep(0.6)        # perlambat tebakan
        return web.json_response({"ok": False, "error": "nama pengguna atau sandi salah"}, status=401)
    auth.note_ok(ip)
    tok = auth.new_session(user, role)
    resp = web.json_response({"ok": True, "user": user, "role": role})
    resp.set_cookie(auth.COOKIE, tok, max_age=auth.SESSION_TTL, httponly=True, samesite="Strict",
                    secure=r.headers.get("X-Forwarded-Proto") == "https" or r.scheme == "https", path="/")
    return resp


async def api_logout(r):
    auth.end_session(r.cookies.get(auth.COOKIE))
    resp = web.json_response({"ok": True})
    resp.del_cookie(auth.COOKIE, path="/")
    return resp


async def api_me(r):
    s = _session(r)
    return web.json_response({"logged_in": bool(s), "user": s and s["user"], "role": s and s["role"]})


def _page(name):
    async def h(r):
        f = os.path.join(PAGES, name)
        if os.path.exists(f):
            return web.FileResponse(f, headers={"Cache-Control": "no-store"})
        return web.Response(text=f"{name} belum ada", content_type="text/plain", status=404)
    return h


# --- Setup FPGA: profil perangkat. Hanya Genesys yang didukung; sisanya ditandai jujur.
FPGA_PROFILES = [
    {"id": "genesys-v5", "name": "Digilent Genesys", "chip": "Xilinx Virtex-5 XC5VLX50T", "status": "supported",
     "toolchain": "ISE 14.7", "phy": "GMII 1 Gbps (88E1111)", "ip": "192.168.0.20",
     "note": "Target saat ini. Gateware terverifikasi di silikon."},
    {"id": "artix7", "name": "Artix-7 (mis. Nexys A7 / Arty A7)", "chip": "Xilinx Artix-7", "status": "planned",
     "toolchain": "Vivado", "phy": "RGMII", "ip": None,
     "note": "Belum ada. Perlu porting lapisan Ethernet (RGMII) dan constraint pin. Inti DPI (VHDL) dapat dipakai ulang."},
    {"id": "zynq", "name": "Zynq-7000 / UltraScale+", "chip": "Xilinx Zynq", "status": "planned",
     "toolchain": "Vivado", "phy": "GEM / RGMII", "ip": None,
     "note": "Belum ada. Inti DPI dipakai di PL; telemetri bisa lewat PS."},
    {"id": "ecp5", "name": "Lattice ECP5", "chip": "Lattice ECP5", "status": "planned",
     "toolchain": "Yosys + nextpnr (open source)", "phy": "RGMII", "ip": None,
     "note": "Belum ada. Jalur toolchain open source; VHDL perlu ghdl-yosys."},
]


async def api_setup_fpga(r):
    lk = link_status()
    fs = await fpga.status()
    return web.json_response({
        "active": "genesys-v5", "profiles": FPGA_PROFILES,
        "link": lk, "udp_port": UDP_PORT,
        "loader": dict(fs, job=fpga.job),
        "contract": {"types": [1, 2, 3, 4], "header_bytes": 4, "endian": "big"},
        "shared_core": ["gtpu_parser", "protocol_classifier", "stats_counter", "telemetry_packer"],
        "port_specific": ["Ethernet MAC/PHY", "pin constraint (UCF/XDC)", "clock/PLL"],
    })


async def api_setup_traffic(r):
    st = await stack.status()
    sstat = {"running": "running", "partial": "partial", "stopped": "stopped", "not-installed": "not-installed",
             "error": "error"}.get(st.get("state"), "stopped")
    cap = st.get("capture") or (stack_capture_info() if stack.installed() else None)
    return web.json_response({
        "sources": [
            {"id": "synthetic", "name": "Sintetis (backend)", "status": "ready",
             "desc": "Backend mengirim paket GTP-U uji ke board. Tanpa jaringan nyata."},
            {"id": "stack-lte", "name": "Stack LTE (Open5GS + srsRAN)", "status": sstat,
             "desc": "UE simulasi attach ke core 4G; GTP-U S1-U asli ditangkap lalu diputar ulang ke board."},
            {"id": "sim-5g", "name": "Simulator 5G (profil aplikasi)", "status": "ready",
             "desc": "GTP-U berekstensi QFI dengan profil aplikasi nyata (video, game, konferensi). Statistik nyata, paket buatan."},
            {"id": "live", "name": "Live (antarmuka fisik)", "status": "manual",
             "desc": "Kabel mirror/TAP dari jaringan nyata ke port Ethernet board. Matikan sumber lain."},
        ],
        "demo": demo, "target": DEMO_TARGET, "limits": DEMO_LIMITS,
        "sim5g": dict(sim5g_info(), apps=sorted(traffic5g.load_profiles()), presets=sorted(traffic5g.MIX_PRESETS)),
        "stack": dict(st, job=stack.job, capture=cap, installed=stack.installed()),
    })


def sim5g_info():
    g = sim5g["gen"]
    if not g:
        return {"active": False}
    return dict(g.snapshot(), active=True, cfg=sim5g["cfg"], teids=g.teid_apps())


def stack_capture_info():
    try:
        st = os.stat(stack.PCAP)
        return {"bytes": st.st_size, "age_s": int(time.time() - st.st_mtime)}
    except OSError:
        return None


async def api_traffic_start(r):
    d = await r.json()
    try:
        pps, on_s, off_s = int(d["pps"]), int(d["on_s"]), int(d["off_s"])
    except (KeyError, ValueError, TypeError):
        return web.json_response({"ok": False, "error": "pps/on_s/off_s wajib angka"}, status=400)
    for k, v in (("pps", pps), ("on_s", on_s), ("off_s", off_s)):
        lo, hi = DEMO_LIMITS[k]
        if not lo <= v <= hi:
            return web.json_response({"ok": False, "error": f"{k} harus {lo}..{hi}"}, status=400)
    source = d.get("source", "synthetic")
    if source not in ("synthetic", "stack-lte", "sim-5g"):
        return web.json_response({"ok": False, "error": "sumber tidak dikenal"}, status=400)
    if source == "sim-5g":
        cfg = d.get("sim5g") or {}
        try:
            mix = traffic5g.MIX_PRESETS[cfg["preset"]] if cfg.get("preset") else (cfg.get("mix") or None)
            if cfg.get("preset") and cfg["preset"] not in traffic5g.MIX_PRESETS:
                raise ValueError("preset tidak dikenal")
            ues = int(cfg.get("ues", 64))
            burst = float(cfg.get("burst", 1.0))
            g = traffic5g.Generator(pps=pps, mix=mix, ues=ues, burst=burst, seed=int(cfg.get("seed", 5152)))
        except (ValueError, TypeError, KeyError) as e:
            return web.json_response({"ok": False, "error": "konfigurasi sim-5g: %s" % e}, status=400)
        sim5g.update({"gen": g, "cfg": {"preset": cfg.get("preset"), "ues": ues, "burst": burst,
                                         "seed": int(cfg.get("seed", 5152))}})
        demo_start(on_s, off_s, pps, source)
        return web.json_response({"ok": True, "demo": demo, "sim5g": sim5g_info()})
    if source == "stack-lte" and not os.path.exists(stack.PCAP or "/nonexistent"):
        return web.json_response({"ok": False, "error": "belum ada tangkapan; jalankan 'Siapkan stack' dulu"}, status=409)
    demo_start(on_s, off_s, pps, source)
    return web.json_response({"ok": True, "demo": demo})


async def api_sim5g_inject(r):
    g = sim5g["gen"]
    if not g:
        return web.json_response({"ok": False, "error": "simulator 5G tidak berjalan"}, status=409)
    try:
        d = await r.json()
        teid = d.get("teid")
        an = g.inject(float(d["factor"]), float(d["seconds"]), app=d.get("app") or None,
                      teid=int(teid) if teid not in (None, "") else None)
    except (KeyError, ValueError, TypeError) as e:
        return web.json_response({"ok": False, "error": str(e) or "masukan tidak valid"}, status=400)
    return web.json_response({"ok": True, "anomaly": an})


async def api_sim5g_status(r):
    return web.json_response(dict(sim5g_info(), apps=sorted(traffic5g.load_profiles())))


async def api_traffic_stop(r):
    demo_stop()
    return web.json_response({"ok": True, "demo": demo})


async def api_stack_prepare(r):
    if not stack.installed():
        return web.json_response({"ok": False, "error": "stack tidak terpasang di host ini"}, status=409)
    if stack.busy():
        return web.json_response({"ok": False, "error": "operasi stack sedang berjalan"}, status=409)
    try:
        d = await r.json()
    except ValueError:
        d = {}
    keep = bool(d.get("keep_running", False))
    secs = max(5, min(60, int(d.get("secs", 12))))
    pps = max(10, min(300, int(d.get("pps", 120))))
    asyncio.ensure_future(stack.prepare(keep, secs, pps))
    return web.json_response({"ok": True, "job": stack.job})


async def api_fpga_load(r):
    if not fpga.installed():
        return web.json_response({"ok": False, "error": "pemuat gateware tidak terpasang di host ini"}, status=409)
    if fpga.busy():
        return web.json_response({"ok": False, "error": "pemuatan sedang berjalan"}, status=409)
    if link_status().get("connected"):
        # papan sudah hidup dan mengirim telemetri: jangan reprogram tanpa perlu (menghindari TX bisu)
        return web.json_response({"ok": False, "error": "papan sudah terhubung; pemuatan ulang tidak diperlukan"}, status=409)
    asyncio.ensure_future(fpga.load())
    return web.json_response({"ok": True, "job": fpga.job})


async def api_stack_stop(r):
    if not stack.installed():
        return web.json_response({"ok": False, "error": "stack tidak terpasang di host ini"}, status=409)
    if stack.busy():
        return web.json_response({"ok": False, "error": "operasi stack sedang berjalan"}, status=409)
    asyncio.ensure_future(stack.shutdown())
    return web.json_response({"ok": True, "job": stack.job})


async def index(r):
    return await _page("index.html")(r)


def start_demo_from_spec(spec: str):
    """Mulai demo dari FALCON_DEMO_TRAFFIC. Melempar ValueError bila format/isi salah (tak menyalakan apa pun)."""
    parts = spec.split(":")
    kind = parts[0].lower()
    if kind not in ("burst", "sim5g") or len(parts) < 4:
        raise ValueError("format")
    on_s, off_s, pps = int(parts[1]), int(parts[2]), int(parts[3])
    for k, v in (("pps", pps), ("on_s", on_s), ("off_s", off_s)):
        lo, hi = DEMO_LIMITS[k]
        if not lo <= v <= hi:
            raise ValueError(f"{k} harus {lo}..{hi}")
    if kind == "burst":
        demo_start(on_s, off_s, pps)
        return
    preset = parts[4] if len(parts) > 4 and parts[4] else "campuran"
    ues = int(parts[5]) if len(parts) > 5 and parts[5] else 64
    if preset not in traffic5g.MIX_PRESETS:
        raise ValueError(f"preset {preset!r} tidak dikenal")
    g = traffic5g.Generator(pps=pps, mix=traffic5g.MIX_PRESETS[preset], ues=ues)
    sim5g.update({"gen": g, "cfg": {"preset": preset, "ues": ues, "burst": 1.0, "seed": 5152}})
    demo_start(on_s, off_s, pps, "sim-5g")


async def on_startup(app):
    loop = asyncio.get_event_loop()
    await loop.create_datagram_endpoint(lambda: TelemetryProto(loop),
                                        local_addr=("0.0.0.0", UDP_PORT))
    asyncio.ensure_future(link_watcher())
    if DEMO_SPEC and DEMO_SPEC.lower() != "off":
        try:
            start_demo_from_spec(DEMO_SPEC)
        except ValueError as e:
            print(f"[FALCON-BE] FALCON_DEMO_TRAFFIC tidak valid: {DEMO_SPEC!r} ({e}); format burst:ON:OFF:PPS atau sim5g:ON:OFF:PPS[:preset[:ues]]")
    if not auth.has_users():
        print("[FALCON-BE] PERINGATAN: belum ada akun operator -> halaman Setup terkunci. Buat: python3 auth.py add <user> operator")
    print(f"[FALCON-BE] UDP listener :{UDP_PORT}  ·  HTTP/WS :{HTTP_PORT}  ·  mode={MODE} public={PUBLIC}")


def make_app():
    app = web.Application(middlewares=[gate])
    app.on_startup.append(on_startup)
    app.add_routes([
        web.get("/", index),
        web.get("/login", _page("login.html")),
        web.get("/setup/fpga", _page("setup-fpga.html")),
        web.get("/setup/traffic", _page("setup-traffic.html")),
        web.post("/api/login", api_login),
        web.post("/api/logout", api_logout),
        web.get("/api/me", api_me),
        web.get("/api/setup/fpga", api_setup_fpga),
        web.get("/api/setup/traffic", api_setup_traffic),
        web.post("/api/traffic/start", api_traffic_start),
        web.post("/api/traffic/stop", api_traffic_stop),
        web.post("/api/sim5g/inject", api_sim5g_inject),
        web.get("/api/sim5g", api_sim5g_status),
        web.post("/api/stack/prepare", api_stack_prepare),
        web.post("/api/stack/stop", api_stack_stop),
        web.post("/api/fpga/load", api_fpga_load),
        web.get("/ws", ws_handler),
        web.get("/api/health", api_health),
        web.get("/api/stats/global", api_global),
        web.get("/api/stats/teid", api_teid),
        web.get("/api/events", api_events),
        web.get("/api/stats/protocol", api_protocol),
        web.get("/api/snapshot", api_snapshot),
        web.get("/api/history", api_history),
        web.get("/api/link", api_link),
        web.get("/api/demo", api_demo),
        web.get("/api/measure", api_measure),
        web.get("/api/events/counter", api_evtcounter),
        web.get("/api/version", api_version),
        web.get("/api/generator/status", api_gen_status),
        web.post("/api/generator/start", api_gen_start),
        web.post("/api/generator/stop", api_gen_stop),
        web.get("/api/rawlog", api_rawlog),
    ])
    if os.path.isdir(DASH_DIR):
        app.router.add_static("/static/", DASH_DIR)
    return app


if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    runner = web.AppRunner(make_app(), access_log=None)
    loop.run_until_complete(runner.setup())
    site = web.TCPSite(runner, "0.0.0.0", HTTP_PORT)
    loop.run_until_complete(site.start())
    print(f"[FALCON-BE] siap di http://0.0.0.0:{HTTP_PORT}", flush=True)
    try:
        loop.run_forever()
    except KeyboardInterrupt:
        pass
    finally:
        loop.run_until_complete(runner.cleanup())

