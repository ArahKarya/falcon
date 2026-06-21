# Genesys Ethernet PHY Pinout (Marvell 88E1111, GMII)

Sumber: Genesys FPGA Board Reference Manual (Digilent), hal. 12.
PHY: Marvell Alaska M88E1111, RJ45 Halo HFJ11-1G01E.
Mode: MII/GMII 10/100/1000, copper interface, MDIO addr = 00111 (0b00111).
Clock GMII: 25MHz dari IDT5V9885 (eksternal).
Default config strapping: CONFIG = 0001101 (lihat manual).

## RX (PHY -> FPGA)
| Sinyal   | Pin  |
|----------|------|
| RX_CLK   | L19  |
| RX_DV    | N8   |
| RX_ER    | (tidak tercantum eksplisit di diagram manual — TODO verify, bisa tie-off awal) |
| RXD0     | N7   |
| RXD1     | R6   |
| RXD2     | P6   |
| RXD3     | P5   |
| RXD4     | M7   |
| RXD5     | M6   |
| RXD6     | M5   |
| RXD7     | L6   |

## TX (FPGA -> PHY)
| Sinyal   | Pin  |
|----------|------|
| GTX_CLK  | J20  |  (gigabit TX clock, FPGA drive)
| TX_CLK   | J16  |  (10/100 TX clock, PHY drive)
| TX_EN    | T10  |
| TX_ER    | R8   |
| TXD0     | J5   |
| TXD1     | G5   |
| TXD2     | F5   |
| TXD3     | R7   |
| TXD4     | T8   |
| TXD5     | R11  |
| TXD6     | T11  |
| TXD7     | U7   |

## MGMT / kontrol
| Sinyal   | Pin  |
|----------|------|
| MDIO     | U10  |
| MDC      | N5   |
| INT#     | T6   |
| RESET#   | L4   |
| COL      | K6   |
| CRS      | L5   |

## Clock & reset sistem (sudah diverifikasi sesi lalu)
| Sinyal   | Pin  | Catatan |
|----------|------|---------|
| clk 100MHz | AG18 | LVCMOS33, on-board IC13 osc |
| rst      | E7   | LVCMOS25, RESET pushbutton active-high |

## Catatan IOSTANDARD
- Bank Ethernet PHY I/O = 2.5V (lihat manual hal. power rails: "2.5V FPGA Aux, VHDC, Ethernet PHY I/O").
- Gunakan IOSTANDARD = LVCMOS25 untuk pin Ethernet (verify per-bank).

## Catatan port Spartan-6 (ATLYS) -> Virtex-5 (Genesys)
- ATLYS example pakai DCM_SP (Spartan-6) -> Virtex-5 TIDAK punya DCM_SP.
  Ganti ke DCM_BASE atau PLL_BASE (Virtex-5 clock primitives).
- ATLYS GMII pin -> ganti SEMUA ke pin Genesys di atas.
- Target chip: xc5vlx50t-1-ff1136.
- IP default rencana: 192.168.0.20 (samakan subnet host NOZ 192.168.0.104/24).
- Fase 0: ARP responder + UDP echo (buktiin board bisa di-ping).

## TODO verify (hardware/manual)
1. RX_ER pin — tidak tercantum, cek skematik board atau tie-off.
2. CLK 25MHz GMII — apakah ke FPGA pin tertentu atau langsung ke PHY? (IDT5V9885)
3. IOSTANDARD exact per bank Ethernet.
