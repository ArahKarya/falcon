# FALCON — Panduan Integrasi FPGA → Host

> Cara menghubungkan board FPGA (gateware GTP-U DPI) ke backend FALCON.
> Untuk: tim **NOZ** (gateware) × **AKS** (host stack).

> ⚠️ **Data demo saat ini SIMULASI.** Simulator (`falcon/simulator/sim.py`) meniru
> persis output yang harus dihasilkan FPGA. Dokumen ini adalah kontrak yang harus
> diikuti gateware agar cutover ke hardware **tanpa mengubah satu baris pun kode host**.

---

## 1. Transport

FPGA mengirim telemetry sebagai **datagram UDP one-way** ke backend host.
Tidak ada handshake, tidak ada ACK, tidak ada TCP, tidak ada driver khusus.

| Item              | Nilai                              |
|-------------------|------------------------------------|
| Protokol          | **UDP** (fire-and-forget)          |
| Tujuan            | `IP_HOST : 50000`                  |
| Backend listen    | `0.0.0.0 : 50000`                  |
| Arah              | FPGA → Host (push only)            |
| Byte order        | **Big-endian** (network order)     |
| Backend HTTP/WS   | `0.0.0.0 : 8080` (host → browser)  |

FPGA hanya butuh **UDP/IP stack** (MAC + IP + UDP — lwIP atau header hardcoded).
Kirim datagram → selesai. Host tidak pernah membalas.

```
  ┌────────────┐   UDP :50000    ┌──────────────┐   WebSocket    ┌───────────┐
  │   FPGA     │ ──────────────► │  Backend Host│ ─────────────► │ Dashboard │
  │ GTP-U DPI  │   telemetry     │  (decode +   │   :8080        │  (browser)│
  │  gateware  │   (4 tipe)      │   broadcast) │                │           │
  └────────────┘                 └──────────────┘                └───────────┘
```

---

## 2. Format datagram

Setiap datagram = **header 4 byte + payload**.

### Header (4B) — `>BBH`

| Offset | Size | Field      | Type   | Keterangan                       |
|--------|------|------------|--------|----------------------------------|
| 0      | 1    | `msg_type` | u8     | `0x01`/`0x02`/`0x03`/`0x04`      |
| 1      | 1    | `version`  | u8     | `0x01` (PROTO_VERSION)           |
| 2      | 2    | `length`   | u16 BE | panjang payload (byte)           |

`length` membuat perubahan internal aman — parser membaca payload sesuai `length`.

---

## 3. Tipe pesan

Sumber kebenaran tunggal: **`falcon/shared/contract.py`**. Tabel di bawah adalah
mirror-nya. Jika berbeda, **`contract.py` yang menang**.

### `0x01` GLOBAL — payload 64B (`>IIIIIQI` + padding)

| Field         | Type    | Keterangan                          |
|---------------|---------|-------------------------------------|
| `ts`          | u32     | Unix epoch (detik)                  |
| `total_imsi`  | u32     | jumlah IMSI aktif                   |
| `ul_pps`      | u32     | uplink paket/detik                  |
| `dl_pps`      | u32     | downlink paket/detik                |
| `active_teid` | u32     | jumlah sesi (TEID) aktif            |
| `total_bytes` | u64     | akumulasi byte (counter kumulatif)  |
| `drop`        | u32     | jumlah paket drop                   |
| _padding_     | 32B     | nol hingga payload genap 64B        |

Frekuensi: **tiap 1 detik**.

### `0x02` PER-TEID — payload 48B (`>I16sBBII` + padding)

| Field      | Type      | Keterangan                                |
|------------|-----------|-------------------------------------------|
| `teid`     | u32       | Tunnel Endpoint ID                        |
| `imsi`     | 16B ascii | string IMSI, null-padded ke 16B           |
| `qfi`      | u8        | QoS Flow ID (5G) / QCI (4G)               |
| `state`    | u8        | `0`=IDLE `1`=ACTIVE `2`=SUSPENDED         |
| `ul_pkts`  | u32       | total paket uplink sesi ini               |
| `dl_pkts`  | u32       | total paket downlink sesi ini             |
| _padding_  | 18B       | nol hingga payload genap 48B              |

