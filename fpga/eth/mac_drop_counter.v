/*
 * mac_drop_counter.v — hitung drop/frame di jalur masuk MAC (domain logic_clk).
 *
 * Masukan = pulsa 1-siklus dari eth_mac_1g_fifo (sudah disinkronkan ke logic_clk di dalam FIFO):
 *   ev_overflow   : frame dibuang karena FIFO RX penuh  (DROP NYATA: kapasitas)
 *   ev_bad_frame  : frame dibuang karena tidak valid     (DROP NYATA: kualitas)
 *   ev_bad_fcs    : FCS salah (diamati MAC; sebagian ikut tercatat sebagai bad_frame -> TIDAK dijumlah dobel)
 *   ev_good_frame : frame sah diteruskan ke logika
 *
 * Keluaran 32-bit tak bertanda yang menaik (kumulatif sejak reset), kecuali rate/jendela dihitung backend
 * dari selisih dua datagram GLOBAL (kontrak sama dengan drop_count yang sudah ada).
 *
 *   drop_total = overflow + bad_frame        (saturasi di 0xFFFFFFFF, tidak membungkus)
 *   frames_ok  = good_frame                  (saturasi)
 *
 * Catatan desain: pulsa bisa jatuh pada siklus yang sama -> jumlah ditambah 0/1/2, bukan "OR".
 */
`resetall
`timescale 1ns / 1ps
`default_nettype none

module mac_drop_counter (
    input  wire        clk,
    input  wire        rst,
    input  wire        ev_overflow,
    input  wire        ev_bad_frame,
    input  wire        ev_good_frame,
    output wire [31:0] drop_total,
    output wire [31:0] overflow_total,
    output wire [31:0] bad_total,
    output wire [31:0] frames_ok
);

reg [31:0] drop_r  = 32'd0;
reg [31:0] ovf_r   = 32'd0;
reg [31:0] bad_r   = 32'd0;
reg [31:0] ok_r    = 32'd0;

wire [1:0] add_drop = {1'b0, ev_overflow} + {1'b0, ev_bad_frame};

always @(posedge clk) begin
    if (rst) begin
        drop_r <= 32'd0;
        ovf_r  <= 32'd0;
        bad_r  <= 32'd0;
        ok_r   <= 32'd0;
    end else begin
        if (add_drop != 2'd0) begin
            // saturasi: jangan membungkus ke 0 (akan terbaca "tak ada drop")
            if (drop_r > 32'hFFFF_FFFD) drop_r <= 32'hFFFF_FFFF;
            else                        drop_r <= drop_r + {30'd0, add_drop};
        end
        if (ev_overflow  && ovf_r != 32'hFFFF_FFFF) ovf_r <= ovf_r + 32'd1;
        if (ev_bad_frame && bad_r != 32'hFFFF_FFFF) bad_r <= bad_r + 32'd1;
        if (ev_good_frame && ok_r != 32'hFFFF_FFFF) ok_r  <= ok_r  + 32'd1;
    end
end

assign drop_total     = drop_r;
assign overflow_total = ovf_r;
assign bad_total      = bad_r;
assign frames_ok      = ok_r;

endmodule

`resetall
