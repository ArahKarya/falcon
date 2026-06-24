/*

Copyright (c) 2014-2016 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`timescale 1ns / 1ps

/*
 * FPGA core logic
 */
module fpga_core #
(
    parameter TARGET = "XILINX"
)
(
    /*
     * Clock: 125MHz
     * Synchronous reset
     */
    input  wire       clk,
    input  wire       rst,

    /*
     * GPIO
     */
    output wire [7:0] led,

    /*
     * Ethernet: 1000BASE-T GMII
     */
    input  wire       phy_rx_clk,
    input  wire [7:0] phy_rxd,
    input  wire       phy_rx_dv,
    input  wire       phy_rx_er,
    output wire       phy_gtx_clk,
    output wire [7:0] phy_txd,
    output wire       phy_tx_en,
    output wire       phy_tx_er,
    output wire       phy_reset_n
);

// GMII between MAC and PHY IF
wire gmii_rx_clk;
wire gmii_rx_rst;
wire [7:0] gmii_rxd;
wire gmii_rx_dv;
wire gmii_rx_er;

wire gmii_tx_clk;
wire gmii_tx_rst;
wire [7:0] gmii_txd;
wire gmii_tx_en;
wire gmii_tx_er;

// AXI between MAC and Ethernet modules
wire [7:0] rx_axis_tdata;
wire rx_axis_tvalid;
wire rx_axis_tready;
wire rx_axis_tlast;
wire rx_axis_tuser;

wire [7:0] tx_axis_tdata;
wire tx_axis_tvalid;
wire tx_axis_tready;
wire tx_axis_tlast;
wire tx_axis_tuser;

// Ethernet frame between Ethernet modules and UDP stack
wire rx_eth_hdr_ready;
wire rx_eth_hdr_valid;
wire [47:0] rx_eth_dest_mac;
wire [47:0] rx_eth_src_mac;
wire [15:0] rx_eth_type;
wire [7:0] rx_eth_payload_tdata;
wire rx_eth_payload_tvalid;
wire rx_eth_payload_tready;
wire rx_eth_payload_tlast;
wire rx_eth_payload_tuser;

wire tx_eth_hdr_ready;
wire tx_eth_hdr_valid;
wire [47:0] tx_eth_dest_mac;
wire [47:0] tx_eth_src_mac;
wire [15:0] tx_eth_type;
wire [7:0] tx_eth_payload_tdata;
wire tx_eth_payload_tvalid;
wire tx_eth_payload_tready;
wire tx_eth_payload_tlast;
wire tx_eth_payload_tuser;

// IP frame connections
wire rx_ip_hdr_valid;
wire rx_ip_hdr_ready;
wire [47:0] rx_ip_eth_dest_mac;
wire [47:0] rx_ip_eth_src_mac;
wire [15:0] rx_ip_eth_type;
wire [3:0] rx_ip_version;
wire [3:0] rx_ip_ihl;
wire [5:0] rx_ip_dscp;
wire [1:0] rx_ip_ecn;
wire [15:0] rx_ip_length;
wire [15:0] rx_ip_identification;
wire [2:0] rx_ip_flags;
wire [12:0] rx_ip_fragment_offset;
wire [7:0] rx_ip_ttl;
wire [7:0] rx_ip_protocol;
wire [15:0] rx_ip_header_checksum;
wire [31:0] rx_ip_source_ip;
wire [31:0] rx_ip_dest_ip;
wire [7:0] rx_ip_payload_tdata;
wire rx_ip_payload_tvalid;
wire rx_ip_payload_tready;
wire rx_ip_payload_tlast;
wire rx_ip_payload_tuser;

wire tx_ip_hdr_valid;
wire tx_ip_hdr_ready;
wire [5:0] tx_ip_dscp;
wire [1:0] tx_ip_ecn;
wire [15:0] tx_ip_length;
wire [7:0] tx_ip_ttl;
wire [7:0] tx_ip_protocol;
wire [31:0] tx_ip_source_ip;
wire [31:0] tx_ip_dest_ip;
wire [7:0] tx_ip_payload_tdata;
wire tx_ip_payload_tvalid;
wire tx_ip_payload_tready;
wire tx_ip_payload_tlast;
wire tx_ip_payload_tuser;

