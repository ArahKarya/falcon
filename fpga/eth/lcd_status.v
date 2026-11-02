// lcd_status.v - Genesys 16x2 LCD (ST7066U / HD44780) status FALCON. WRITE-ONLY.
//
// Keselamatan listrik: LCD berdaya 5V, bank FPGA 2.5V/3.3V. Maka:
//   - R/W DIIKAT 0 (tak pernah baca busy flag; tunggu pakai delay tetap sesuai manual)
//   - DB[7:0], RS, E hanya OUTPUT. Tak ada jalur dari LCD ke input FPGA.
//
// Tampilan (16 kolom x 2 baris):
//   baris 1 (tetap):  "FALCON UL 00120 "     UL = paket GTP-U per detik (jendela 1 dtk)
//   baris 2 (3 dtk bergantian, 4 halaman):
//     0:  "bps  0.07 Mbps  "  (laju byte, 2 desimal)
//     1:  "Tot 0000036000 B"  (total byte payload GTP-U, 10 digit)
//     2:  "Pkt 000000003600"  (total paket GTP-U, 12 digit)
//     3:  "Up   00:12:34    "  (uptime)
//
// Semua perhitungan angka -> digit desimal memakai double-dabble kecil di FSM
// agar sintesis XST ringan (tak ada pembagi).
`timescale 1ns / 1ps
module lcd_status #(
    parameter CLK_HZ     = 125_000_000,
    parameter PAGE_SEC   = 3,
    parameter PWR_DELAY  = 2_500_000,     // 20 ms @125MHz (manual: >=20 ms setelah power)
    parameter T_37US     = 5_000,         // 40 us
    parameter T_1P52MS   = 200_000        // 1,6 ms
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       pkt_strobe,     // 1 clk per paket GTP-U (akhir paket)
    input  wire       byte_strobe,    // 1 clk per byte payload GTP-U
    output reg        lcd_rs = 0,
    output wire       lcd_rw,
    output reg        lcd_e  = 0,
    output reg  [7:0] lcd_db = 0
);
    assign lcd_rw = 1'b0;             // write-only, SELALU

    // ---------------------------------------------------------------
    // Pengukuran
    // ---------------------------------------------------------------
    reg [31:0] sec_cnt   = 0;
    reg        sec_tick  = 0;
    always @(posedge clk) begin
        if (rst) begin sec_cnt <= 0; sec_tick <= 0; end
        else if (sec_cnt == CLK_HZ-1) begin sec_cnt <= 0; sec_tick <= 1; end
        else begin sec_cnt <= sec_cnt + 1; sec_tick <= 0; end
    end

    reg [47:0] tot_bytes = 0;         // kumulatif
    reg [47:0] tot_pkts  = 0;
    reg [31:0] win_bytes = 0;
    reg [31:0] win_pkts  = 0;
    reg [31:0] last_pps  = 0;
    reg [31:0] last_bps  = 0;         // byte/dtk
    reg [31:0] uptime_s  = 0;

    always @(posedge clk) begin
        if (rst) begin
            tot_bytes <= 0; tot_pkts <= 0; win_bytes <= 0; win_pkts <= 0;
            last_pps <= 0; last_bps <= 0; uptime_s <= 0;
        end else begin
            if (byte_strobe) begin tot_bytes <= tot_bytes + 1; win_bytes <= win_bytes + 1; end
            if (pkt_strobe)  begin tot_pkts  <= tot_pkts  + 1; win_pkts  <= win_pkts  + 1; end
            if (sec_tick) begin
                last_pps  <= win_pkts;
                last_bps  <= win_bytes;
                win_bytes <= byte_strobe ? 32'd1 : 32'd0;
                win_pkts  <= pkt_strobe  ? 32'd1 : 32'd0;
                uptime_s  <= uptime_s + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Halaman: ganti tiap PAGE_SEC detik
    // ---------------------------------------------------------------
    reg [1:0]  page    = 0;
    reg [7:0]  page_t  = 0;
    always @(posedge clk) begin
        if (rst) begin page <= 0; page_t <= 0; end
        else if (sec_tick) begin
            if (page_t == PAGE_SEC-1) begin page_t <= 0; page <= page + 1; end
            else page_t <= page_t + 1;
        end
    end

    // ---------------------------------------------------------------
    // Snapshot nilai untuk satu siklus refresh (agar digit konsisten)
    // ---------------------------------------------------------------
    reg [47:0] s_tot_b, s_tot_p;
    reg [31:0] s_pps, s_bps, s_up;
    reg [1:0]  s_page;

    reg [47:0] dd_src;
    reg [31:0] mbps100;
    // double-dabble: 48 bit -> 15 digit BCD (60 bit). Berjalan 48 clk.
    reg [47:0] dd_in;
    reg [59:0] dd_bcd;
    reg [6:0]  dd_n;
    reg        dd_busy = 0;
    reg        dd_start = 0;
    reg        dd_done = 0;
    wire [59:0] dd_adj = {
        (dd_bcd[59:56] >= 5) ? dd_bcd[59:56] + 4'd3 : dd_bcd[59:56],
        (dd_bcd[55:52] >= 5) ? dd_bcd[55:52] + 4'd3 : dd_bcd[55:52],
        (dd_bcd[51:48] >= 5) ? dd_bcd[51:48] + 4'd3 : dd_bcd[51:48],
        (dd_bcd[47:44] >= 5) ? dd_bcd[47:44] + 4'd3 : dd_bcd[47:44],
        (dd_bcd[43:40] >= 5) ? dd_bcd[43:40] + 4'd3 : dd_bcd[43:40],
        (dd_bcd[39:36] >= 5) ? dd_bcd[39:36] + 4'd3 : dd_bcd[39:36],
        (dd_bcd[35:32] >= 5) ? dd_bcd[35:32] + 4'd3 : dd_bcd[35:32],
        (dd_bcd[31:28] >= 5) ? dd_bcd[31:28] + 4'd3 : dd_bcd[31:28],
        (dd_bcd[27:24] >= 5) ? dd_bcd[27:24] + 4'd3 : dd_bcd[27:24],
        (dd_bcd[23:20] >= 5) ? dd_bcd[23:20] + 4'd3 : dd_bcd[23:20],
        (dd_bcd[19:16] >= 5) ? dd_bcd[19:16] + 4'd3 : dd_bcd[19:16],
        (dd_bcd[15:12] >= 5) ? dd_bcd[15:12] + 4'd3 : dd_bcd[15:12],
        (dd_bcd[11:8]  >= 5) ? dd_bcd[11:8]  + 4'd3 : dd_bcd[11:8],
        (dd_bcd[7:4]   >= 5) ? dd_bcd[7:4]   + 4'd3 : dd_bcd[7:4],
        (dd_bcd[3:0]   >= 5) ? dd_bcd[3:0]   + 4'd3 : dd_bcd[3:0] };
    always @(posedge clk) begin
        dd_done <= 0;
        if (rst) begin dd_busy <= 0; end
        else if (dd_start) begin dd_in <= dd_src; dd_bcd <= 0; dd_n <= 0; dd_busy <= 1; end
        else if (dd_busy) begin
            if (dd_n == 48) begin dd_busy <= 0; dd_done <= 1; end
            else begin
                dd_bcd <= {dd_adj[58:0], dd_in[47]};
                dd_in  <= {dd_in[46:0], 1'b0};
                dd_n   <= dd_n + 1;
            end
        end
    end


    // BCD hasil beberapa konversi
    reg [59:0] bcd_pps, bcd_bps, bcd_tb, bcd_tp;           // hasil konversi (bekerja)
    reg [59:0] v_pps, v_bps, v_tb, v_tp;                   // salinan beku untuk penulisan
    reg [7:0]  v_h, v_m, v_s;
    reg [19:0] bcd_up_s, bcd_up_m, bcd_up_h;     // utk uptime (dihitung biner -> 2 digit)

    // uptime: pecah h:m:s (biner, pembagi dengan pengurangan berulang, jarang -> boleh lambat)
    reg [7:0] up_h, up_m, up_s;
    reg [31:0] up_rem;

    // ---------------------------------------------------------------
    // ROM teks + FSM penulis. Satu "frame" = refresh seluruh 2 baris.
    // ---------------------------------------------------------------
    // state utama
    localparam S_PWR=0, S_INIT=1, S_SNAP=2, S_CONV=3, S_UP=4, S_WRITE=5, S_MB=6;
    reg [3:0] st = S_PWR;
    reg [31:0] dly = 0;
    reg [3:0]  conv_i = 0;
    reg [5:0]  wr_i = 0;                  // 0..35 : 2 cmd set addr + 32 char + spare
    reg [3:0]  init_i = 0;
    reg [1:0]  phase = 0;                 // 0=siapkan, 1=E naik, 2=E turun, 3=tunggu

    // puluhan/satuan 0..99 tanpa pembagi (XST: pembagian non-pangkat-2 tak didukung)
    function [3:0] tens;
        input [7:0] x;
        begin
            tens = (x >= 90) ? 4'd9 : (x >= 80) ? 4'd8 : (x >= 70) ? 4'd7 : (x >= 60) ? 4'd6 :
                   (x >= 50) ? 4'd5 : (x >= 40) ? 4'd4 : (x >= 30) ? 4'd3 : (x >= 20) ? 4'd2 :
                   (x >= 10) ? 4'd1 : 4'd0;
        end
    endfunction
    function [3:0] ones;
        input [7:0] x;
        begin ones = x - (tens(x) * 10); end
    endfunction

    // helper: ASCII digit dari BCD pada indeks digit (0 = paling kanan)
    function [7:0] dig;
        input [59:0] b; input [3:0] idx;
        begin dig = 8'h30 + b[idx*4 +: 4]; end
    endfunction

    // karakter ke-k (0..31) dari tampilan saat ini
    function [7:0] ch;
        input [5:0] k;
        input [1:0] pg;
        begin
            ch = " ";
            if (k < 16) begin
                case (k)
                    0: ch="F"; 1: ch="A"; 2: ch="L"; 3: ch="C"; 4: ch="O"; 5: ch="N"; 6: ch=" ";
                    7: ch="U"; 8: ch="L"; 9: ch=" ";
                    10: ch = dig(v_pps, 4); 11: ch = dig(v_pps, 3); 12: ch = dig(v_pps, 2);
                    13: ch = dig(v_pps, 1); 14: ch = dig(v_pps, 0); 15: ch=" ";
                    default: ch=" ";
                endcase
            end else begin
                case (pg)
                    2'd0: begin // "Rate  0012.34 Mb/s" dipadatkan: "Rate 0012.34 Mbps" tak muat 16 -> "Rate 0012.34Mbps"
                        case (k-16)
                            0: ch="R"; 1: ch="a"; 2: ch="t"; 3: ch="e"; 4: ch=" ";
                            5: ch = dig(v_bps, 5); 6: ch = dig(v_bps, 4); 7: ch = dig(v_bps, 3); 8: ch = dig(v_bps, 2);
                            9: ch = "."; 10: ch = dig(v_bps, 1); 11: ch = dig(v_bps, 0);
                            12: ch = "M"; 13: ch = "b"; 14: ch = "p"; 15: ch = "s";
                            default: ch = " ";
                        endcase
                    end
                    2'd1: begin // "Tot 0000036000 B"
                        case (k-16)
                            0: ch="T"; 1: ch="o"; 2: ch="t"; 3: ch=" ";
                            4: ch=dig(v_tb,9); 5: ch=dig(v_tb,8); 6: ch=dig(v_tb,7); 7: ch=dig(v_tb,6); 8: ch=dig(v_tb,5);
                            9: ch=dig(v_tb,4); 10: ch=dig(v_tb,3); 11: ch=dig(v_tb,2); 12: ch=dig(v_tb,1); 13: ch=dig(v_tb,0);
                            14: ch=" "; 15: ch="B";
                            default: ch=" ";
                        endcase
                    end
                    2'd2: begin // "Pkt 000000003600"
                        case (k-16)
                            0: ch="P"; 1: ch="k"; 2: ch="t"; 3: ch=" ";
                            4: ch=dig(v_tp,11); 5: ch=dig(v_tp,10); 6: ch=dig(v_tp,9); 7: ch=dig(v_tp,8);
                            8: ch=dig(v_tp,7);  9: ch=dig(v_tp,6);  10: ch=dig(v_tp,5); 11: ch=dig(v_tp,4);
                            12: ch=dig(v_tp,3); 13: ch=dig(v_tp,2); 14: ch=dig(v_tp,1); 15: ch=dig(v_tp,0);
                            default: ch=" ";
                        endcase
                    end
                    default: begin // "Up   00:12:34    "
                        case (k-16)
                            0: ch="U"; 1: ch="p"; 2: ch=" "; 3: ch=" "; 4: ch=" ";
                            5: ch = 8'h30 + tens(v_h); 6: ch = 8'h30 + ones(v_h); 7: ch=":";
                            8: ch = 8'h30 + tens(v_m); 9: ch = 8'h30 + ones(v_m); 10: ch=":";
                            11: ch = 8'h30 + tens(v_s); 12: ch = 8'h30 + ones(v_s);
                            default: ch=" ";
                        endcase
                    end
                endcase
            end
        end
    endfunction

    // Mbps*100 = bytes/s * 8 / 10_000  -> pakai perkalian + geser kasar: (b*8)/10000 = b/1250
    // dihitung di S_SNAP dengan pengurangan berulang (jarang jalan) - lihat di bawah.
    reg [31:0] mb_rem;

    // pengiriman satu byte ke LCD (rs, data) : phase machine, E pulse >= 230ns (30 clk ~ 240ns)
    reg [7:0] tx_data;
    reg       tx_rs;
    reg       tx_go = 0;
    reg       tx_busy = 0;
    reg [15:0] tx_cnt = 0;
    reg [31:0] tx_wait = 0;
    reg [31:0] tx_wait_load;
    always @(posedge clk) begin
        if (rst) begin lcd_e <= 0; lcd_rs <= 0; lcd_db <= 0; tx_busy <= 0; tx_cnt <= 0; end
        else if (tx_go && !tx_busy) begin
            lcd_rs <= tx_rs; lcd_db <= tx_data; lcd_e <= 0;
            tx_busy <= 1; tx_cnt <= 0; tx_wait <= tx_wait_load;
        end else if (tx_busy) begin
            if (tx_cnt < 56) tx_cnt <= tx_cnt + 1;   // tahan di 56: cegah luap 16-bit yg memicu pulsa E palsu saat tunggu panjang
            if (tx_cnt == 8)  lcd_e <= 1;        // setup data >= 40 ns, lalu E naik
            if (tx_cnt == 48) lcd_e <= 0;        // E tinggi ~320 ns (>=230 ns); data ditulis di tepi turun
            if (tx_cnt >= 56 && tx_wait != 0) tx_wait <= tx_wait - 1;
            if (tx_cnt >= 56 && tx_wait == 0) tx_busy <= 0;
        end
    end

    // FSM utama
    always @(posedge clk) begin
        tx_go <= 0;
        if (rst) begin
            st <= S_PWR; dly <= 0; init_i <= 0; wr_i <= 0; conv_i <= 0; dd_start <= 0;
        end else begin
            dd_start <= 0;
            case (st)
                S_PWR: begin
                    if (dly == PWR_DELAY) begin st <= S_INIT; init_i <= 0; dly <= 0; end
                    else dly <= dly + 1;
                end
                // Urutan init manual: function set (8-bit, 2 baris, 5x8) -> display on -> clear -> entry mode
                S_INIT: if (!tx_busy && !tx_go) begin
                    case (init_i)
                        0: begin tx_rs<=0; tx_data<=8'h38; tx_wait_load<=T_37US;   tx_go<=1; init_i<=1; end
                        1: begin tx_rs<=0; tx_data<=8'h38; tx_wait_load<=T_37US;   tx_go<=1; init_i<=2; end
                        2: begin tx_rs<=0; tx_data<=8'h0C; tx_wait_load<=T_37US;   tx_go<=1; init_i<=3; end   // display on, cursor off
                        3: begin tx_rs<=0; tx_data<=8'h01; tx_wait_load<=T_1P52MS; tx_go<=1; init_i<=4; end   // clear
                        4: begin tx_rs<=0; tx_data<=8'h06; tx_wait_load<=T_37US;   tx_go<=1; init_i<=5; end   // entry mode: increment
                        default: begin st <= S_SNAP; end
                    endcase
                end
                // Ambil snapshot nilai
                S_SNAP: begin
                    s_pps <= last_pps; s_bps <= last_bps; s_up <= uptime_s;
                    s_tot_b <= tot_bytes; s_tot_p <= tot_pkts; s_page <= page;
                    mb_rem <= last_bps; mbps100 <= 0; conv_i <= 0; st <= S_MB;
                end
                // Mbps*100 = byte/s * 8 / 10000 = byte/s / 1250 via pengurangan berulang
                S_MB: begin
                    if (mb_rem >= 1250) begin mb_rem <= mb_rem - 1250; mbps100 <= mbps100 + 1; end
                    else st <= S_CONV;
                end
                // Konversi 4 nilai ke BCD (berurutan: pps, mbps*100, total byte, total paket)
                S_CONV: begin
                    if (!dd_busy && !dd_start && !dd_done) begin
                        case (conv_i)
                            0: begin dd_src <= {16'b0, s_pps}; dd_start <= 1; conv_i <= 1; end
                            2: begin
                                // Mbps*100 = byte/s * 8 / 10000 = byte/s / 1250 (pembagian satu kali, di sini via loop)
                                dd_src <= {16'b0, mbps100}; dd_start <= 1; conv_i <= 3;
                            end
                            4: begin dd_src <= s_tot_b; dd_start <= 1; conv_i <= 5; end
                            6: begin dd_src <= s_tot_p; dd_start <= 1; conv_i <= 7; end
                            8: begin st <= S_UP; end
                            default: ;
                        endcase
                    end
                    if (dd_done) begin
                        case (conv_i)
                            1: begin bcd_pps <= dd_bcd; conv_i <= 2; end
                            3: begin bcd_bps <= dd_bcd; conv_i <= 4; end
                            5: begin bcd_tb  <= dd_bcd; conv_i <= 6; end
                            7: begin bcd_tp  <= dd_bcd; conv_i <= 8; end
                            default: ;
                        endcase
                    end
                end
                S_UP: begin
                    // pecah uptime ke h:m:s tanpa pembagi: loop pengurangan satu langkah per clk
                    // (<= 360 iterasi bagi jam, aman). Dijalankan sekali per frame.
                    if (conv_i == 8) begin up_rem <= s_up; up_h <= 0; up_m <= 0; up_s <= 0; conv_i <= 9; end
                    else if (conv_i == 9) begin
                        if (up_rem >= 3600) begin up_rem <= up_rem - 3600; up_h <= up_h + 1; end
                        else conv_i <= 10;
                    end else if (conv_i == 10) begin
                        if (up_rem >= 60) begin up_rem <= up_rem - 60; up_m <= up_m + 1; end
                        else begin up_s <= up_rem[7:0]; conv_i <= 11; end
                    end else begin
                        v_pps<=bcd_pps; v_bps<=bcd_bps; v_tb<=bcd_tb; v_tp<=bcd_tp; v_h<=up_h; v_m<=up_m; v_s<=up_s;
                        wr_i <= 0; st <= S_WRITE;
                    end
                end
                S_WRITE: if (!tx_busy && !tx_go) begin
                    if (wr_i == 0) begin
                        tx_rs<=0; tx_data<=8'h80; tx_wait_load<=T_37US; tx_go<=1; wr_i<=1;    // DDRAM 0x00 (baris 1)
                    end else if (wr_i <= 16) begin
                        tx_rs<=1; tx_data<=ch(wr_i-1, s_page); tx_wait_load<=T_37US; tx_go<=1; wr_i<=wr_i+1;
                    end else if (wr_i == 17) begin
                        tx_rs<=0; tx_data<=8'hC0; tx_wait_load<=T_37US; tx_go<=1; wr_i<=18;   // DDRAM 0x40 (baris 2)
                    end else if (wr_i <= 34) begin
                        tx_rs<=1; tx_data<=ch(wr_i-2, s_page); tx_wait_load<=T_37US; tx_go<=1; wr_i<=wr_i+1;
                    end else begin
                        st <= S_SNAP;     // frame berikut; kecepatan ditentukan total waktu tulis (~1,5 ms)
                    end
                end
                default: st <= S_PWR;
            endcase
        end
    end

endmodule
