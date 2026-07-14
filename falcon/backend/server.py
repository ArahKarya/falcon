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

UDP_PORT = 50000
HTTP_PORT = 8080
DASH_DIR = os.path.join(os.path.dirname(__file__), "..", "dashboard")
GEN_CTL = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "falcon-gen")

# ---- in-memory state ----
state = {
    "global": {}, "protocol": {},
    "teid": {},                      # teid -> latest dict
    "events": collections.deque(maxlen=100),
    "history": collections.deque(maxlen=120),   # ring-buffer global stats utk sparkline (~120 titik)
    "evt_counter": {"CreateSession": 0, "ModifySession": 0, "DeleteSession": 0, "Error": 0},
    "started": time.time(), "msg_count": 0, "err_count": 0,
    "rawlog": collections.deque(maxlen=200),   # raw datagram feed (FPGA log)
}
TYPE_NAMES = {0x01: "GLOBAL", 0x02: "TEID", 0x03: "EVENT", 0x04: "PROTOCOL"}
_raw_seq = [0]
VERSION = "1.1.0"
TEID_TTL = 15  # detik; sesi tak update dianggap mati
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


def update_state(msg: dict):
    t = msg["type"]
    if t == "global":
        g = {**msg["data"], "ts": msg.get("ts")}
        state["global"] = g
        # rekam histori ringan utk sparkline (UL/DL/throughput/drop)
        state["history"].append({
            "ts": g.get("ts") or int(time.time()),
            "ul": g.get("uplink_pps", 0),
            "dl": g.get("downlink_pps", 0),
            "bytes": g.get("total_bytes", 0),
            "drop": g.get("drop_count", 0),
        })
    elif t == "protocol":
        state["protocol"] = {**msg["data"], "ts": msg.get("ts", int(time.time()))}
    elif t == "teid":
        d = msg["data"]; d["_seen"] = time.time()
        state["teid"][d["teid"]] = d
    elif t == "event":
        ev = {**msg["data"], "ts": msg.get("ts")}
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
        _raw_seq[0] += 1
        tid = data[0] if len(data) > 0 else -1
        rawrec = {
            "seq": _raw_seq[0],
            "ts": time.time(),
            "src": f"{addr[0]}:{addr[1]}",
            "type_id": tid,
            "type": TYPE_NAMES.get(tid, f"0x{tid:02X}" if tid >= 0 else "?"),
            "len": len(data),
            "hex": data[:16].hex(),
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
            msg["data"] = {k: v for k, v in msg["data"].items() if not k.startswith("_")}
        elif msg["type"] == "event":
            msg["counter"] = dict(state["evt_counter"])   # sertakan counter terkini
        asyncio.ensure_future(broadcast(msg))
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


def snapshot():
    expire_teids()
    return {
        "global": state["global"],
        "protocol": state["protocol"],
        "teid": [{k: v for k, v in d.items() if not k.startswith("_")}
                 for d in state["teid"].values()],
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
async def api_teid(r):     expire_teids(); return web.json_response([{k:v for k,v in d.items() if not k.startswith("_")} for d in state["teid"].values()])
async def api_events(r):
    lim = int(r.query.get("limit", 20))
    return web.json_response(list(state["events"])[:lim])
async def api_protocol(r): return web.json_response(state["protocol"])
async def api_snapshot(r): return web.json_response(snapshot())
async def api_history(r):  return web.json_response(list(state["history"]))
async def api_evtcounter(r): return web.json_response(state["evt_counter"])
def _gen(action):
    """run falcon-gen <action>, return (ok, output)."""
    try:
        r = subprocess.run(["bash", GEN_CTL, action], capture_output=True, text=True, timeout=15)
        out = (r.stdout + r.stderr).strip()
        return r.returncode == 0, out
    except Exception as e:
        return False, str(e)

async def api_gen_status(r):
    ok, out = _gen("status")
    running = out.startswith("RUNNING")
    return web.json_response({"running": running, "detail": out})

async def api_gen_start(r):
    ok, out = _gen("start")
    return web.json_response({"ok": ok, "detail": out, "running": ("STARTED" in out or "ALREADY_RUNNING" in out)})

async def api_gen_stop(r):
    ok, out = _gen("stop")
    return web.json_response({"ok": ok, "detail": out, "running": False})

async def api_version(r):  return web.json_response({"name": "FALCON", "version": VERSION, "udp_port": UDP_PORT, "http_port": HTTP_PORT})
async def api_rawlog(r):
    lim = int(r.query.get("limit", 100))
    return web.json_response(list(state["rawlog"])[-lim:])


async def index(r):
    f = os.path.join(DASH_DIR, "index.html")
    if os.path.exists(f):
        return web.FileResponse(f)
    return web.Response(text="dashboard belum ada", content_type="text/plain")


async def on_startup(app):
    loop = asyncio.get_event_loop()
    await loop.create_datagram_endpoint(lambda: TelemetryProto(loop),
                                        local_addr=("0.0.0.0", UDP_PORT))
    print(f"[FALCON-BE] UDP listener :{UDP_PORT}  ·  HTTP/WS :{HTTP_PORT}")


def make_app():
    app = web.Application()
    app.on_startup.append(on_startup)
    app.add_routes([
        web.get("/", index),
        web.get("/ws", ws_handler),
        web.get("/api/health", api_health),
        web.get("/api/stats/global", api_global),
        web.get("/api/stats/teid", api_teid),
        web.get("/api/events", api_events),
        web.get("/api/stats/protocol", api_protocol),
        web.get("/api/snapshot", api_snapshot),
        web.get("/api/history", api_history),
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