// UDP frame connections
wire rx_udp_hdr_valid;
wire rx_udp_hdr_ready;
wire [47:0] rx_udp_eth_dest_mac;
wire [47:0] rx_udp_eth_src_mac;
wire [15:0] rx_udp_eth_type;
wire [3:0] rx_udp_ip_version;
wire [3:0] rx_udp_ip_ihl;
wire [5:0] rx_udp_ip_dscp;
wire [1:0] rx_udp_ip_ecn;
wire [15:0] rx_udp_ip_length;
wire [15:0] rx_udp_ip_identification;
wire [2:0] rx_udp_ip_flags;
wire [12:0] rx_udp_ip_fragment_offset;
wire [7:0] rx_udp_ip_ttl;
wire [7:0] rx_udp_ip_protocol;
wire [15:0] rx_udp_ip_header_checksum;
wire [31:0] rx_udp_ip_source_ip;
wire [31:0] rx_udp_ip_dest_ip;
wire [15:0] rx_udp_source_port;
wire [15:0] rx_udp_dest_port;
wire [15:0] rx_udp_length;
wire [15:0] rx_udp_checksum;
wire [7:0] rx_udp_payload_tdata;
wire rx_udp_payload_tvalid;
wire rx_udp_payload_tready;
wire rx_udp_payload_tlast;
wire rx_udp_payload_tuser;

wire tx_udp_hdr_valid;
wire tx_udp_hdr_ready;
wire [5:0] tx_udp_ip_dscp;
wire [1:0] tx_udp_ip_ecn;
wire [7:0] tx_udp_ip_ttl;
wire [31:0] tx_udp_ip_source_ip;
wire [31:0] tx_udp_ip_dest_ip;
wire [15:0] tx_udp_source_port;
wire [15:0] tx_udp_dest_port;
wire [15:0] tx_udp_length;
wire [15:0] tx_udp_checksum;
wire [7:0] tx_udp_payload_tdata;
wire tx_udp_payload_tvalid;
wire tx_udp_payload_tready;
wire tx_udp_payload_tlast;
wire tx_udp_payload_tuser;

wire [7:0] rx_fifo_udp_payload_tdata;
wire rx_fifo_udp_payload_tvalid;
wire rx_fifo_udp_payload_tready;
wire rx_fifo_udp_payload_tlast;
wire rx_fifo_udp_payload_tuser;

wire [7:0] tx_fifo_udp_payload_tdata;
wire tx_fifo_udp_payload_tvalid;
wire tx_fifo_udp_payload_tready;
wire tx_fifo_udp_payload_tlast;
wire tx_fifo_udp_payload_tuser;

// Configuration
wire [47:0] local_mac   = 48'h02_00_00_00_00_20;
wire [31:0] local_ip    = {8'd192, 8'd168, 8'd0,   8'd20};
wire [31:0] gateway_ip  = {8'd192, 8'd168, 8'd0,   8'd1};
wire [31:0] subnet_mask = {8'd255, 8'd255, 8'd255, 8'd0};

// IP ports not used
assign rx_ip_hdr_ready = 1;
assign rx_ip_payload_tready = 1;

assign tx_ip_hdr_valid = 0;
assign tx_ip_dscp = 0;
assign tx_ip_ecn = 0;
assign tx_ip_length = 0;
assign tx_ip_ttl = 0;
assign tx_ip_protocol = 0;
assign tx_ip_source_ip = 0;
assign tx_ip_dest_ip = 0;
assign tx_ip_payload_tdata = 0;
assign tx_ip_payload_tvalid = 0;
assign tx_ip_payload_tlast = 0;
assign tx_ip_payload_tuser = 0;

