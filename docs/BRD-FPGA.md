# Business Requirements Document (BRD)
## FALCON — FPGA GTP-U DPI Engine & Telemetry Platform

> **FALCON** · *FPGA-Accelerated Live Core Observation Node*

| | |
|---|---|
| **Dokumen** | Business Requirements Document (BRD) |
| **Project** | **FALCON** — FPGA GTP-U Deep Packet Inspection Engine |
| **Kode/Codename** | FALCON (FPGA-Accelerated Live Core Observation Node) |
| **Versi** | 1.0 |
| **Tanggal** | Juni 2026 |
| **Disusun oleh** | Arah Karya Sinergi (AKS) |
| **Kolaborator** | NOZ — Tri Sumarno (Telecom Security Research) |
| **Status** | Draft untuk approval |

---

## 1. Ringkasan Eksekutif

Project ini membangun **FALCON** — *FPGA-Accelerated Live Core Observation Node* — sebuah **mesin analisis lalu lintas seluler berbasis FPGA** yang mampu membongkar dan menganalisa paket **GTP-U** (protokol User Plane jaringan seluler) secara *real-time* di tingkat hardware, lalu menyajikan statistiknya melalui dashboard web.

Inti nilai: **offloading** — memindahkan beban parsing paket berkecepatan tinggi dari CPU host (yang lambat dan mudah jenuh) ke chip **FPGA Genesys Virtex-5** yang memproses paket secara paralel dan deterministik. Hasilnya, host bebas menjalankan visualisasi & logika kontrol tanpa terbebani throughput User Plane.

Sistem ditargetkan sebagai **platform riset keamanan & observabilitas telco** — memetakan siapa (IMSI), sesi apa (TEID), dan protokol apa yang mengalir di jaringan, dengan latensi rendah dan beban feedback minimal (~25 KB/s).

> **Mengapa ini penting:** kemampuan inspeksi GTP-U di hardware adalah fondasi untuk monitoring jaringan, deteksi anomali, dan riset keamanan 2G→5G — kapabilitas yang umumnya hanya dimiliki vendor telco kelas atas. Project ini memvalidasi kapabilitas tersebut pada perangkat riset terjangkau.

---

## 2. Latar Belakang & Pernyataan Masalah

### 2.1 Konteks
Lalu lintas data seluler (browsing, streaming, IoT) dibungkus protokol **GTP-U** di jaringan operator. Untuk memonitor atau meriset jaringan, paket ini harus dibongkar (*parsed*) guna mengekstrak metadata: identitas sesi (TEID), pengguna (IMSI), jenis pesan, dan komposisi protokol.

### 2.2 Masalah
| # | Masalah | Dampak |
|---|---|---|
| M1 | Parsing GTP-U dengan CPU **tidak skalabel** — pada throughput tinggi CPU jenuh | Paket drop, statistik tidak akurat, host tidak responsif |
| M2 | Solusi DPI komersial **mahal & tertutup** (appliance vendor) | Tidak terjangkau untuk riset / skala kecil |
| M3 | Tidak ada **visibilitas real-time** terhadap sesi & protokol pada perangkat riset | Sulit riset keamanan / debugging jaringan |
| M4 | Kebutuhan **latensi rendah** (kelas URLLC 5G) tak terpenuhi software stack biasa | Tidak relevan untuk use-case 5G SA |

### 2.3 Peluang
FPGA memungkinkan parsing **paralel, deterministik, latensi <10 µs** dengan biaya hardware riset yang wajar (board Virtex-5 + host laptop), membuka kapabilitas DPI telco di luar ekosistem vendor besar.

---

## 3. Tujuan & Sasaran Terukur

| Kode | Tujuan Bisnis | Sasaran Terukur (Success Metric) |
|---|---|---|
| T1 | Offload parsing GTP-U ke hardware | CPU host < 20% saat trafik puncak; FPGA tangani 100% parsing |
| T2 | Capai latensi rendah | Hardware latency **< 10 µs** (mode Zero Copy) |
| T3 | Visibilitas real-time | Dashboard tampilkan IMSI aktif, per-TEID, event, protokol — refresh ≤ 1 dtk |
| T4 | Beban feedback minimal | Telemetry FPGA→Host **≤ 25 KB/s** pada 100 sesi aktif |
| T5 | Skalabilitas lintas generasi | Arsitektur sanggup 2G/GPRS → 3G/4G/5G (link util ~5% di 1 Gbps untuk 2G) |
| T6 | Biaya terjangkau | Gunakan board riset Virtex-5 + host existing (ThinkPad X230), tanpa appliance komersial |

---

## 4. Stakeholder

| Peran | Pihak | Kepentingan |
|---|---|---|
| **Sponsor / Product Owner** | Ndoro (Arah Karya Sinergi) | Pemilik visi produk, pendanaan, prioritas |
| **Domain Expert / Researcher** | NOZ — Tri Sumarno | Spesifikasi telco, validasi protokol 3GPP, use-case keamanan |
| **System Engineering** | Arah Karya Sinergi (AKS) | Arsitektur, gateware FPGA, host networking, backend, dashboard |
| **End User** | Tim riset / analis jaringan | Konsumen dashboard & data telemetri |

