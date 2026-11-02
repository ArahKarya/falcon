// LED status Genesys LD0..LD7 - semua dari sinyal nyata.
//   LD0 heartbeat 1 Hz | LD1 paket GTP-U masuk | LD2 telemetri keluar | LD3 frame Ethernet masuk
//   LD4..LD7 bar beban GTP-U jendela 1 dtk: >=1, >=100, >=1.000, >=10.000 paket/dtk
`timescale 1ns / 1ps
module led_status #(
    parameter LED_SEC     = 125_000_000,
    parameter LED_STRETCH = 12_500_000
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       gtpu_strobe,   // 1 clk per paket GTP-U
    input  wire       tx_strobe,     // 1 clk per datagram telemetri dikirim
    input  wire       phy_rx_dv,     // GMII RX data valid (async terhadap clk)
    output wire [7:0] led
);
    reg [27:0] hb_cnt = 0;
    reg        hb_led = 0;
    always @(posedge clk) begin
        if (rst) begin hb_cnt <= 0; hb_led <= 0; end
        else if (hb_cnt == (LED_SEC/2)-1) begin hb_cnt <= 0; hb_led <= ~hb_led; end
        else hb_cnt <= hb_cnt + 1;
    end

    reg rxdv_s1 = 0, rxdv_s2 = 0, rxdv_s3 = 0;
    always @(posedge clk) begin rxdv_s1 <= phy_rx_dv; rxdv_s2 <= rxdv_s1; rxdv_s3 <= rxdv_s2; end
    wire eth_strobe = rxdv_s2 & ~rxdv_s3;

    reg [23:0] st_gtpu = 0, st_tx = 0, st_eth = 0;
    always @(posedge clk) begin
        if (rst) begin st_gtpu <= 0; st_tx <= 0; st_eth <= 0; end
        else begin
            if (gtpu_strobe)    st_gtpu <= LED_STRETCH; else if (st_gtpu != 0) st_gtpu <= st_gtpu - 1;
            if (tx_strobe)      st_tx   <= LED_STRETCH; else if (st_tx   != 0) st_tx   <= st_tx   - 1;
            if (eth_strobe)     st_eth  <= LED_STRETCH; else if (st_eth  != 0) st_eth  <= st_eth  - 1;
        end
    end

    reg [27:0] win_cnt  = 0;
    reg [15:0] pkt_cnt  = 0;
    reg [3:0]  load_bar = 0;
    always @(posedge clk) begin
        if (rst) begin win_cnt <= 0; pkt_cnt <= 0; load_bar <= 0; end
        else begin
            if (gtpu_strobe && pkt_cnt != 16'hFFFF) pkt_cnt <= pkt_cnt + 1;
            if (win_cnt == LED_SEC-1) begin
                win_cnt  <= 0;
                load_bar <= { (pkt_cnt >= 16'd10000), (pkt_cnt >= 16'd1000),
                              (pkt_cnt >= 16'd100),   (pkt_cnt >= 16'd1) };
                pkt_cnt  <= gtpu_strobe ? 16'd1 : 16'd0;
            end else win_cnt <= win_cnt + 1;
        end
    end

    assign led = { load_bar[3], load_bar[2], load_bar[1], load_bar[0],
                   (st_eth != 0), (st_tx != 0), (st_gtpu != 0), hb_led };
endmodule
