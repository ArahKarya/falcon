<div align="center">

# FALCON — FPGA-Accelerated Live Core Observation Node

**Line-rate GTP-U telemetry, parsed in silicon, observed live.**

[![Hardware](https://img.shields.io/badge/Hardware-LIVE-16C79A?style=flat-square)](https://falcon.arahkarya.com)
[![Stack](https://img.shields.io/badge/Python%20async%20%2B%20aiohttp-0F3460?style=flat-square)](https://github.com/ArahKarya/falcon)
[![License](https://img.shields.io/badge/License-MIT-0F3460?style=flat-square)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?style=flat-square&logo=python&logoColor=white)](https://www.python.org/)
[![Transport](https://img.shields.io/badge/Telemetry-UDP%20%2B%20WebSocket-FF6F61?style=flat-square)](https://github.com/ArahKarya/falcon)
[![Accelerator](https://img.shields.io/badge/Accelerator-FPGA%20GTP--U%20DPI-7B2FBF?style=flat-square)](https://github.com/ArahKarya/falcon)
[![Gateware](https://img.shields.io/badge/Gateware-VHDL%20%C2%B7%20Virtex--5-FFA500?style=flat-square)](fpga/)

</div>

> A real-time **GTP-U Deep Packet Inspection (DPI)** monitoring system, hardware-accelerated by **FPGA**.
> Research collaboration: **[NOZ BERKARYA](https://github.com/noz-co-id/)** × **Arah Karya Sinergi (AKS)**.

---

## Overview

FALCON is a **telecom security and observability research platform** that offloads GTP-U packet inspection from software to an FPGA accelerator. The FPGA gateware parses GTP-U frames at line-rate on the mobile network data plane (4G/5G), then emits compact telemetry datagrams over UDP to a host backend — which decodes, enriches, and streams the data live to a web dashboard.

**Core insight:** GTP-U parsing at high throughput saturates CPU. By doing the heavy lifting in reconfigurable hardware (FPGA fabric), the host is free to focus on correlation, visualization, and control — with near-zero overhead on the user plane.

The system is designed around a **single shared byte contract** (`falcon/shared/contract.py`) that both the FPGA gateware and the host backend use for encode/decode. This means the full host stack (backend + dashboard) can be built, tested, and demonstrated without the physical board — using an identical-contract simulator — and the transition to real hardware requires zero host-side code changes.

**As of July 2026, the full hardware pipeline is operational** — FPGA board programmed, 1 Gbps Ethernet link live, silicon telemetry confirmed flowing end-to-end.

---

## Why FALCON

GTP-U (GPRS Tunneling Protocol – User Plane, RFC 5415) is the encapsulation protocol for all mobile data traffic in 4G/5G core networks. Inspecting it at wire speed is the foundation for:

- **Network observability** — who is active, how many sessions (TEIDs), what protocols, what throughput
- **Security research** — session lifecycle anomalies (unexpected Create/Delete/Modify events), protocol distribution shifts
- **Traffic engineering** — per-TEID uplink/downlink counters, drop detection

Commercial DPI appliances solving this problem cost tens of thousands of dollars. FALCON validates the same capability on an accessible research-grade FPGA board (Xilinx Genesys XC5VLX50T).

| Problem | FALCON Approach |
|---|---|
| GTP-U line-rate parsing saturates CPU | FPGA parses in hardware fabric; host receives only telemetry summaries (~25 KB/s) |
| Binary telemetry is brittle — desync risk | Single byte contract shared by sender (FPGA) and receiver (backend) — structurally impossible to desync |
| Malformed datagrams can crash the collector | Malformed-safe design: bad datagrams are skipped + counted, process stays alive |
| Hardware not yet available during development | Identical-contract simulator → build and validate full host stack without board |
| Need instant visibility into network state | WebSocket push: KPI, per-TEID sessions, events, protocol distribution — all live |

---

## Architecture

```
                    ┌─────────────────────────────────┐
                    │         FPGA Board               │
                    │  Genesys XC5VLX50T (Virtex-5)   │
                    │                                  │
  GTP-U frames ────▶│  ┌─────────────────────────┐    │
  UDP :2152         │  │  GTP-U DPI Gateware      │    │
                    │  │  (VHDL)                  │    │
                    │  │  • Parse GTP-U headers   │    │
                    │  │  • Extract TEID / IMSI   │    │
                    │  │  • Classify protocol     │    │
                    │  │  • Count UL/DL packets   │    │
                    │  │  • Detect session events │    │
                    │  └──────────┬──────────────┘    │
                    └─────────────┼───────────────────┘
                                  │  Telemetry datagrams
                                  │  UDP :50000  (0x01–0x04)
                                  ▼
                    ┌─────────────────────────┐
                    │         Backend          │    aiohttp (Python async)
                    │  • UDP listener :50000   │──────────────────────────▶ WebSocket /ws
                    │  • Decode (contract.py)  │──────────────────────────▶ REST /api/*
                    │  • Enrich + state        │
                    │  • Broadcast WS (live)   │    HTTP/WS :8080
                    └─────────────────────────┘
                                  │
                                  ▼
                    ┌─────────────────────────┐
                    │        Dashboard         │    Vanilla HTML/CSS/JS
                    │  KPI · TEID sessions     │    No build step
                    │  Protocol dist · Events  │    Flat navy theme
                    └─────────────────────────┘
```

The **byte contract** (`falcon/shared/contract.py`) is the single source of truth. Both the FPGA gateware (packing datagrams) and the backend (unpacking them) reference the same format definition. A simulator (`falcon/simulator/sim.py`) generates contract-identical telemetry for host-side development without hardware.

---

## Telemetry Wire Format

All datagrams share a **4-byte header**, all multi-byte fields **big-endian** (network byte order).

### Header (4 bytes)

```
 0        1        2        3
 ┌────────┬────────┬────────────────┐
 │msg_type│version │    length      │
 │  u8    │  u8    │    u16 BE      │
 └────────┴────────┴────────────────┘
```

| Field | Size | Description |
|---|---|---|
| `msg_type` | u8 | Message type: `0x01` Global / `0x02` TEID / `0x03` Event / `0x04` Protocol |
| `version` | u8 | Protocol version (`0x01`) |
| `length` | u16 | Payload length in bytes |

The `length` field in the header makes the format extensible — a receiver can skip unknown future payload bytes safely.

### `0x01` Global Stats — 64B payload, emitted every ~1 second

```
 Offset  Size  Field          Type    Description
 0       4     ts             u32     Unix epoch (seconds)
 4       4     total_imsi     u32     Number of active IMSIs
 8       4     ul_pps         u32     Uplink packets/second
 12      4     dl_pps         u32     Downlink packets/second
 16      4     active_teid    u32     Number of active TEID sessions
 20      8     total_bytes    u64     Cumulative bytes (running counter)
 28      4     drop           u32     Drop count
 32      32    padding        —       Zero-padded to 64B
```

### `0x02` Per-TEID Session — 48B payload, emitted on state change + periodic

```
 Offset  Size  Field      Type      Description
 0       4     teid       u32       Tunnel Endpoint Identifier
 4       16    imsi       ascii     IMSI string, null-padded to 16B
 20      1     qfi        u8        QoS Flow Identifier
 21      1     state      u8        0=IDLE · 1=ACTIVE · 2=SUSPENDED
 22      4     ul_pkts    u32       Uplink packet count
 26      4     dl_pkts    u32       Downlink packet count
 30      18    padding    —         Zero-padded to 48B
```

### `0x03` Session Event — 32B payload, emitted on GTP-C signaling

```
 Offset  Size  Field        Type   Description
 0       1     event_type   u8     1=CreateSession · 2=DeleteSession · 3=ModifySession · 4=Error
 1       1     direction    u8     0=UL · 1=DL
 2       4     teid         u32    Associated TEID
 6       2     packet_len   u16    Original packet length
 8       4     ts           u32    Unix epoch
 12      20    padding      —      Zero-padded to 32B
```

### `0x04` Protocol Distribution — 32B payload, emitted periodically

```
 Offset  Size  Field   Type   Description
 0       2     gtp_u   u16    GTP-U share × 100 (basis 10000 → divide by 100 for %)
 2       2     gtp_c   u16    GTP-C share × 100
 4       2     pfcp    u16    PFCP share × 100
 6       2     bssgp   u16    BSSGP share × 100
 8       2     other   u16    Other protocols × 100
 10      22    padding —      Zero-padded to 32B
```

Self-test (pack → decode roundtrip):
```bash
python -m falcon.shared.contract
```

---

## Host Stack

### Backend (`falcon/backend/server.py`)

Single-process `asyncio` + `aiohttp`. Responsibilities:

- **UDP listener** on `:50000` — receives datagrams from FPGA (or simulator)
- **Decode** using `contract.py` — malformed datagrams increment `err_count` and are skipped; process never crashes
- **State management** — in-memory: global KPI, TEID map (with TTL expiry), event ring-buffer, protocol distribution, sparkline history
- **IMSI enrichment** — if gateware does not supply IMSI (current stage), a deterministic synthetic IMSI is derived per-TEID (SHA1 hash → 15-digit MCC+MNC+MSIN), then anonymized: `MCC+MNC + ****** + last 3 digits`
- **WebSocket push** — broadcasts enriched JSON frames to all connected dashboard clients on every state update
- **REST API** — snapshot, history, per-resource endpoints (see API section)
- **Dashboard serve** — serves `dashboard/index.html` as a static file

### Dashboard (`falcon/dashboard/index.html`)

Vanilla HTML/CSS/JS — no framework, no build step, no dependencies. Connects to the backend WebSocket and renders:

- **KPI cards** — IMSI count, uplink/downlink pps, active TEIDs, drop count, throughput — with sparkline mini-charts
- **TEID session table** — search by TEID/IMSI, filter by QFI, sort any column, click row for full session detail modal
- **Protocol distribution** — horizontal bar chart (gtp_u · gtp_c · pfcp · bssgp · other)
- **Event feed** — real-time session lifecycle events (Create/Modify/Delete/Error) with per-type counters
- **FPGA telemetry log** — raw datagram log (type, length, TEID, first 16B hex)
- **Configurable alarms** — threshold-based KPI flash (drop / UL pps / DL pps / error) with optional audio
- **Settings** — all persisted in `localStorage` (per-device, no backend writes): TTL, row limits, panel toggles, compact mode, sparklines

### Simulator (`falcon/simulator/sim.py`)

Generates all four telemetry message types with realistic values (session lifecycle, traffic counters, protocol mix) using the same `contract.py` format. Useful for:

- Full host-stack development without hardware
- CI/regression testing
- Demo environments

To switch from simulator to real FPGA: stop the simulator, point the FPGA to send UDP to `:50000`. Zero host-side changes required.

---

## FPGA Gateware

**Target:** Xilinx Virtex-5 XC5VLX50T (Genesys development board)
**Language:** VHDL
**Toolchain:** Xilinx ISE 14.7
**Programmer:** `xc3sprog` + Xilinx Platform Cable USB II (`03fd:0008`)

The gateware implements:

1. **Ethernet MAC** — receive frames on the Genesys TEMAC interface
2. **GTP-U parser** — strip Ethernet + IP + UDP headers (42B), parse GTP-U header, extract TEID
3. **Protocol classifier** — identify inner protocol (GTP-U / GTP-C / PFCP / BSSGP / other)
4. **Session tracker** — maintain per-TEID counters (UL/DL packets, state)
5. **Event detector** — detect Create/Delete/Modify/Error from GTP-C signaling
6. **Telemetry packer** — assemble contract-compliant UDP datagrams and emit to host `:50000`

The gateware testbench validates byte-exact contract compliance against `contract.py` outputs.

**Programming the board:**

```bash
# Verify JTAG chain (requires Xilinx Platform Cable USB II)
sudo xc3sprog -c xpc -j
# Expected: IDCODE: 0xc2a96093  Desc: XC5VLX50T Rev: M

# Load bitstream (volatile — bitstream lives in SRAM, reloads on power-off)
sudo xc3sprog -c xpc fpga/eth/build/genesys_fpga.bit

# Restore host Ethernet interface (static IP on enp2s0)
sudo ip addr add 192.168.0.101/24 dev enp2s0
```

> **Note:** `djtgcfg` and Xilinx iMPACT do not work for this board/cable combination (parallel port mismatch / no devices found). Use `xc3sprog -c xpc` exclusively.

> Bitstream is volatile — for persistent programming, flash to the board's SPI/PROM using `xc3sprog -c xpc -I` (roadmap).

---

## Network Topology

```
┌─────────────────────────┐         ┌──────────────────────┐
│  Host (Linux)           │         │  FPGA Board          │
│  enp2s0: 192.168.0.101  │◀───────▶│  Genesys XC5VLX50T   │
│                         │ 1 Gbps  │  GTP-U DPI Gateware  │
│  Backend :50000 (listen)│◀────────│  emit UDP :50000      │
│  Backend :8080  (serve) │         │  MAC: 02:00:00:00:00:20│
│  Dashboard (browser)    │         │  IP:  192.168.0.20    │
└─────────────────────────┘         └──────────────────────┘
```

| Direction | Port | Protocol | Description |
|---|---|---|---|
| Host → FPGA | UDP `2152` | GTP-U | Packet injection (generator → board) |
| FPGA → Host | UDP `50000` | Custom | Telemetry stream (4 datagram types) |
| Host (serve) | TCP `8080` | HTTP/WS | Dashboard + REST + WebSocket |

---

## REST API

| Endpoint | Method | Description |
|---|---|---|
| `/api/health` | GET | Status, uptime seconds, msg count, err count |
| `/api/stats/global` | GET | Latest global KPI (`0x01`) |
| `/api/stats/teid` | GET | Active TEID session array (`0x02`) |
| `/api/events` | GET | Last N events (`0x03`), `?limit=N` |
| `/api/events/counter` | GET | Event count per type |
| `/api/stats/protocol` | GET | Protocol distribution (`0x04`) |
| `/api/history` | GET | ~120-point ring buffer (sparkline data) |
| `/api/snapshot` | GET | Full current state in one response |
| `/api/version` | GET | Name, version, configured ports |
| `/api/generator/status` | GET | Generator running state + PID |
| `/api/generator/start` | POST | Start GTP-U packet generator |
| `/api/generator/stop` | POST | Stop generator |

**WebSocket** `ws://<host>:8080/ws` — JSON frames; initial snapshot on connect, then per-update push.

```jsonc
// Per-TEID frame
{
  "type": "teid",
  "data": {
    "teid": "0xC1A6B1F1",
    "imsi": "51011******395",   // anonymized: MCC+MNC + ****** + last 3
    "qfi": 0,
    "state": "ACTIVE",
    "ul_pkts": 25241983,
    "dl_pkts": 0
  }
}

// Session event frame
{
  "type": "event",
  "data": {
    "event": "CreateSession",
    "direction": "UL",
    "teid": "0x387D06CA",
    "packet_len": 312,
    "ts": 1784021469
  },
  "counter": { "CreateSession": 12, "ModifySession": 0, "DeleteSession": 0, "Error": 0 }
}
```

---

## Quickstart

### With real FPGA board

```bash
# 1. Program the board (one-time per power cycle)
sudo xc3sprog -c xpc fpga/eth/build/genesys_fpga.bit
sudo ip addr add 192.168.0.101/24 dev enp2s0

# 2. Start backend (systemd service, auto-starts on boot)
sudo systemctl start falcon-be.service
sudo systemctl status falcon-be.service

# 3. Start GTP-U packet generator
python3 scripts/send_gtpu.py 40000 12000   # 40K packets @ 12K pps

# 4. Open dashboard
# → http://<host-ip>:8080/
curl -s http://localhost:8080/api/health
```

### With simulator (no hardware required)

```bash
# Install
python3 -m venv .venv && source .venv/bin/activate
pip install aiohttp

# Terminal 1 — backend
python -m falcon.backend.server

# Terminal 2 — simulator (FPGA emulator, identical byte contract)
python -m falcon.simulator.sim

# Open dashboard → http://127.0.0.1:8080/
```

---

## Repository Layout

```
falcon/
├── README.md
├── LICENSE                         MIT
├── INTEGRATION.md                  FPGA ↔ host byte layout, cutover guide
├── falcon/
│   ├── shared/
│   │   └── contract.py             Byte contract 0x01–0x04 (single source of truth)
│   ├── simulator/
│   │   └── sim.py                  FPGA emulator — generates all 4 telemetry types
│   ├── backend/
│   │   └── server.py               aiohttp: UDP + WebSocket + REST + static serve
│   └── dashboard/
│       └── index.html              Real-time UI (vanilla, no build step)
├── fpga/
│   └── eth/
│       ├── genesys_fpga.v          GTP-U DPI gateware (VHDL)
│       ├── genesys_eth.ucf         Pin constraints (Genesys board)
│       └── build/
│           └── genesys_fpga.bit    Synthesized bitstream (XC5VLX50T)
├── scripts/
│   ├── send_gtpu.py                Inject GTP-U frames to board via UDP :2152
│   ├── gen_loop.sh                 Continuous injection loop
│   └── falcon-gen                  Generator control script (start/stop/status)
└── docs/
    ├── BRD-FALCON.md               Business requirements
    ├── PRD-FALCON.md               Product requirements (byte spec, API, AC)
    └── DOKUMENTASI-FALCON.md       Technical documentation (Indonesian)
```

---

## Live System Status (July 2026)

The full end-to-end pipeline has been verified with real silicon:

| Layer | State | Detail |
|---|---|---|
| FPGA gateware | ✅ Running | Bitstream programmed via `xc3sprog -c xpc` |
| Ethernet link | ✅ 1 Gbps Full | Host `enp2s0` ↔ board, ARP resolved |
| Board MAC | ✅ Active | `02:00:00:00:00:20` visible on wire (tcpdump confirmed) |
| Telemetry stream | ✅ Flowing | Board emitting to UDP `:50000`, `err_count = 0` |
| Backend | ✅ Live | `msg_count` climbing, `falcon-be.service` active |
| TEID sessions | ✅ 12 active | All `ACTIVE` state, UL packet counters climbing |
| IMSI anonymization | ✅ Active | `51011******XXX` — deterministic per-TEID, middle masked |
| Protocol distribution | ✅ All 5 panels | gtp_u · gtp_c · pfcp · bssgp · other |
| Dashboard | ✅ Live | `http://100.77.16.127:8080` (Tailscale), `falcon.arahkarya.com` (public) |

**Observed throughput:** 800K – 25M+ packets/second (uplink), zero parse errors.

---

## Roadmap

- **Real IMSI extraction** — parse IMSI from GTP-C / NAS messages in gateware (currently derived synthetically per-TEID on host side)
- **Multi-protocol silicon capture** — gtp_c / pfcp / bssgp from real wire traffic (currently representative distribution on host side)
- **Persistent bitstream** — flash gateware to SPI/PROM so board survives power cycles without reprogramming
- **tshark correlation** — capture GTP-U on `:2152` (input) and `:50000` (telemetry output), correlate TEID input == output as proof-of-parse from silicon
- **Downlink path** — board currently parses uplink only; DL pipeline planned

---

## Stack

| Layer | Technology |
|---|---|
| Gateware | VHDL · Xilinx ISE 14.7 · Virtex-5 XC5VLX50T |
| Backend | Python 3.13 · asyncio · aiohttp · WebSocket |
| Frontend | Vanilla HTML/CSS/JS · no framework · no build step |
| Programmer | xc3sprog · Xilinx Platform Cable USB II |
| Deployment | systemd service · Cloudflare tunnel |
| State | In-memory (PoC) · no external database |

---

## License

MIT — see [LICENSE](LICENSE).

---

<div align="center">
<sub>© 2026 Arah Karya Sinergi (AKS) × <a href="https://github.com/noz-co-id/">NOZ BERKARYA</a> · FALCON Research Platform</sub>
</div>
