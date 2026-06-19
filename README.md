# FALCON — FPGA-Accelerated Live Core Observation Node

Sistem monitoring **GTP-U Deep Packet Inspection (DPI)** real-time. Telemetry dari
akselerator FPGA (parsing line-rate paket GTP-U di plane jaringan seluler) di-stream ke
backend host, lalu divisualisasikan live di dashboard web.

Kolaborasi **Arah Karya Sinergi (AKS)** × **NOZ**. FPGA gateware dikembangkan NOZ;
stack host-side (ini) dikembangkan AKS.

```
┌──────────┐   UDP :50000    ┌──────────┐  WebSocket/REST :8080  ┌───────────┐
│  FPGA /  │ ───telemetry──▶ │ BACKEND  │ ──────live push──────▶ │ DASHBOARD │
│ SIMULATOR│                 │ parse+   │                        │ (web UI)  │
│          │ ◀──ingest:9000──│ state    │                        │           │
└──────────┘                 └──────────┘                        └───────────┘
```

Selama FPGA fisik masih di NOZ, **Simulator** menggantikan output board (kontrak byte
identik). Saat board datang: matikan simulator, arahkan FPGA kirim ke `:50000` — backend
& dashboard tak berubah.

## Struktur

| Path | Fungsi |
|---|---|
| `falcon/shared/contract.py` | Kontrak byte telemetry `0x01`–`0x04` (single source of truth). Pack & unpack. |
| `falcon/simulator/sim.py` | Tiru output FPGA: kirim telemetry palsu realistis ke `:50000`. |
| `falcon/backend/server.py` | UDP listener `:50000` → decode → state → WebSocket + REST `:8080`. |
| `falcon/dashboard/index.html` | UI real-time (tema Hermes Dashboard), konsumsi WebSocket. |
| `docs/` | BRD, PRD, diagram (PDF + sumber Markdown). |
| `source-pdf/` | Dokumen sumber asli dari NOZ (FPGA spec + readme). |

## Menjalankan (host RPi5)

> **PENTING:** di host RPi5, `terminal(background=true)` rusak (`open terminal failed`).
> Jalankan via **tmux detached**.

```bash
cd ~/apps/fpga-dpi

# 1. backend (serve dashboard + API + WebSocket di :8080, listen telemetry :50000)
tmux new-session -d -s falcon-be  ". .venv/bin/activate && python -m falcon.backend.server"

# 2. simulator (pengganti FPGA — kirim telemetry ke :50000)
tmux new-session -d -s falcon-sim ". .venv/bin/activate && python -m falcon.simulator.sim"

# 3. buka dashboard → http://127.0.0.1:8080/
curl -s http://127.0.0.1:8080/api/health
```

Operasi:
```bash
tmux ls                               # lihat session aktif
tmux capture-pane -t falcon-be -p | tail   # baca log backend
tmux kill-session -t falcon-sim       # stop simulator
```

## API

- **WebSocket** `ws(s)://<host>:8080/ws` — push JSON 4 tipe + snapshot awal.
  Dashboard memilih `wss://` otomatis saat diakses via HTTPS (hindari mixed-content).
- **REST**: `/api/health` · `/api/stats/global` · `/api/stats/teid` ·
  `/api/events?limit=N` · `/api/events/counter` · `/api/stats/protocol` ·
  `/api/history` (ring-buffer ~120 titik utk sparkline) · `/api/snapshot` · `/api/version`

## Fitur Dashboard

Konfigurasi tersimpan di browser (`localStorage`) — per-device, tanpa backend write.

| Kategori | Fitur |
|---|---|
| **Kontrol** | Pause/Resume stream (bekukan tampilan), panel Settings (⚙) |
| **Alarm** | Ambang Drop / UL pps / DL pps / Error → kartu KPI flash merah; opsi bunyi |
| **Tabel TEID** | Search (TEID/IMSI), filter QFI, sort tiap kolom, klik baris → detail sesi |
| **Visual** | Sparkline UL/DL/Throughput (histori in-memory), bar protokol, counter event per-tipe |
| **Tampilan** | Mode compact, toggle tiap panel, toggle sparkline, TTL sesi & limit baris/event |

Semua mengikuti **Hermes Design System** (flat: solid, border 1px, sudut tajam, mono untuk angka — tanpa glow/neon/wire).

## Kontrak Byte (proposal AKS — perlu konfirmasi NOZ)

Common header 4B (`msg_type · version · length`) + payload big-endian. Detail di
`falcon/shared/contract.py` + `docs/PRD-FALCON.pdf` §5.
Self-test: `python -m falcon.shared.contract` (pack→decode roundtrip).

## Port

| Arah | Port | Keterangan |
|---|---|---|
| Host → FPGA | UDP `9000` | ingest (hardware-locked) |
| FPGA → Host | UDP `50000` | telemetry (host listening) |
| Backend HTTP/WS | TCP `8080` | dashboard + REST + WebSocket |

## Saat FPGA asli datang

1. Konfirmasi field/offset byte dengan NOZ → patch `falcon/shared/contract.py` bila beda.
2. `tmux kill-session -t falcon-sim`.
3. Arahkan FPGA kirim telemetry ke host `:50000`. Backend & dashboard tak berubah.

## Stack

Python 3.11 async (`aiohttp` + WebSocket). Tanpa DB eksternal (state in-memory untuk PoC).
Dashboard: HTML/CSS/JS vanilla, tema **Hermes Dashboard** (flat, navy + teal/cyan, mono).

---

© Arah Karya Sinergi (AKS) · kolaborasi dengan NOZ
