# FALCON — Host-side Stack (Simulator + Backend + Dashboard)

**FALCON** · *FPGA-Accelerated Live Core Observation Node*
Stack host-side yang berjalan **tanpa FPGA fisik** (FPGA masih di NOZ). Saat board asli datang,
cukup matikan Simulator — output gateware FPGA langsung kompatibel (kontrak byte sama).

## Arsitektur
```
SIMULATOR ──UDP:50000──▶ BACKEND ──WebSocket/REST:8080──▶ DASHBOARD
(ganti FPGA)             (parse+state)                    (live UI)
```

## Komponen
| Path | Fungsi |
|---|---|
| `shared/contract.py` | Kontrak byte telemetry 0x01-0x04 (single source of truth). Pack & unpack. |
| `simulator/sim.py` | Tiru output FPGA: kirim telemetry palsu realistis ke :50000 |
| `backend/server.py` | UDP listener :50000 → decode → state → WebSocket push + REST :8080 |
| `dashboard/index.html` | UI real-time (tema Hermes Dashboard), konsumsi WebSocket |

## Menjalankan

> **PENTING (host RPi5):** `terminal(background=true)` rusak ("open terminal failed").
> Jalankan via **tmux detached**. Lihat skill `long-lived-process-tmux-workaround`.

```bash
cd ~/apps/fpga-dpi/falcon
# 1. backend
tmux new-session -d -s falcon-be  "../.venv/bin/python backend/server.py 2>&1 | tee /tmp/falcon-be.log"
# 2. simulator
tmux new-session -d -s falcon-sim "../.venv/bin/python simulator/sim.py 2>&1 | tee /tmp/falcon-sim.log"
# 3. buka dashboard
#    http://127.0.0.1:8080/
```

Operasi:
```bash
tmux ls                              # lihat session
tmux capture-pane -t falcon-be -p | tail   # baca log
tmux kill-session -t falcon-sim      # stop simulator
curl -s http://127.0.0.1:8080/api/health   # health check
```

## API
- WebSocket: `ws://<host>:8080/ws` — push JSON 4 tipe + snapshot awal
- REST: `/api/health` `/api/stats/global` `/api/stats/teid` `/api/events?limit=N` `/api/stats/protocol` `/api/snapshot`

## Kontrak Byte (proposed AKS — konfirmasi NOZ)
Lihat `shared/contract.py` + PRD §5. Common header 4B (`msg_type·version·length`) + payload big-endian.
Self-test: `python3 shared/contract.py` (pack→decode roundtrip).

## Saat FPGA asli datang
1. Konfirmasi field/offset byte dengan NOZ → patch `shared/contract.py` bila beda.
2. Matikan `falcon-sim`.
3. Arahkan FPGA kirim telemetry ke host :50000. Backend & dashboard tak berubah.
