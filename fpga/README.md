# FALCON FPGA Gateware (VHDL)

Custom firmware FPGA untuk **GTP-U Deep Packet Inspection** — parse paket GTP-U
pada *line-rate*, akumulasi statistik, dan pancarkan **telemetry** (kontrak byte
`0x01`–`0x04`) ke host via UDP `:50000`.

Bahasa **VHDL** (type-safe, dominan di telco/ISE). Target awal **Xilinx Virtex-5**
(toolchain ISE 14.7). Simulasi via **GHDL** — bisa jalan di RPi5 **tanpa hardware**.

> Kontrak byte gateware **terverifikasi byte-exact** terhadap host
> `falcon/shared/contract.py` lewat testbench otomatis (lihat di bawah).

## 🧩 Modul (`rtl/`)

| File | Fungsi |
|---|---|
| `falcon_pkg.vhd` | Package konstanta & tipe — msg id, port, enum, helper header 4B |
| `gtpu_parser.vhd` | Parse Ethernet → IPv4 → UDP → GTP-U; ekstrak TEID, port, msg type, length (IHL adaptif) |
| `protocol_classifier.vhd` | Klasifikasi `gtp_u/gtp_c/pfcp/bssgp/other` berdasar UDP port (kombinatorial) |
| `stats_counter.vhd` | Akumulasi global (UL/DL pps, total bytes, drop) + distribusi protokol |
| `telemetry_packer.vhd` | Susun datagram `0x01`–`0x04` **byte-exact** kontrak host (big-endian, padded) |
| `falcon_top.vhd` | Integrasi: parser → classifier → stats → packer → TX; arbiter emit |

## 🔁 Alur data

```
RX frame (AXI-Stream byte)
   │
   ▼
gtpu_parser ─► protocol_classifier ─► stats_counter ─┐
   │  (TEID, dir, len, ports)                         │
   └──────────────────────────────────────────────────┤
                                                       ▼
   emit_global / emit_proto / emit_event ─► telemetry_packer ─► TX datagram :50000
```

`gtpu_parser` berbasis **byte-counter** (latency rendah, sintesa-friendly), IHL
IPv4 diukur dinamis sehingga offset UDP/GTP-U menyesuaikan bila ada IP options.

## 🧪 Simulasi (GHDL — di RPi5, tanpa hardware)

```bash
# semua testbench (packer byte-exact + parser GTP-U)
bash fpga/sim/run_all.sh

# hanya packer (regen golden dari contract.py lalu bandingkan)
bash fpga/sim/run_packer_tb.sh
```

Testbench:

| TB | Verifikasi |
|---|---|
| `tb/tb_telemetry_packer.vhd` | Output `0x01`–`0x04` **identik byte-per-byte** dengan `contract.py` |
| `tb/tb_gtpu_parser.vhd` | Frame GTP-U sintetis → TEID/port/msg-type/length terparse benar |

`tb/gen_golden.py` meng-encode vektor uji dengan **host `contract.py`** (ground
truth) → `tb/vectors/golden.txt`. Testbench VHDL drive nilai identik lalu
membandingkan. **Cocok = kontrak FPGA↔host tersinkron.**

Output yang diharapkan:
```
TB 1: PASS type=0x01..0x04 → ALL PASS - byte-exact
TB 2: PASS is_gtpu, teid=A1B2C3D4, mtype=0xFF, ... → ALL PASS
```

## 🏗️ Sintesis (Virtex-5 / ISE — di mesin ber-ISE, BUKAN RPi5)

```bash
source /opt/Xilinx/14.7/ISE_DS/settings64.sh
DEVICE=xc5vlx50t-1-ff1136 bash fpga/synth/build_ise.sh
# → fpga/synth/build/falcon_top.bit
```

Alur: `XST → NGDBuild (+UCF) → MAP → PAR → BitGen`. Constraint di
`constraints/falcon_top.ucf` (**pin LOC placeholder — sesuaikan board NOZ**).

## 🔌 Integrasi board (di luar gateware inti)

Gateware ini = **data-path DPI**. Deployment penuh butuh wrapper board-spesifik:

- **Tri-Mode Ethernet MAC** (Virtex-5 TEMAC) — terima frame dari PHY
- **UDP/IP core** (open-source `verilog-ethernet`, atau Xilinx LogiCORE) —
  bungkus TX datagram jadi paket UDP ke host `:50000`
- **Timer 1 Hz** — drive `emit_global` & `emit_proto` periodik
- **Session table** (TEID ↔ IMSI/QFI) — untuk telemetry `0x02` penuh

## 📐 Struktur

```
fpga/
├── rtl/                  # sumber VHDL sintesa
│   ├── falcon_pkg.vhd
│   ├── gtpu_parser.vhd
│   ├── protocol_classifier.vhd
│   ├── stats_counter.vhd
│   ├── telemetry_packer.vhd
│   └── falcon_top.vhd
├── tb/                   # testbench + generator vektor
│   ├── tb_telemetry_packer.vhd
│   ├── tb_gtpu_parser.vhd
│   ├── gen_golden.py
│   └── vectors/golden.txt
├── sim/                  # script GHDL
│   ├── run_all.sh
│   └── run_packer_tb.sh
├── constraints/
│   └── falcon_top.ucf    # Virtex-5 (pin placeholder)
└── synth/
    └── build_ise.sh      # XST → PAR → BitGen
```

## ⚠️ Status & catatan

- ✅ RTL inti + testbench **lulus simulasi** (GHDL, byte-exact + parse benar)
- 🟡 Pin UCF = **placeholder** — butuh pinout board NOZ
- 🟡 MAC/UDP core + timer = wrapper board (belum di repo ini)
- 🟡 Byte-struct = **proposal AKS** — konfirmasi final dengan NOZ
- 🟡 Sintesis bitstream butuh mesin ber-ISE (Virtex-5), bukan RPi5

---

© Arah Karya Sinergi (AKS) × NOZ · FALCON gateware