---

## 5. Ruang Lingkup (Scope)

### 5.1 In-Scope
- Ingest paket GTP-U dari host ke FPGA (3 metode, bertahap).
- Pipeline parsing GTP-U di FPGA (MAC → IP → UDP filter → GTP parser → DPI modules).
- Ekstraksi metadata: TEID, IMSI, Message Type, Flags, Length.
- Modul analitik FPGA: TEID Lookup, Flow Counter, Session State Machine, Pattern Match.
- Telemetry export FPGA→Host (4 tipe message) via UDP.
- Backend host: UDP listener → parser → JSON → WebSocket/REST.
- Dashboard web real-time (HTML).

### 5.2 Out-of-Scope (Fase ini)
- Modifikasi / injeksi paket (sistem bersifat **observasi pasif**).
- Dekripsi payload terenkripsi (hanya metadata GTP-U).
- Deployment produksi skala operator (project = riset / PoC).
- Integrasi 5G Control Plane penuh (fokus User Plane).

---

## 6. Kebutuhan Fungsional (Functional Requirements)

| ID | Kebutuhan | Prioritas |
|---|---|---|
| FR-1 | Sistem menerima paket GTP-U dari host via **UDP dst-port 9000** (ingest) | Must |
| FR-2 | FPGA memfilter paket berdasarkan dst-port 9000 di hardware komparator | Must |
| FR-3 | FPGA mem-parse header GTP v1: Flags, Message Type, Length, TEID | Must |
| FR-4 | FPGA melakukan TEID Lookup & menghitung flow per sesi | Must |
| FR-5 | FPGA memelihara Session State Machine (deteksi Create/aktif sesi) | Should |
| FR-6 | FPGA menjalankan Pattern Match untuk klasifikasi protokol (DPI) | Should |
| FR-7 | FPGA meng-export telemetry ke host via **UDP dst-port 50000** | Must |
| FR-8 | Telemetry mendukung 4 tipe: 0x01 Global, 0x02 Per-TEID, 0x03 Event, 0x04 Protocol Dist | Must |
| FR-9 | Host backend mem-parse telemetry → JSON → WebSocket/REST | Must |
| FR-10 | Dashboard menampilkan IMSI aktif, per-TEID, event real-time, distribusi protokol | Must |
| FR-11 | Sistem mendukung 3 mode ingest (TAP/TUN, Re-encapsulate, Zero Copy) bertahap | Should |

---

## 7. Kebutuhan Non-Fungsional (Non-Functional Requirements)

| ID | Kategori | Kebutuhan |
|---|---|---|
| NFR-1 | Performa | Hardware latency < 10 µs (mode Zero Copy) |
| NFR-2 | Throughput | Tangani ≥ 40–50 Mbps (skenario 2G/GPRS); headroom ke 3G/4G/5G |
| NFR-3 | Efisiensi | Telemetry feedback ≤ 25 KB/s pada 100 sesi |
| NFR-4 | Determinisme | Parsing paralel, jitter rendah (keunggulan FPGA vs CPU) |
| NFR-5 | Observability | tcpdump-friendly: arah trafik terpisah port (9000 in / 50000 out) |
| NFR-6 | Keterjangkauan | Hardware riset existing, tanpa appliance komersial |
| NFR-7 | Keamanan | Observasi pasif; tidak memodifikasi trafik produksi |

---

## 8. Arsitektur High-Level

```
[Sinyal Seluler] → USRP (radio) → Host (PHY decode → RAW GTP-U)
                                       │
                                       │  UDP dst-port 9000  (INGEST)
                                       ▼
                              FPGA Virtex-5 (192.168.1.20)
                              ┌────────────────────────────┐
                              │ Ethernet MAC (XC5V TEMAC)   │
                              │ IPv4 Parser                 │
                              │ UDP Filter (port 9000?)     │
                              │ GTP Parser (TEID/Flags/Len) │
                              │ TEID Lookup · Flow Counter  │
                              │ Session SM · Pattern Match  │
                              └──────────────┬─────────────┘
                                       │  UDP dst-port 50000 (TELEMETRY)
                                       ▼
                              Host (192.168.1.10)
                              UDP listener → parser → JSON
                              → WebSocket/REST → Dashboard Web
```

### 8.1 Keputusan Arsitektur Kunci (Resolved oleh AKS)
> **Pemisahan port dua arah** untuk menghindari ambiguitas:
> - **Ingest (Host→FPGA): UDP dst-port `9000`** — terkunci di komparator hardware FPGA.
> - **Telemetry (FPGA→Host): UDP dst-port `50000`** — host listen di 50000.
>
> Keputusan ini menyelesaikan inkonsistensi pada dokumen sumber (yang menyebut 9000 dan 50000 untuk telemetry). Dipilih 50000 karena: contoh paket sumber sudah memakai 50000 sebagai port host-side, arsitektur logis high-level eksplisit menyebut telemetry=50000, dan pemisahan port memudahkan debugging serta aturan firewall.