// ===========================================================================
// FALCON DPI MODE (Fase 1) — ganti echo Fase 0.
// RX: UDP payload port 2152 (GTP-U) -> falcon_dpi_wrap parser.
// TX: telemetry datagram -> UDP ke HOST:50000.
// ===========================================================================
localparam [31:0] HOST_IP   = {8'd192, 8'd168, 8'd0, 8'd101};  // laptop NOZ
localparam [15:0] TELE_PORT = 16'd50000;
localparam [15:0] GTPU_PORT = 16'd2152;

// hanya terima paket UDP dest port 2152 ke parser
wire dpi_match = (rx_udp_dest_port == GTPU_PORT);

// RX payload -> wrapper (gate dgn match). Non-match: drain (tready=1) biar tak stall.
wire        w_rx_tready;
wire [7:0]  w_tx_tdata;
wire        w_tx_tvalid;
wire        w_tx_tready;
wire        w_tx_tlast;
wire        w_tx_busy;
wire        w_tx_sof;   // FIX: per-datagram start-of-frame
wire [15:0] w_tx_len;   // FIX: len datagram aktif (per-type)

assign rx_udp_payload_tready = dpi_match ? w_rx_tready : 1'b1;

falcon_dpi_wrap u_dpi (
    .clk(clk), .rst(rst),
    .rx_tdata(rx_udp_payload_tdata),
    .rx_tvalid(rx_udp_payload_tvalid & dpi_match),
    .rx_tready(w_rx_tready),
    .rx_tlast(rx_udp_payload_tlast),
    .tx_tdata(w_tx_tdata),
    .tx_tvalid(w_tx_tvalid),
    .tx_tready(w_tx_tready),
    .tx_tlast(w_tx_tlast),
    .tx_busy(w_tx_busy),
    .tx_sof(w_tx_sof),
    .tx_len_o(w_tx_len),
    .dbg_teid(), .dbg_emit()
);

// ---- TX UDP header: kirim telemetry ke HOST:50000 ----
// header dikirim sekali per datagram, saat serializer mulai (tx_busy rising).
reg w_tx_busy_r = 0;
always @(posedge clk) w_tx_busy_r <= w_tx_busy;
// FIX Fase 1.5: tele_start dari SOF per-datagram (bukan busy-edge). Busy-edge
// MISS datagram back-to-back (busy stay HIGH antar TEID/EVENT) -> header UDP
// tak terkirim -> datagram di-drop UDP core. Itu sebab cuma GLOBAL@1Hz lolos.
wire tele_start = w_tx_sof;

reg tx_hdr_valid_r = 0;
always @(posedge clk) begin
    if (rst) tx_hdr_valid_r <= 0;
    else if (tele_start) tx_hdr_valid_r <= 1;
    else if (tx_udp_hdr_ready) tx_hdr_valid_r <= 0;
end

assign tx_udp_hdr_valid    = tx_hdr_valid_r;
assign rx_udp_hdr_ready    = 1'b1;                 // selalu siap konsumsi RX hdr
assign tx_udp_ip_dscp      = 0;
assign tx_udp_ip_ecn       = 0;
assign tx_udp_ip_ttl       = 64;
assign tx_udp_ip_source_ip = local_ip;
assign tx_udp_ip_dest_ip   = HOST_IP;
assign tx_udp_source_port  = TELE_PORT;
assign tx_udp_dest_port    = TELE_PORT;
// FIX Fase 1.5 TX: length per-datagram (GLOBAL=68,TEID=52,EVENT/PROTO=36).
// Bug lama: hardcoded 68 -> TEID/EVENT (len beda) mismatch -> UDP core stall/
// desync ~1s -> cuma GLOBAL@1Hz lolos. Sekarang dari serializer byte_cnt.
assign tx_udp_length       = 16'd8 + w_tx_len;     // UDP hdr 8 + payload aktual
assign tx_udp_checksum     = 0;

