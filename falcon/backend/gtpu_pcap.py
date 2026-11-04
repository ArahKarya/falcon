"""Baca payload GTP-U (UDP :2152) dari pcap klasik. Dipakai backend & scripts/replay_gtpu.py."""
from __future__ import annotations

import struct
from typing import Iterator, List


def _frames(path: str) -> Iterator[tuple]:
    with open(path, "rb") as f:
        g = f.read(24)
        if len(g) < 24:
            return
        magic = struct.unpack("<I", g[:4])[0]
        if magic not in (0xA1B2C3D4, 0xA1B23C4D):
            raise ValueError("bukan pcap klasik (pcapng belum didukung): %s" % path)
        linktype = struct.unpack("<I", g[20:24])[0]
        while True:
            h = f.read(16)
            if len(h) < 16:
                return
            caplen = struct.unpack("<I", h[8:12])[0]
            yield linktype, f.read(caplen)


def gtpu_payloads(path: str) -> List[bytes]:
    """Payload UDP (header GTP-U + paket UE) dari tiap frame Ethernet/IPv4/UDP bertujuan port 2152."""
    out: List[bytes] = []
    for lt, fr in _frames(path):
        if lt == 1:
            off = 14
            if len(fr) < off + 28 or struct.unpack("!H", fr[12:14])[0] != 0x0800:
                continue
        elif lt == 113:
            off = 16
            if len(fr) < off + 28:
                continue
        else:
            continue
        ihl = (fr[off] & 0x0F) * 4
        if fr[off + 9] != 17:
            continue
        udp = off + ihl
        if len(fr) < udp + 8:
            continue
        _, dp, ulen = struct.unpack("!HHH", fr[udp:udp + 6])
        if dp != 2152 or ulen < 8:
            continue
        pl = fr[udp + 8:udp + ulen]
        if len(pl) >= 8 and pl[1] == 0xFF:      # G-PDU saja; GTP-C/echo dibuang
            out.append(pl)
    return out
