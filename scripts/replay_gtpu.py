#!/usr/bin/env python3
"""replay_gtpu.py — kirim ulang GTP-U hasil tangkapan stack LTE (Open5GS+srsRAN) ke papan FALCON.

Sumber : pcap S1-U (eNB -> SGW-U, UDP 2152) hasil tcpdump.
Tujuan : papan FPGA 192.168.0.20:2152 (UDP).
Yang dikirim = PAYLOAD UDP apa adanya (header GTP-U + IP paket UE), identik dengan yang ditangkap.
Hanya alamat IP/MAC lapis luar yang berganti (sengaja: board hanya menerima paket yang tujuannya dia).

Pakai: replay_gtpu.py <file.pcap> [pps=100] [loop=1] [target=192.168.0.20:2152]
"""
import socket, struct, sys, time

def read_pcap(path):
    with open(path, "rb") as f:
        g = f.read(24)
        magic = struct.unpack("<I", g[:4])[0]
        if magic not in (0xa1b2c3d4, 0xa1b23c4d):
            raise SystemExit("bukan pcap klasik (pcapng belum didukung): %s" % path)
        nano = (magic == 0xa1b23c4d)
        linktype = struct.unpack("<I", g[20:24])[0]
        while True:
            h = f.read(16)
            if len(h) < 16: return
            _, _, caplen, _ = struct.unpack("<IIII", h)
            yield linktype, f.read(caplen)

def gtpu_payloads(path):
    """Ambil payload UDP dst-port 2152 dari tiap frame Ethernet/IPv4/UDP."""
    for lt, fr in read_pcap(path):
        if lt == 1:   off = 14                      # Ethernet
        elif lt == 113: off = 16                    # Linux cooked
        else: continue
        if len(fr) < off + 28: continue
        if struct.unpack("!H", fr[off-2:off])[0] != 0x0800 and lt == 1: continue
        ihl = (fr[off] & 0x0F) * 4
        if fr[off + 9] != 17: continue
        udp = off + ihl
        sp, dp, ulen = struct.unpack("!HHH", fr[udp:udp+6])
        if dp != 2152: continue
        yield fr[udp+8: udp+ulen]

def main():
    if len(sys.argv) < 2: raise SystemExit(__doc__)
    path = sys.argv[1]
    pps  = int(sys.argv[2]) if len(sys.argv) > 2 else 100
    loop = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    host, port = (sys.argv[4] if len(sys.argv) > 4 else "192.168.0.20:2152").rsplit(":", 1)
    pl = list(gtpu_payloads(path))
    if not pl: raise SystemExit("tidak ada GTP-U di pcap")
    sizes = sorted(set(len(p) for p in pl))
    print("dimuat %d paket GTP-U, ukuran payload UDP: %s B" % (len(pl), sizes[:5]))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    gap = 1.0 / pps; t0 = time.time(); n = 0; tot = 0
    for _ in range(loop):
        for p in pl:
            s.sendto(p, (host, int(port))); n += 1; tot += len(p)
            d = t0 + n * gap - time.time()
            if d > 0: time.sleep(d)
    dt = time.time() - t0
    print("terkirim %d paket, %d B GTP-U (payload UDP) dalam %.2f dtk = %.0f pps" % (n, tot, dt, n / dt))
    print("harapan board: total_bytes naik %d" % tot)

if __name__ == "__main__":
    main()