// FIX Fase 1.5 TX DESYNC: header-first sequencing per datagram.
// Bug: serializer pump payload byte-0 BARENGAN set hdr_valid -> header belum
// accepted core -> payload desync -> UDP core drop. Hanya GLOBAL@1Hz (TX idle,
// header sempat handshake) lolos. Bukti silikon: serializer mulai 1333 datagram,
// cuma 7 keluar. FIX: tahan payload sampai header di-accept core (hdr_done),
// baru stream byte. Serializer auto-hold byte-0 via tready=0 (AXIS-compliant).
reg hdr_done = 0;
always @(posedge clk) begin
    if (rst) hdr_done <= 1'b0;
    else if (tx_udp_hdr_valid && tx_udp_hdr_ready) hdr_done <= 1'b1;
    else if (tx_udp_payload_tvalid && tx_udp_payload_tready && tx_udp_payload_tlast) hdr_done <= 1'b0;
end

// payload = output serializer, di-gate hdr_done (header-first)
assign tx_udp_payload_tdata  = w_tx_tdata;
assign tx_udp_payload_tvalid = w_tx_tvalid & hdr_done;
assign w_tx_tready           = tx_udp_payload_tready & hdr_done;
assign tx_udp_payload_tlast  = w_tx_tlast;
assign tx_udp_payload_tuser  = 1'b0;

// Place first payload byte onto LEDs
reg valid_last = 0;
reg [7:0] led_reg = 0;

always @(posedge clk) begin
    if (rst) begin
        led_reg <= 0;
    end else begin
        valid_last <= tx_udp_payload_tvalid;
        if (tx_udp_payload_tvalid & ~valid_last) begin
            led_reg <= tx_udp_payload_tdata;
        end
    end
end

//assign led = sw;
assign led = led_reg;

// ---------------------------------------------------------------------------
// PHY reset pulse: hold phy_reset_n LOW >=10ms after clk stabil, baru release.
// 88E1111 butuh reset minimal 10ms + waktu config strap setelah power.
// clk = 125MHz -> 10ms = 1_250_000 cycle. Pakai 25ms (3_125_000) buat margin.
// HARDWARE-VERIFIED: tanpa ini link mati (LED nyala tapi Link detected:no).
// ---------------------------------------------------------------------------
localparam PHY_RST_CYC = 3_125_000;   // 25 ms @ 125MHz
reg [21:0] phy_rst_cnt = 0;
reg        phy_reset_n_reg = 1'b0;

always @(posedge clk) begin
    if (rst) begin
        phy_rst_cnt     <= 0;
        phy_reset_n_reg <= 1'b0;       // assert reset (active low) selama sistem reset
    end else if (phy_rst_cnt < PHY_RST_CYC) begin
        phy_rst_cnt     <= phy_rst_cnt + 1;
        phy_reset_n_reg <= 1'b0;       // tahan reset low
    end else begin
        phy_reset_n_reg <= 1'b1;       // release reset setelah 25ms
    end
end

assign phy_reset_n = phy_reset_n_reg;

// uart removed

