"""FALCON telemetry contract — single source of truth untuk byte-struct.
Mirror PRD §4-5. Dipakai bersama oleh Simulator (pack) & Backend (unpack).

Common header (4B): msg_type(u8) version(u8) length(u16 BE)
Semua multi-byte = big-endian (network order), konfirmasi NOZ pending.

CATATAN: struktur ini = proposal AKS (data NOZ parsial). Field length di header
membuat perubahan internal berdampak minimal pada parser.
"""
import struct
from dataclasses import dataclass, asdict

# ---- message type ids ----
TYPE_GLOBAL   = 0x01
TYPE_TEID     = 0x02
TYPE_EVENT    = 0x03
TYPE_PROTOCOL = 0x04

PROTO_VERSION = 0x01
HEADER_FMT = ">BBH"          # msg_type, version, length
HEADER_LEN = struct.calcsize(HEADER_FMT)   # 4

EVENT_NAMES = {1: "CreateSession", 2: "DeleteSession", 3: "ModifySession", 4: "Error"}
STATE_NAMES = {0: "IDLE", 1: "ACTIVE", 2: "SUSPENDED"}
DIR_NAMES   = {0: "UL", 1: "DL"}


def make_header(msg_type: int, payload: bytes) -> bytes:
    return struct.pack(HEADER_FMT, msg_type, PROTO_VERSION, len(payload)) + payload


def parse_header(buf: bytes):
    """return (msg_type, version, length, payload_bytes) or raise ValueError."""
    if len(buf) < HEADER_LEN:
        raise ValueError(f"datagram too short: {len(buf)}B")
    msg_type, version, length = struct.unpack(HEADER_FMT, buf[:HEADER_LEN])
    payload = buf[HEADER_LEN:HEADER_LEN + length]
    if len(payload) < length:
        raise ValueError(f"truncated payload: want {length} got {len(payload)}")
    return msg_type, version, length, payload


# ---------- 0x01 GLOBAL (payload 64B) ----------
GLOBAL_FMT = ">IIIIIQI"   # ts, total_imsi, ul_pps, dl_pps, active_teid, total_bytes(u64), drop  = 4+4+4+4+4+8+4=32
GLOBAL_PAD = 64 - struct.calcsize(GLOBAL_FMT)

def pack_global(ts, total_imsi, ul_pps, dl_pps, active_teid, total_bytes, drop):
    body = struct.pack(GLOBAL_FMT, ts, total_imsi, ul_pps, dl_pps, active_teid, total_bytes, drop)
    return make_header(TYPE_GLOBAL, body + b"\x00" * GLOBAL_PAD)

def unpack_global(payload):
    ts, ti, ul, dl, at, tb, dr = struct.unpack(GLOBAL_FMT, payload[:struct.calcsize(GLOBAL_FMT)])
    return {"type": "global", "ts": ts, "data": {
        "total_imsi": ti, "uplink_pps": ul, "downlink_pps": dl,
        "active_teid": at, "total_bytes": tb, "drop_count": dr}}


# ---------- 0x02 PER-TEID (payload 48B) ----------
TEID_FMT = ">I16sBBII"   # teid, imsi[16], qfi, state, ul_pkts, dl_pkts = 4+16+1+1+4+4=30
TEID_PAD = 48 - struct.calcsize(TEID_FMT)

def pack_teid(teid, imsi, qfi, state, ul_pkts, dl_pkts):
    imsi_b = imsi.encode("ascii")[:16].ljust(16, b"\x00")
    body = struct.pack(TEID_FMT, teid, imsi_b, qfi, state, ul_pkts, dl_pkts)
    return make_header(TYPE_TEID, body + b"\x00" * TEID_PAD)

def unpack_teid(payload):
    teid, imsi_b, qfi, state, ul, dl = struct.unpack(TEID_FMT, payload[:struct.calcsize(TEID_FMT)])
    imsi = imsi_b.split(b"\x00")[0].decode("ascii", "ignore")
    return {"type": "teid", "data": {
        "teid": f"0x{teid:08X}", "imsi": imsi, "qfi": qfi,
        "state": STATE_NAMES.get(state, str(state)),
        "ul_pkts": ul, "dl_pkts": dl}}


# ---------- 0x03 EVENT (payload 32B) ----------
EVENT_FMT = ">BBIHI"   # event_type, direction, teid, packet_len, ts = 1+1+4+2+4=12
EVENT_PAD = 32 - struct.calcsize(EVENT_FMT)

def pack_event(event_type, direction, teid, packet_len, ts):
    body = struct.pack(EVENT_FMT, event_type, direction, teid, packet_len, ts)
    return make_header(TYPE_EVENT, body + b"\x00" * EVENT_PAD)

def unpack_event(payload):
    et, d, teid, plen, ts = struct.unpack(EVENT_FMT, payload[:struct.calcsize(EVENT_FMT)])
    return {"type": "event", "ts": ts, "data": {
        "event": EVENT_NAMES.get(et, str(et)),
        "direction": DIR_NAMES.get(d, str(d)),
        "teid": f"0x{teid:08X}", "packet_len": plen}}


# ---------- 0x04 PROTOCOL DIST (payload 32B) ----------
# basis 10000 (2 desimal): pct = raw/100.0
PROTO_FMT = ">HHHHH"   # gtp_u, gtp_c, pfcp, bssgp, other = 10B
PROTO_PAD = 32 - struct.calcsize(PROTO_FMT)

def pack_protocol(gtp_u, gtp_c, pfcp, bssgp, other):
    """input persen float; disimpan basis 10000."""
    body = struct.pack(PROTO_FMT, *[int(round(x * 100)) for x in (gtp_u, gtp_c, pfcp, bssgp, other)])
    return make_header(TYPE_PROTOCOL, body + b"\x00" * PROTO_PAD)

def unpack_protocol(payload):
    gu, gc, pf, bs, ot = struct.unpack(PROTO_FMT, payload[:struct.calcsize(PROTO_FMT)])
    return {"type": "protocol", "data": {
        "gtp_u": gu / 100.0, "gtp_c": gc / 100.0, "pfcp": pf / 100.0,
        "bssgp": bs / 100.0, "other": ot / 100.0}}


# ---------- dispatch ----------
_UNPACK = {TYPE_GLOBAL: unpack_global, TYPE_TEID: unpack_teid,
           TYPE_EVENT: unpack_event, TYPE_PROTOCOL: unpack_protocol}

def decode(buf: bytes):
    """raw datagram -> dict JSON-ready. raise ValueError on malformed."""
    msg_type, version, length, payload = parse_header(buf)
    fn = _UNPACK.get(msg_type)
    if fn is None:
        raise ValueError(f"unknown msg_type 0x{msg_type:02X}")
    return fn(payload)


if __name__ == "__main__":
    # self-test: pack -> decode roundtrip
    import time
    t = int(time.time())
    tests = [
        pack_global(t, 142, 18000, 9500, 130, 1<<33, 0),
        pack_teid(0xA1B2C3D4, "310410123456789", 7, 1, 1200, 980),
        pack_event(1, 0, 0xAABBCCDD, 312, t),
        pack_protocol(78.2, 9.1, 6.4, 3.0, 3.3),
    ]
    for b in tests:
        print(len(b), "B ->", decode(b))