---

## 9. Pendekatan Bertahap — Strategi Ingest

Tiga metode ingest dipilih sebagai **tahapan kematangan**, bukan alternatif sekali pilih:

| Tahap | Metode | Tujuan Bisnis | Trade-off |
|---|---|---|---|
| **Fase 1** | TAP/TUN Mirror (iptables TEE) | Buktikan konsep cepat & murah | Lambat (lewat kernel), cukup untuk PoC |
| **Fase 2** | Host Re-encapsulate (DPDK/PF_RING) | Operasi kinerja tinggi yang andal | Host kerja sedikit (re-encap), tapi rapi |
| **Fase 3** | Zero Copy (AF_XDP/DPDK ZC) | Latensi ekstrem kelas 5G URLLC | Setup paling kompleks |

---

## 10. Risiko & Mitigasi

| ID | Risiko | Dampak | Mitigasi |
|---|---|---|---|
| R1 | Resource FPGA Virtex-5 (chip lama) terbatas untuk semua modul DPI | Sedang | Prioritaskan modul inti (FR-1..4) dulu; modul DPI lanjut (FR-5..6) sebagai Should |
| R2 | Kompleksitas Zero Copy (Fase 3) | Sedang | Jadikan opsional; nilai bisnis sudah tercapai di Fase 2 |
| R3 | Inkonsistensi spec sumber (port, field) | Rendah | Sudah di-resolve internal (lihat §8.1); dokumentasikan keputusan |
| R4 | Akurasi parsing lintas generasi (2G→5G) | Sedang | Validasi bertahap per generasi; mulai 2G/GPRS yang sudah teruji |
| R5 | Ketergantungan hardware tunggal (1 board, 1 host) | Rendah | PoC scope; skalabilitas multi-node = fase lanjut |

---

## 11. Kriteria Sukses (Acceptance)

Project dinyatakan **berhasil (Fase 1–2)** bila:

- [ ] FPGA menerima & mem-parse GTP-U dari host (port 9000) tanpa drop pada beban 2G/GPRS (~40 Mbps).
- [ ] Metadata TEID, Message Type, Length, Flags ter-ekstrak benar (validasi vs paket uji).
- [ ] Telemetry 4 tipe message terkirim ke host (port 50000) & ter-parse jadi JSON.
- [ ] Dashboard menampilkan IMSI aktif & per-TEID real-time (refresh ≤ 1 dtk).
- [ ] CPU host < 20% saat trafik puncak (bukti offloading berhasil).
- [ ] Beban telemetry ≤ 25 KB/s pada 100 sesi.

**Fase 3 (stretch):** latensi terukur < 10 µs mode Zero Copy.

---

## 12. Roadmap Indikatif

| Milestone | Output | Fase Ingest |
|---|---|---|
| **MS-1 · PoC** | Mirror trafik ke FPGA, parsing GTP dasar tampil di log | TAP/TUN |
| **MS-2 · Pipeline Inti** | Full pipeline FPGA (MAC→GTP→TEID/Flow) + telemetry 0x01/0x02 | Re-encapsulate |
| **MS-3 · Dashboard** | Backend + dashboard real-time, 4 tipe telemetry | Re-encapsulate |
| **MS-4 · DPI Lanjut** | Session State Machine + Pattern Match (event & protokol dist) | Re-encapsulate |
| **MS-5 · Low Latency** | Mode Zero Copy, ukur latensi <10 µs | Zero Copy |

---

## 13. Open Questions / Keputusan Lanjut

| # | Pertanyaan | Status |
|---|---|---|
| Q1 | Port telemetry FPGA→Host: 9000 atau 50000? | ✅ **RESOLVED** — 50000 (lihat §8.1) |
| Q2 | Generasi target prioritas pasca-2G (3G/4G/5G)? | ⏳ Perlu keputusan Ndoro/NOZ |
| Q3 | Format IMSI lookup (mapping TEID↔IMSI) — sumber data? | ⏳ Perlu klarifikasi domain (NOZ) |
| Q4 | Persistensi data telemetri (live-only vs simpan historis)? | ⏳ Perlu keputusan scope |

> Open question yang terjawab akan dipromosikan menjadi **Keputusan Final** di PRD (Product Requirements Document) tahap berikutnya.

---

*Dokumen ini adalah BRD (fokus: kenapa & apa). Detail teknis implementasi — field byte, API contract, behavior per-modul, acceptance criteria granular — akan dijabarkan pada **PRD** terpisah.*

**Disiapkan oleh Arah Karya Sinergi (AKS) — kolaborasi NOZ.**