gmii_phy_if #(
    .TARGET(TARGET),
    .IODDR_STYLE("IODDR"),
    .CLOCK_INPUT_STYLE("BUFG")
)
gmii_phy_if_inst (
    .clk(clk),
    .rst(rst),

    .mac_gmii_rx_clk(gmii_rx_clk),
    .mac_gmii_rx_rst(gmii_rx_rst),
    .mac_gmii_rxd(gmii_rxd),
    .mac_gmii_rx_dv(gmii_rx_dv),
    .mac_gmii_rx_er(gmii_rx_er),
    .mac_gmii_tx_clk(gmii_tx_clk),
    .mac_gmii_tx_rst(gmii_tx_rst),
    .mac_gmii_txd(gmii_txd),
    .mac_gmii_tx_en(gmii_tx_en),
    .mac_gmii_tx_er(gmii_tx_er),

    .phy_gmii_rx_clk(phy_rx_clk),
    .phy_gmii_rxd(phy_rxd),
    .phy_gmii_rx_dv(phy_rx_dv),
    .phy_gmii_rx_er(phy_rx_er),
    .phy_mii_tx_clk(1'b0),
    .phy_gmii_tx_clk(phy_gtx_clk),
    .phy_gmii_txd(phy_txd),
    .phy_gmii_tx_en(phy_tx_en),
    .phy_gmii_tx_er(phy_tx_er),
    .mii_select(1'b0)
);

eth_mac_1g_fifo #(
    .ENABLE_PADDING(1),
    .MIN_FRAME_LENGTH(64),
    .TX_FIFO_ADDR_WIDTH(12),
    .RX_FIFO_ADDR_WIDTH(12)
)
eth_mac_1g_fifo_inst (
    .rx_clk(gmii_rx_clk),
    .rx_rst(gmii_rx_rst),
    .tx_clk(gmii_tx_clk),
    .tx_rst(gmii_tx_rst),
    .logic_clk(clk),
    .logic_rst(rst),

    .tx_axis_tdata(tx_axis_tdata),
    .tx_axis_tvalid(tx_axis_tvalid),
    .tx_axis_tready(tx_axis_tready),
    .tx_axis_tlast(tx_axis_tlast),
    .tx_axis_tuser(tx_axis_tuser),

    .rx_axis_tdata(rx_axis_tdata),
    .rx_axis_tvalid(rx_axis_tvalid),
    .rx_axis_tready(rx_axis_tready),
    .rx_axis_tlast(rx_axis_tlast),
    .rx_axis_tuser(rx_axis_tuser),

    .gmii_rxd(gmii_rxd),
    .gmii_rx_dv(gmii_rx_dv),
    .gmii_rx_er(gmii_rx_er),
    .gmii_txd(gmii_txd),
    .gmii_tx_en(gmii_tx_en),
    .gmii_tx_er(gmii_tx_er),

    .rx_error_bad_frame(rx_error_bad_frame),
    .rx_error_bad_fcs(rx_error_bad_fcs),

    .ifg_delay(12)
);

eth_axis_rx
eth_axis_rx_inst (
    .clk(clk),
    .rst(rst),
    // AXI input
    .input_axis_tdata(rx_axis_tdata),
    .input_axis_tvalid(rx_axis_tvalid),
    .input_axis_tready(rx_axis_tready),
    .input_axis_tlast(rx_axis_tlast),
    .input_axis_tuser(rx_axis_tuser),
    // Ethernet frame output
    .output_eth_hdr_valid(rx_eth_hdr_valid),
    .output_eth_hdr_ready(rx_eth_hdr_ready),
    .output_eth_dest_mac(rx_eth_dest_mac),
    .output_eth_src_mac(rx_eth_src_mac),
    .output_eth_type(rx_eth_type),
    .output_eth_payload_tdata(rx_eth_payload_tdata),
    .output_eth_payload_tvalid(rx_eth_payload_tvalid),
    .output_eth_payload_tready(rx_eth_payload_tready),
    .output_eth_payload_tlast(rx_eth_payload_tlast),
    .output_eth_payload_tuser(rx_eth_payload_tuser),
    // Status signals
    .busy(),
    .error_header_early_termination()
);

eth_axis_tx
eth_axis_tx_inst (
    .clk(clk),
    .rst(rst),
    // Ethernet frame input
    .input_eth_hdr_valid(tx_eth_hdr_valid),
    .input_eth_hdr_ready(tx_eth_hdr_ready),
    .input_eth_dest_mac(tx_eth_dest_mac),
    .input_eth_src_mac(tx_eth_src_mac),
    .input_eth_type(tx_eth_type),
    .input_eth_payload_tdata(tx_eth_payload_tdata),
    .input_eth_payload_tvalid(tx_eth_payload_tvalid),
    .input_eth_payload_tready(tx_eth_payload_tready),
    .input_eth_payload_tlast(tx_eth_payload_tlast),
    .input_eth_payload_tuser(tx_eth_payload_tuser),
    // AXI output
    .output_axis_tdata(tx_axis_tdata),
    .output_axis_tvalid(tx_axis_tvalid),
    .output_axis_tready(tx_axis_tready),
    .output_axis_tlast(tx_axis_tlast),
    .output_axis_tuser(tx_axis_tuser),
    // Status signals
    .busy()
);

udp_complete #(
    .UDP_CHECKSUM_ENABLE(0)
)
udp_complete_inst (
    .clk(clk),
    .rst(rst),
    // Ethernet frame input
    .input_eth_hdr_valid(rx_eth_hdr_valid),
    .input_eth_hdr_ready(rx_eth_hdr_ready),
    .input_eth_dest_mac(rx_eth_dest_mac),
    .input_eth_src_mac(rx_eth_src_mac),
    .input_eth_type(rx_eth_type),
    .input_eth_payload_tdata(rx_eth_payload_tdata),
    .input_eth_payload_tvalid(rx_eth_payload_tvalid),
    .input_eth_payload_tready(rx_eth_payload_tready),
    .input_eth_payload_tlast(rx_eth_payload_tlast),
    .input_eth_payload_tuser(rx_eth_payload_tuser),
    // Ethernet frame output
    .output_eth_hdr_valid(tx_eth_hdr_valid),
    .output_eth_hdr_ready(tx_eth_hdr_ready),
    .output_eth_dest_mac(tx_eth_dest_mac),
    .output_eth_src_mac(tx_eth_src_mac),
    .output_eth_type(tx_eth_type),
    .output_eth_payload_tdata(tx_eth_payload_tdata),
    .output_eth_payload_tvalid(tx_eth_payload_tvalid),
    .output_eth_payload_tready(tx_eth_payload_tready),
    .output_eth_payload_tlast(tx_eth_payload_tlast),
    .output_eth_payload_tuser(tx_eth_payload_tuser),
    // IP frame input
    .input_ip_hdr_valid(tx_ip_hdr_valid),
    .input_ip_hdr_ready(tx_ip_hdr_ready),
    .input_ip_dscp(tx_ip_dscp),
    .input_ip_ecn(tx_ip_ecn),
    .input_ip_length(tx_ip_length),
    .input_ip_ttl(tx_ip_ttl),
    .input_ip_protocol(tx_ip_protocol),
    .input_ip_source_ip(tx_ip_source_ip),
    .input_ip_dest_ip(tx_ip_dest_ip),
    .input_ip_payload_tdata(tx_ip_payload_tdata),
    .input_ip_payload_tvalid(tx_ip_payload_tvalid),
    .input_ip_payload_tready(tx_ip_payload_tready),
    .input_ip_payload_tlast(tx_ip_payload_tlast),
    .input_ip_payload_tuser(tx_ip_payload_tuser),
    // IP frame output
    .output_ip_hdr_valid(rx_ip_hdr_valid),
    .output_ip_hdr_ready(rx_ip_hdr_ready),
    .output_ip_eth_dest_mac(rx_ip_eth_dest_mac),
    .output_ip_eth_src_mac(rx_ip_eth_src_mac),
    .output_ip_eth_type(rx_ip_eth_type),
    .output_ip_version(rx_ip_version),
    .output_ip_ihl(rx_ip_ihl),
    .output_ip_dscp(rx_ip_dscp),
    .output_ip_ecn(rx_ip_ecn),
    .output_ip_length(rx_ip_length),
    .output_ip_identification(rx_ip_identification),
    .output_ip_flags(rx_ip_flags),
    .output_ip_fragment_offset(rx_ip_fragment_offset),
    .output_ip_ttl(rx_ip_ttl),
    .output_ip_protocol(rx_ip_protocol),
    .output_ip_header_checksum(rx_ip_header_checksum),
    .output_ip_source_ip(rx_ip_source_ip),
    .output_ip_dest_ip(rx_ip_dest_ip),
    .output_ip_payload_tdata(rx_ip_payload_tdata),
    .output_ip_payload_tvalid(rx_ip_payload_tvalid),
    .output_ip_payload_tready(rx_ip_payload_tready),
    .output_ip_payload_tlast(rx_ip_payload_tlast),
    .output_ip_payload_tuser(rx_ip_payload_tuser),
    // UDP frame input
    .input_udp_hdr_valid(tx_udp_hdr_valid),
    .input_udp_hdr_ready(tx_udp_hdr_ready),
    .input_udp_ip_dscp(tx_udp_ip_dscp),
    .input_udp_ip_ecn(tx_udp_ip_ecn),
    .input_udp_ip_ttl(tx_udp_ip_ttl),
    .input_udp_ip_source_ip(tx_udp_ip_source_ip),
    .input_udp_ip_dest_ip(tx_udp_ip_dest_ip),
    .input_udp_source_port(tx_udp_source_port),
    .input_udp_dest_port(tx_udp_dest_port),
    .input_udp_length(tx_udp_length),
    .input_udp_checksum(tx_udp_checksum),
    .input_udp_payload_tdata(tx_udp_payload_tdata),
    .input_udp_payload_tvalid(tx_udp_payload_tvalid),
    .input_udp_payload_tready(tx_udp_payload_tready),
    .input_udp_payload_tlast(tx_udp_payload_tlast),
    .input_udp_payload_tuser(tx_udp_payload_tuser),
    // UDP frame output
    .output_udp_hdr_valid(rx_udp_hdr_valid),
    .output_udp_hdr_ready(rx_udp_hdr_ready),
    .output_udp_eth_dest_mac(rx_udp_eth_dest_mac),
    .output_udp_eth_src_mac(rx_udp_eth_src_mac),
    .output_udp_eth_type(rx_udp_eth_type),
    .output_udp_ip_version(rx_udp_ip_version),
    .output_udp_ip_ihl(rx_udp_ip_ihl),
    .output_udp_ip_dscp(rx_udp_ip_dscp),
    .output_udp_ip_ecn(rx_udp_ip_ecn),
    .output_udp_ip_length(rx_udp_ip_length),
    .output_udp_ip_identification(rx_udp_ip_identification),
    .output_udp_ip_flags(rx_udp_ip_flags),
    .output_udp_ip_fragment_offset(rx_udp_ip_fragment_offset),
    .output_udp_ip_ttl(rx_udp_ip_ttl),
    .output_udp_ip_protocol(rx_udp_ip_protocol),
    .output_udp_ip_header_checksum(rx_udp_ip_header_checksum),
    .output_udp_ip_source_ip(rx_udp_ip_source_ip),
    .output_udp_ip_dest_ip(rx_udp_ip_dest_ip),
    .output_udp_source_port(rx_udp_source_port),
    .output_udp_dest_port(rx_udp_dest_port),
    .output_udp_length(rx_udp_length),
    .output_udp_checksum(rx_udp_checksum),
    .output_udp_payload_tdata(rx_udp_payload_tdata),
    .output_udp_payload_tvalid(rx_udp_payload_tvalid),
    .output_udp_payload_tready(rx_udp_payload_tready),
    .output_udp_payload_tlast(rx_udp_payload_tlast),
    .output_udp_payload_tuser(rx_udp_payload_tuser),
    // Status signals
    .ip_rx_busy(),
    .ip_tx_busy(),
    .udp_rx_busy(),
    .udp_tx_busy(),
    .ip_rx_error_header_early_termination(),
    .ip_rx_error_payload_early_termination(),
    .ip_rx_error_invalid_header(),
    .ip_rx_error_invalid_checksum(),
    .ip_tx_error_payload_early_termination(),
    .ip_tx_error_arp_failed(),
    .udp_rx_error_header_early_termination(),
    .udp_rx_error_payload_early_termination(),
    .udp_tx_error_payload_early_termination(),
    // Configuration
    .local_mac(local_mac),
    .local_ip(local_ip),
    .gateway_ip(gateway_ip),
    .subnet_mask(subnet_mask),
    .clear_arp_cache(0)
);

// echo udp_payload_fifo dihapus (DPI mode, Fase 1)

endmodule
