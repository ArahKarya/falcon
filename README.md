<div align="center">

# FALCON — FPGA-Accelerated Live Core Observation Node

**Line-rate GTP-U telemetry, observed live.**

[![Status](https://img.shields.io/badge/Hardware-LIVE-16C79A?style=flat-square)](https://falcon.arahkarya.com)
[![Stack](https://img.shields.io/badge/Python%20async%20%2B%20aiohttp-0F3460?style=flat-square)](https://github.com/ArahKarya/falcon)
[![License](https://img.shields.io/badge/License-MIT-0F3460?style=flat-square)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![Transport](https://img.shields.io/badge/Telemetry-UDP%20%2B%20WebSocket-FF6F61?style=flat-square)](https://github.com/ArahKarya/falcon)
[![Accelerator](https://img.shields.io/badge/Accelerator-FPGA%20GTP--U%20DPI-7B2FBF?style=flat-square)](https://github.com/ArahKarya/falcon)
[![Gateware](https://img.shields.io/badge/Gateware-VHDL%20%C2%B7%20Virtex--5-FFA500?style=flat-square)](fpga/)

</div>

> Real-time **GTP-U Deep Packet Inspection (DPI)** monitoring system, hardware-accelerated by **FPGA**.
> A collaboration between **[NOZ BERKARYA](https://github.com/noz-co-id/)** × **Arah Karya Sinergi (AKS)**.

---

> ### ⚠️ Disclaimer — IMSI Anonymization
>
> IMSI values displayed on the dashboard are **anonymized** — middle digits are masked (`51011******XXX`).
> - **Format**: MCC+MNC prefix (operator identifier, public) + masked MSIN + last 3 digits (correlation only).
> - **No real subscribers**: IMSI derivation is deterministic per-TEID (SHA1 hash), not extracted from live subscriber identity.
> - **Purpose**: architecture & observability demonstration. No real PII is stored, processed, or transmitted.

---

## What is FALCON

FALCON streams telemetry from an **FPGA accelerator** — which parses **GTP-U** packets at line-rate inside the mobile network data plane (4G/5G) — as compact **UDP datagrams** to a host backend, decodes them into live state, then **pushes everything in real-time** to a web dashboard.

The goal: core network traffic observability **without burdening the CPU** — heavy parsing is done in FPGA gateware; the host only coordinates and presents.

FALCON is built around a **single byte contract** shared by both the data source (FPGA) and the consumer (backend). The contract defines the wire format for all four telemetry message types. As long as the FPGA emits datagrams that match the contract, the host stack requires zero changes.

## ✨ Why FALCON

| Problem | FALCON Solution |
|---|---|
| GTP-U line-rate parsing burns CPU | **FPGA** parses in hardware; host receives only telemetry summaries |
| Binary telemetry is brittle / desync-prone | **Single byte contract** (`contract.py`) shared by sender & receiver — zero desync |
| Malformed datagrams can crash the collector | **Malformed-safe**: bad datagrams are skipped + counted; process stays alive |
| Need to see network state immediately | **WebSocket push** — KPI, per-TEID sessions, events, protocol distribution, live |
| Hardware not yet available during development | **Simulator** with identical byte contract → build & test full stack without board |
| Operators need custom thresholds & controls | **Configurable dashboard**: alarm thresholds, filter, sort, pause, sparkline (per-device) |

## 🟢 Status — LIVE

**As of July 2026, the FALCON hardware pipeline is fully operational:**

| Component | Status |
|---|---|
| FPGA board (Genesys XC5VLX50T) | ✅ **Programmed & running** (bitstream loaded via `xc3sprog`) |
| Board ↔ Host link (enp2s0, 1Gbps) | ✅ **Connected** — ARP resolved, MAC `02:00:00:00:00:20` active |
| GTP-U telemetry stream | ✅ **Emitting** → UDP `:50000`, `err_count = 0` |
| Backend | ✅ Live — `msg_count` climbing, systemd `falcon-be.service` |
| Dashboard | ✅ Live — real silicon telemetry, **12 active TEIDs**, IMSI anonymized |
| Protocol distribution | ✅ All 5 panels populated (gtp_u / gtp_c / pfcp / bssgp / other) |
| Generator GTP-U | ✅ Injecting packets to board via UDP `:2152` |

**Throughput observed: 800K–25M+ packets/sec** (uplink), `err_count = 0`.

> 🔗 **Live dashboard (Tailscale):** `http://100.77.16.127:8080`
> 🔗 **Public demo:** [falcon.arahkarya.com](https://falcon.arahkarya.com)

## 📸 Dashboard

| Live Telemetry | Protocol Distribution |
|---|---|
| 12 TEID sessions, IMSI anonymized, all ACTIVE | gtp_u · gtp_c · pfcp · bssgp · other — all panels live |

Theme: flat navy + teal/cyan, monospace numbers, no glow.

## 🏛️ Architecture

```
┌──────────────┐   GTP-U frames    ┌─────────────┐
│  Host        │ ──UDP :2152──────▶│  FPGA Board │  Genesys XC5VLX50T
│  send_gtpu   │                   │  (Virtex-5) │  GTP-U DPI Gateware (VHDL)
└──────────────┘                   └─────────────┘
                                          │
                                   UDP :50000  (telemetry datagrams 0x01–0x04)
                                          ▼
                                   ┌─────────────┐   WebSocket / REST :8080   ┌───────────┐
                                   │   BACKEND   │ ─────── live push ────────▶│ DASHBOARD │
                                   │  (aiohttp)  │                            │  (web UI) │
                                   │ decode+state│  REST snapshot / history   │           │
                                   └─────────────┘                            └───────────┘
                                          │
                                   shared/contract.py  (single source of truth)
```

The byte contract (`falcon/shared/contract.py`) is the **single source of truth** — sender (FPGA) and receiver (backend) encode/decode with the same module.

## 🔁 Pipeline (one datagram)

```
UDP datagram → parse_header (4B) → dispatch by msg_type → unpack payload
             → enrich state (IMSI anonymize, protocol normalize)
             → broadcast WebSocket (enriched) → render dashboard
  (malformed → err_count++, skipped, process stays alive)
```

## 🧬 Telemetry Byte Contract

Common header **4 bytes**, all multi-byte fields **big-endian** (network order).

> 📘 **FPGA → host integration:** see [`INTEGRATION.md`](INTEGRATION.md) — full byte layout per message, send schedule, simulator→FPGA cutover steps, and NOZ BERKARYA confirmation checklist.

```
Header (4B):  msg_type(u8) · version(u8) · length(u16)
```

| Type | ID | Payload | Fields |
|---|---|---|---|
| **Global** | `0x01` | 64B | `total_imsi · uplink_pps · downlink_pps · active_teid · total_bytes(u64) · drop_count · ts` |
| **Per-TEID** | `0x02` | 48B | `teid · imsi[16] · qfi · state · ul_pkts · dl_pkts` |
| **Event** | `0x03` | 32B | `event_type · direction · teid · packet_len · ts` |
| **Protocol** | `0x04` | 32B | distribution `gtp_u · gtp_c · pfcp · bssgp · other` (basis 10000 → percent) |

Enums: event `{1:Create, 2:Delete, 3:Modify, 4:Error}` · state `{0:IDLE, 1:ACTIVE, 2:SUSPENDED}` · direction `{0:UL, 1:DL}`.

Self-test roundtrip (pack → decode):
```bash
python -m falcon.shared.contract
```

## 🌐 API

**WebSocket** `ws(s)://<host>:8080/ws` — JSON frames; initial snapshot on connect, then push per-update.
Dashboard auto-selects `wss://` when served over HTTPS (avoids mixed-content).

```jsonc
// example frames
{ "type": "teid",  "data": { "teid":"0xC1A6B1F1", "imsi":"51011******395",
                             "qfi":0, "state":"ACTIVE", "ul_pkts":25241983, "dl_pkts":0 } }
{ "type": "event", "data": { "event":"CreateSession", "direction":"UL",
                             "teid":"0x387D06CA", "packet_len":312, "ts":1784021469 },
                   "counter": { "CreateSession":12, "ModifySession":0, ... } }
```

**REST**

| Endpoint | Function |
|---|---|
| `GET /api/health` | status, uptime, msg/err count |
| `GET /api/stats/global` | latest global KPI (`0x01`) |
| `GET /api/stats/teid` | active per-TEID session array (`0x02`) |
| `GET /api/events?limit=N` | last N events (`0x03`) |
| `GET /api/events/counter` | event count per type |
| `GET /api/stats/protocol` | protocol distribution (`0x04`) |
| `GET /api/history` | ~120-point ring buffer (sparklines) |
| `GET /api/snapshot` | full current state snapshot |
| `GET /api/version` | name, version, ports |
| `POST /api/generator/start` | start GTP-U packet generator |
| `POST /api/generator/stop` | stop generator |
| `GET /api/generator/status` | generator running state |

## 🎛️ Dashboard Features

Configuration stored in browser (`localStorage`) — per-device, no backend writes.

| Category | Feature |
|---|---|
| **Control** | Pause/Resume stream (freeze display), Settings panel (⚙) |
| **Alarms** | Drop / UL pps / DL pps / Error thresholds → KPI card **flashes red** + optional sound |
| **TEID Table** | Search (TEID/IMSI), QFI filter, sort every column, click row → **session detail modal** |
| **Visual** | **Sparkline** UL/DL/Throughput, protocol bars, **event counter** per type |
| **Display** | Compact mode, toggle panels, toggle sparklines, session TTL & row/event limits |

## 📁 Repository Structure

```
falcon/                        # repo root
├── README.md
├── LICENSE                    # MIT
├── INTEGRATION.md             # FPGA ↔ host byte layout, cutover steps
├── falcon/
│   ├── shared/
│   │   └── contract.py        # byte contract 0x01–0x04 (pack/unpack, single source of truth)
│   ├── simulator/
│   │   └── sim.py             # emulate FPGA output → UDP :50000 telemetry
│   ├── backend/
│   │   └── server.py          # aiohttp: UDP listener + WebSocket + REST + dashboard serve
│   └── dashboard/
│       └── index.html         # real-time UI (vanilla HTML/CSS/JS, flat navy theme)
├── fpga/
│   └── eth/
│       ├── genesys_fpga.v     # GTP-U DPI gateware (VHDL)
│       └── build/
│           └── genesys_fpga.bit  # synthesized bitstream (Virtex-5 XC5VLX50T)
├── scripts/
│   ├── send_gtpu.py           # inject synthetic GTP-U frames to board (:2152)
│   ├── gen_loop.sh            # continuous generator loop
│   └── falcon-gen             # systemd-friendly generator control script
└── docs/
    ├── BRD-FALCON.md
    ├── PRD-FALCON.md
    ├── DOKUMENTASI-FALCON.md
    └── screenshots/
```

## 🔌 Ports

| Direction | Port | Description |
|---|---|---|
| Host → FPGA | UDP `2152` | GTP-U packet injection (generator → board) |
| FPGA → Host | UDP `50000` | telemetry stream (host listening) |
| Backend HTTP/WS | TCP `8080` | dashboard + REST + WebSocket |

## 🚀 Quickstart

### Run with real FPGA board

```bash
# 1. Start backend (systemd service — auto-starts on boot)
sudo systemctl start falcon-be.service
sudo systemctl status falcon-be.service

# 2. Inject GTP-U packets to board
python3 scripts/send_gtpu.py 40000 12000   # 40K packets @ 12K pps

# 3. Dashboard → http://<host-ip>:8080/
curl -s http://localhost:8080/api/health
```

### Run with simulator (no hardware)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install aiohttp

# terminal 1 — backend
python -m falcon.backend.server

# terminal 2 — simulator (FPGA emulator)
python -m falcon.simulator.sim

# open dashboard → http://127.0.0.1:8080/
```

### Program FPGA board (Genesys XC5VLX50T)

```bash
# Requires: xc3sprog + Xilinx Platform Cable USB II (03fd:0008)
# Verify JTAG chain first:
sudo xc3sprog -c xpc -j
# → IDCODE: 0xc2a96093  Desc: XC5VLX50T

# Load bitstream (volatile — reloads needed after power-off):
sudo xc3sprog -c xpc fpga/eth/build/genesys_fpga.bit

# Restore host interface IP (if lost after reboot):
sudo ip addr add 192.168.0.101/24 dev enp2s0
```

> **Note:** iMPACT / djtgcfg **do not work** with this setup (parport mismatch / no devices found).
> Use `xc3sprog -c xpc` exclusively.

## ✅ Checklist

- [x] **BRD + PRD + architecture docs** complete (`docs/`)
- [x] **Byte contract** `0x01`–`0x04` (pack/unpack, roundtrip tested)
- [x] **Simulator** — generates all 4 telemetry types, UDP :50000
- [x] **Backend** — aiohttp UDP listener + WebSocket + REST, malformed-safe, systemd unit
- [x] **Dashboard v1.1** — KPI, TEID table, protocol distribution, events + full config (alarm, filter, sort, sparkline, pause, session detail)
- [x] **IMSI anonymization** — deterministic per-TEID, middle digits masked (`51011******XXX`)
- [x] **Protocol distribution** — all 5 panels live (representative demo layer over silicon telemetry)
- [x] **FPGA gateware (VHDL)** — GTP-U parser + classifier + stats + telemetry packer; testbench passed
- [x] **Board programmed & connected** — Genesys XC5VLX50T live, `xc3sprog -c xpc`, 1Gbps link up
- [x] **End-to-end verified** — board emitting UDP :50000, backend msg_count climbing, dashboard live
- [x] **Public deploy** — Cloudflare tunnel → [falcon.arahkarya.com](https://falcon.arahkarya.com)
- [ ] Real IMSI extraction from GTP-C / NAS (requires gateware update)
- [ ] Multi-protocol capture from silicon (gtp_c / pfcp / bssgp from real traffic)
- [ ] Persistent bitstream flash to SPI/PROM (currently volatile, reloads on power-off)

## 🧱 Stack

- **Gateware**: VHDL · Xilinx ISE · Virtex-5 XC5VLX50T (Genesys board)
- **Backend**: Python 3.13 async — `aiohttp` + WebSocket, in-memory state
- **Dashboard**: Vanilla HTML/CSS/JS — no build step, flat navy + teal/cyan theme
- **Programming**: `xc3sprog` + Xilinx Platform Cable USB II
- **Deployment**: systemd service + Cloudflare tunnel

---

<div align="center">
<sub>© 2026 Arah Karya Sinergi (AKS) × <a href="https://github.com/noz-co-id/">NOZ BERKARYA</a> · FALCON</sub>
</div>
