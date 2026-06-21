/*
 * genesys_fpga.v — FALCON Ethernet Fase 0 (ARP + UDP echo)
 *
 * Port dari verilog-ethernet ATLYS example (Alex Forencich, MIT) ke board
 * Digilent Genesys (Virtex-5 XC5VLX50T-1-FF1136, PHY Marvell 88E1111 GMII).
 *
 * Perubahan vs ATLYS:
 *   - Clock: DCM_SP (Spartan-6) -> PLL_BASE (Virtex-5) untuk 100MHz->125MHz.
 *   - Buang UART + tombol (tak perlu Fase 0); LED untuk indikator status.
 *   - Pin GMII -> pin Genesys (lihat genesys_eth.ucf).
 *
 * Fase 0 target: board respon ARP + echo UDP, bisa di-ping di 192.168.0.20.
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module genesys_fpga (
    input  wire       clk,          // 100 MHz on-board osc (AG18)
    input  wire       reset_n,      // RESET pushbutton (active-low wiring di UCF)

    output wire [7:0] led,          // indikator status

    /* Ethernet: GMII ke Marvell 88E1111 */
    input  wire       phy_rx_clk,
    input  wire [7:0] phy_rxd,
    input  wire       phy_rx_dv,
    output wire       phy_gtx_clk,
    output wire [7:0] phy_txd,
    output wire       phy_tx_en,
    output wire       phy_tx_er,
    output wire       phy_reset_n
);

// ---------------------------------------------------------------------------
// Clock: 100MHz -> 125MHz via PLL_BASE (Virtex-5)
// ---------------------------------------------------------------------------
wire clk_ibufg;
wire clk_pll_out;
wire clk_int;
wire rst_int;
wire pll_locked;
wire pll_fb;

IBUFG clk_ibufg_inst (
    .I(clk),
    .O(clk_ibufg)
);

// PLL_BASE: VCO = 100MHz * CLKFBOUT_MULT / DIVCLK_DIVIDE
//   Mult=10 -> VCO 1000MHz (dalam range Virtex-5 400-1000MHz)
//   CLKOUT0 DIVIDE=8 -> 125MHz (untuk GMII gtx_clk + sistem)
PLL_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKIN_PERIOD(10.0),            // 100 MHz
    .DIVCLK_DIVIDE(1),
    .CLKFBOUT_MULT(10),             // VCO = 1000 MHz
    .CLKFBOUT_PHASE(0.0),
    .CLKOUT0_DIVIDE(8),             // 125 MHz
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.0),
    .COMPENSATION("SYSTEM_SYNCHRONOUS"),
    .REF_JITTER(0.100)
)
pll_inst (
    .CLKIN(clk_ibufg),
    .CLKFBIN(pll_fb),
    .RST(~reset_n),
    .CLKFBOUT(pll_fb),
    .CLKOUT0(clk_pll_out),
    .CLKOUT1(),
    .CLKOUT2(),
    .CLKOUT3(),
    .CLKOUT4(),
    .CLKOUT5(),
    .LOCKED(pll_locked)
);

BUFG clk_bufg_inst (
    .I(clk_pll_out),
    .O(clk_int)
);

sync_reset #(
    .N(4)
)
sync_reset_inst (
    .clk(clk_int),
    .rst(~pll_locked),
    .sync_reset_out(rst_int)
);

// ---------------------------------------------------------------------------
// Core: ARP + UDP echo (IP 192.168.0.20)
// ---------------------------------------------------------------------------
fpga_core #(
    .TARGET("XILINX")
)
core_inst (
    .clk(clk_int),
    .rst(rst_int),

    .led(led),

    .phy_rx_clk(phy_rx_clk),
    .phy_rxd(phy_rxd),
    .phy_rx_dv(phy_rx_dv),
    .phy_rx_er(1'b0),
    .phy_gtx_clk(phy_gtx_clk),
    .phy_txd(phy_txd),
    .phy_tx_en(phy_tx_en),
    .phy_tx_er(phy_tx_er),
    .phy_reset_n(phy_reset_n)
);

endmodule

`resetall
