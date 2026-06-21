#!/usr/bin/env python3
"""gen_imsi_test.py — generator paket GTP-U ber-IMSI untuk uji parser FALCON (Level 1).

Bikin N frame Ethernet/IPv4/UDP/GTP-U sintetis, tiap frame bawa TEID unik yang
dipetakan ke IMSI uji (fiktif). Output:
  1. vectors/imsi_frames.txt  — frame hex + expected field (dibaca testbench VHDL)
  2. vectors/imsi_map.csv      — peta TEID<->IMSI (referensi host/dashboard)

Frame layout = identik kontrak parser (lihat tb_gtpu_parser.vhd):
  Eth(14) + IPv4(20, IHL=5) + UDP(8) + GTP-U(12, G-PDU)

CATATAN: IMSI di sini FIKTIF (random) — bukan data pelanggan nyata. Parser FALCON
ekstrak TEID + field GTP-U; IMSI dipakai sebagai label sesi (mapping TEID->IMSI
dikelola host, sesuai BRD). Frame ini buktiin parser ekstrak metadata dgn benar.

Usage:
  python3 gen_imsi_test.py [--n 8] [--seed 42]
"""
import argparse
import os
import random
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
PORT_GTPU = 2152          # 0x0868
ETH_TYPE_IPV4 = 0x0800
IP_PROTO_UDP = 0x11
GTPU_FLAGS = 0x30         # version=1, PT=1
GTPU_MTYPE_GPDU = 0xFF    # G-PDU


def rand_imsi(rng):
    """IMSI FIKTIF — random. Bukan pelanggan nyata. Prefix realisme format saja."""
    return "001010" + "".join(rng.choice("0123456789") for _ in range(9))


def ipv4_checksum(hdr: bytes) -> int:
    s = 0
    for i in range(0, len(hdr), 2):
        s += (hdr[i] << 8) + hdr[i + 1]
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF


def build_frame(teid: int, sport=PORT_GTPU, dport=PORT_GTPU,
                src_ip="10.0.0.1", dst_ip="10.0.0.2") -> bytes:
    """Bangun 1 frame Eth/IPv4/UDP/GTP-U G-PDU byte-exact (54 byte)."""
    # ---- GTP-U (12B): flags, mtype, len(payload after 8B base hdr), TEID, seq/npdu/next ----
    gtpu = struct.pack(">BBH I HBB",
                       GTPU_FLAGS, GTPU_MTYPE_GPDU, 0x000C,
                       teid, 0x0000, 0x00, 0x00)
    # ---- UDP (8B): sport, dport, len(8+gtpu), csum=0 ----
    udp_len = 8 + len(gtpu)
    udp = struct.pack(">HHHH", sport, dport, udp_len, 0x0000)
    # ---- IPv4 (20B, IHL=5) ----
    total_len = 20 + udp_len
    src = bytes(int(x) for x in src_ip.split("."))
    dst = bytes(int(x) for x in dst_ip.split("."))
    ip_no_csum = struct.pack(">BBHHHBBH", 0x45, 0x00, total_len,
                             0x0000, 0x0000, 0x40, IP_PROTO_UDP, 0x0000) + src + dst
    csum = ipv4_checksum(ip_no_csum)
    ip = ip_no_csum[:10] + struct.pack(">H", csum) + ip_no_csum[12:]
    # ---- Ethernet (14B) ----
    eth = bytes.fromhex("aabbccddeeff") + bytes.fromhex("112233445566") + struct.pack(">H", ETH_TYPE_IPV4)
    return eth + ip + udp + gtpu


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=8, help="jumlah frame/sesi")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    out_dir = os.path.join(HERE, "vectors")
    os.makedirs(out_dir, exist_ok=True)

    frames_path = os.path.join(out_dir, "imsi_frames.txt")
    map_path = os.path.join(out_dir, "imsi_map.csv")

    rows = []
    for _ in range(args.n):
        teid = rng.randint(0x10000000, 0xFFFFFFFF)
        imsi = rand_imsi(rng)
        frame = build_frame(teid)
        rows.append((teid, imsi, frame))

    # frame file: <teid_hex> <expected_dport> <frame_hex>
    with open(frames_path, "w") as f:
        for teid, imsi, frame in rows:
            f.write(f"{teid:08x} {PORT_GTPU:04x} {frame.hex()}\n")

    # map file: TEID,IMSI (referensi host/dashboard)
    with open(map_path, "w") as f:
        f.write("teid,imsi\n")
        for teid, imsi, frame in rows:
            f.write(f"0x{teid:08X},{imsi}\n")

    print(f"[imsi-test] {len(rows)} frame -> {frames_path}")
    print(f"[imsi-test] peta TEID<->IMSI -> {map_path}")
    for teid, imsi, frame in rows:
        print(f"  TEID=0x{teid:08X}  IMSI={imsi}  ({len(frame)}B)")


if __name__ == "__main__":
    main()