Frekuensi: **tiap 2 detik**, satu datagram per TEID aktif.

### `0x03` EVENT — payload 32B (`>BBIHI` + padding)

| Field         | Type | Keterangan                                          |
|---------------|------|-----------------------------------------------------|
| `event_type`  | u8   | `1`=CreateSession `2`=DeleteSession `3`=ModifySession `4`=Error |
| `direction`   | u8   | `0`=UL `1`=DL                                        |
| `teid`        | u32  | TEID terkait                                         |
| `packet_len`  | u16  | ukuran paket pemicu (byte)                           |
| `ts`          | u32  | Unix epoch (detik)                                   |
| _padding_     | 20B  | nol hingga payload genap 32B                         |

Frekuensi: **asinkron**, saat event terjadi.

### `0x04` PROTOCOL DIST — payload 32B (`>HHHHH` + padding)

| Field    | Type | Keterangan                              |
|----------|------|-----------------------------------------|
| `gtp_u`  | u16  | persen × 100 (basis 10000)              |
| `gtp_c`  | u16  | persen × 100                            |
| `pfcp`   | u16  | persen × 100                            |
| `bssgp`  | u16  | persen × 100                            |
| `other`  | u16  | persen × 100                            |
| _padding_| 22B  | nol hingga payload genap 32B            |

Contoh: `gtp_u = 78.2%` → kirim `7820`. Host decode: `7820 / 100.0 = 78.2`.
Frekuensi: **tiap 1 detik**.

---

## 4. Verifikasi mandiri (sebelum board siap)

NOZ bisa cek byte-layout tanpa host hidup:

```bash
cd falcon
python3 shared/contract.py     # self-test pack -> decode roundtrip
```

Output menunjukkan ukuran byte tiap pesan + hasil decode — persis yang FPGA harus hasilkan.

Test kirim manual ke backend (mis. dari laptop NOZ):

```python
import socket
from shared import contract as C
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
pkt = C.pack_teid(0xA1B2C3D4, "001011234567890", 7, 1, 1200, 980)
s.sendto(pkt, ("IP_HOST", 50000))   # ganti IP_HOST
```

Datagram langsung muncul di dashboard `:8080`.

---

## 5. Cutover: simulator → FPGA

1. Matikan simulator di host: `tmux kill-session -t falcon-sim`
2. Set FPGA kirim UDP ke `IP_HOST:50000`
3. Backend tetap jalan — **tidak ada kode host yang berubah**
4. Dashboard langsung menampilkan data FPGA nyata

---

## 6. Checklist konfirmasi NOZ

Beberapa field masih **asumsi AKS**. Mohon NOZ validasi sebelum tape-out:

- [ ] **Endianness** — host pakai big-endian. FPGA juga BE?
- [ ] **IMSI encoding** — host asumsi ASCII 16B null-padded. FPGA kirim ASCII atau BCD/packed?
- [ ] **QFI vs QCI** — field `qfi` (u8): 5G QFI atau 4G QCI?
- [ ] **`total_bytes`** — counter kumulatif (naik terus) atau per-interval reset?
- [ ] **`ts`** — Unix epoch detik (u32) atau format lain (mis. milidetik / monotonic)?
- [ ] **Padding** — host abaikan padding (baca sesuai `length`). FPGA boleh isi nol?
- [ ] **MTU** — datagram terbesar 64B+4B header = 68B, jauh di bawah MTU. OK.

---

**Pertanyaan kontrak → balas di repo issue atau langsung ke AKS.**
File ini + `shared/contract.py` adalah satu-satunya yang harus disinkronkan kedua tim.
