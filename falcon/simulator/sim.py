#!/usr/bin/env python3
"""FALCON FPGA Simulator — tiru output gateware FPGA tanpa hardware.
Kirim telemetry palsu (4 tipe) via UDP ke backend :50000. Mirror PRD §7.1.

Jadwal: 0x01 global tiap 1s · 0x04 protocol tiap 1s ·
        0x02 per-TEID tiap 2s (semua sesi aktif) · 0x03 event acak (Poisson).

Usage: python3 sim.py [--host 127.0.0.1] [--port 50000] [--rate 1.0]
"""
import argparse, random, socket, time, sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from shared import contract as C


def rand_imsi():
    # IMSI FIKTIF — dibangkitkan acak untuk demo/simulasi.
    # TIDAK merujuk pelanggan/perangkat nyata. Tidak ada data subscriber asli yang dipakai.
    # Prefix "310410" hanya untuk realisme format (panjang & struktur IMSI), bukan target operator nyata.
    return "310410" + "".join(random.choice("0123456789") for _ in range(9))


class Session:
    __slots__ = ("teid", "imsi", "qfi", "state", "ul", "dl")
    def __init__(self):
        self.teid = random.randint(0x10000000, 0xFFFFFFFF)
        self.imsi = rand_imsi()
        self.qfi = random.choice([1, 5, 6, 7, 9])
        self.state = 1  # ACTIVE
        self.ul = random.randint(100, 2000)
        self.dl = random.randint(100, 2000)
    def tick(self):
        self.ul += random.randint(0, 300)
        self.dl += random.randint(0, 250)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=50000)
    ap.add_argument("--rate", type=float, default=1.0, help="multiplier traffic/event")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dst = (args.host, args.port)
    print(f"[FALCON-SIM] mengirim telemetry ke udp://{args.host}:{args.port} (rate={args.rate})")

    sessions = [Session() for _ in range(random.randint(8, 15))]
    drop_total = 0
    byte_total = 0
    last_teid_push = 0
    next_event = time.time() + random.expovariate(0.5)

    try:
        while True:
            now = time.time()
            ts = int(now)

            # churn sesi: kadang tambah/hapus
            if random.random() < 0.1 and len(sessions) < 60:
                s = Session(); sessions.append(s)
                sock.sendto(C.pack_event(1, 0, s.teid, random.randint(64, 512), ts), dst)  # CreateSession
            if random.random() < 0.05 and len(sessions) > 3:
                s = sessions.pop(random.randrange(len(sessions)))
                sock.sendto(C.pack_event(2, random.randint(0, 1), s.teid, random.randint(64, 256), ts), dst)  # Delete

            for s in sessions:
                s.tick()

            ul_pps = int(sum(1 for _ in sessions) * random.randint(120, 200) * args.rate)
            dl_pps = int(ul_pps * random.uniform(0.4, 0.7))
            byte_total += (ul_pps + dl_pps) * 250
            if random.random() < 0.03:
                drop_total += random.randint(1, 5)

            # 0x01 global (tiap 1s)
            sock.sendto(C.pack_global(ts, len(sessions), ul_pps, dl_pps,
                                      len(sessions), byte_total, drop_total), dst)

            # 0x04 protocol dist (tiap 1s) — normalisasi ke 100
            raw = [random.uniform(70, 85), random.uniform(5, 12),
                   random.uniform(3, 8), random.uniform(1, 5), random.uniform(1, 4)]
            tot = sum(raw); pcts = [x / tot * 100 for x in raw]
            sock.sendto(C.pack_protocol(*pcts), dst)

            # 0x02 per-TEID (tiap 2s, semua sesi)
            if now - last_teid_push >= 2.0:
                for s in sessions:
                    sock.sendto(C.pack_teid(s.teid, s.imsi, s.qfi, s.state, s.ul, s.dl), dst)
                last_teid_push = now

            # 0x03 event acak (Poisson)
            if now >= next_event:
                s = random.choice(sessions)
                sock.sendto(C.pack_event(random.choice([1, 3, 4]),
                                         random.randint(0, 1), s.teid,
                                         random.randint(64, 1400), ts), dst)
                next_event = now + random.expovariate(0.5 * args.rate)

            time.sleep(1.0)
    except KeyboardInterrupt:
        print("\n[FALCON-SIM] stop.")


if __name__ == "__main__":
    main()
