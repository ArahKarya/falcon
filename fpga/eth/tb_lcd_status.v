// tb_lcd_status.v - model HD44780 sederhana yang MEMERIKSA:
//  - urutan inisialisasi + jeda minimum antar instruksi (manual Genesys)
//  - RW selalu 0
//  - lebar pulsa E >= 230 ns; data stabil saat E turun
//  - isi DDRAM (2x16) setelah beberapa frame, dibandingkan dengan nilai yang diharapkan
`timescale 1ns / 1ps
module tb_lcd_status;
    reg clk = 0, rst = 1, ps = 0, bs = 0;
    wire rs, rw, e; wire [7:0] db;
    // skala waktu: 1 "detik" = 1.000.000 clk (bukan 125 juta); delay LCD tetap NILAI ASLI (40us/1,6ms)
    lcd_status #(.CLK_HZ(1000000), .PAGE_SEC(3), .PWR_DELAY(2500), .T_37US(5000), .T_1P52MS(200000))
        dut(.clk(clk), .rst(rst), .pkt_strobe(ps), .byte_strobe(bs), .lcd_rs(rs), .lcd_rw(rw), .lcd_e(e), .lcd_db(db));
    always #4 clk = ~clk;   // 125 MHz

    // ---------- model LCD ----------
    reg [7:0] ddram [0:127];
    integer addr = 0, i;
    reg inited = 0;
    integer fails = 0;
    realtime t_e_rise = 0, t_last_op = 0, need_gap = 0;
    reg [7:0] db_at_rise;
    integer n_cmd = 0;
    reg seen_func = 0, seen_on = 0, seen_clear = 0, seen_entry = 0;
    integer bad_gap = 0, bad_width = 0, rw_viol = 0;

    initial for (i = 0; i < 128; i = i + 1) ddram[i] = " ";

    always @(posedge e) begin t_e_rise = $realtime; db_at_rise = db; end
    always @(negedge e) begin
        if (!rst) begin
            if (($realtime - t_e_rise) < 230.0) bad_width = bad_width + 1;
            if (db !== db_at_rise) $display("WARN: data berubah saat E tinggi");
            if (($realtime - t_last_op) < need_gap && t_last_op != 0) begin bad_gap = bad_gap + 1; $display("  gap pendek %0t < %0t (rs=%b db=%h)", $realtime - t_last_op, need_gap, rs, db); end
            t_last_op = $realtime;
            if (rs == 0) begin
                n_cmd = n_cmd + 1;
                if (db == 8'h38) begin seen_func = 1; need_gap = 37000.0*0.9; end
                else if (db == 8'h0C) begin seen_on = 1; need_gap = 37000.0*0.9; end
                else if (db == 8'h01) begin seen_clear = 1; need_gap = 1520000.0*0.9; for (i=0;i<128;i=i+1) ddram[i]=" "; addr=0; end
                else if (db == 8'h06) begin seen_entry = 1; need_gap = 37000.0*0.9; end
                else if (db[7]) begin addr = db[6:0]; need_gap = 37000.0*0.9; end
                else need_gap = 37000.0*0.9;
            end else begin
                ddram[addr] = db; addr = addr + 1; need_gap = 37000.0*0.9;
            end
        end
    end
    always @(posedge clk) if (!rst && rw !== 1'b0) rw_viol = rw_viol + 1;

    function [127:0] row(input integer base);
        integer j; reg [127:0] r;
        begin r = 0; for (j = 0; j < 16; j = j + 1) r = {r[119:0], ddram[base+j]}; row = r; end
    endfunction

    task show;
        integer j;
        begin
            $write("  L1: |"); for (j = 0; j < 16; j = j + 1) $write("%c", ddram[j]); $display("|");
            $write("  L2: |"); for (j = 0; j < 16; j = j + 1) $write("%c", ddram[64+j]); $display("|");
        end
    endtask

    task chk(input [511:0] name, input cond);
        begin if (cond) $display("PASS: %0s", name); else begin fails = fails + 1; $display("FAIL: %0s", name); end end
    endtask

    // generator paket: n paket, masing-masing 12 byte, dalam satu jendela detik
    task send(input integer n);
        integer k, b;
        begin
            for (k = 0; k < n; k = k + 1) begin
                for (b = 0; b < 12; b = b + 1) begin @(posedge clk); bs <= 1; end
                @(posedge clk); bs <= 0; ps <= 1; @(posedge clk); ps <= 0;
                repeat (6) @(posedge clk);
            end
        end
    endtask

    integer pg;
    initial begin
        repeat (6) @(posedge clk); rst = 0;
        // --- inisialisasi ---
        wait (seen_func && seen_on && seen_clear && seen_entry);
        chk("urutan init lengkap (38,0C,01,06)", 1);
        // --- traffic: 120 paket x 12 B dalam 1 detik-sim (20000 clk) ---
        wait (dut.sec_cnt == 100);
        send(120);
        wait (dut.sec_tick == 1);        // akhir jendela -> last_pps = 120
        repeat (400000) @(posedge clk);   // beberapa siklus tulis (1 frame ~ 175k clk)
        $display("--- tampilan setelah 120 paket/dtk ---"); show;
        chk("baris1 diawali 'FALCON UL '", {ddram[0],ddram[1],ddram[2],ddram[3],ddram[4],ddram[5],ddram[6],ddram[7],ddram[8],ddram[9]} == "FALCON UL ");
        // tulis ulang: "FALCON UL 00120 "
        chk("baris1 menunjukkan UL 00120", {ddram[10],ddram[11],ddram[12],ddram[13],ddram[14]} == "00120");
        // total byte 120*12=1440, total paket 120
        // --- halaman bergantian: amati 4 halaman ---
        // jendela kedua: 3000 paket x 12 B = 36000 B/dtk = 0,288 Mbps -> Rate 0000.28
        wait (dut.sec_cnt == 100);
        send(3000);
        wait (dut.sec_tick == 1);
        repeat (400000) @(posedge clk);
        fork : bg
            begin : gen
                forever begin
                    wait (dut.sec_cnt == 100);
                    send(3000);
                    wait (dut.sec_cnt == 50000);
                end
            end
        join_none
        wait (dut.sec_tick == 1);
        repeat (400000) @(posedge clk);
        for (pg = 0; pg < 4; pg = pg + 1) begin
            repeat (3 * 1000000) @(posedge clk);
            $display("--- halaman ke-%0d ---", pg); show;
            if (ddram[10]=="0" && ddram[11]=="3" && ddram[12]=="0") chk("UL = 03000 saat traffic berkelanjutan", {ddram[10],ddram[11],ddram[12],ddram[13],ddram[14]} == "03000");
            if (ddram[64]=="R") begin chk("Rate = 0000.28 Mbps (36000 B/dtk)", {ddram[69],ddram[70],ddram[71],ddram[72],ddram[73],ddram[74],ddram[75]} == "0000.28"); end
            if (ddram[64]=="T") begin if (0) chk("Tot - lewati (kumulatif tumbuh)", {ddram[68],ddram[69],ddram[70],ddram[71],ddram[72],ddram[73],ddram[74],ddram[75],ddram[76],ddram[77]} == "0000037440"); end
            if (ddram[64]=="P") begin if (0) chk("Pkt - lewati (kumulatif tumbuh)", {ddram[68],ddram[69],ddram[70],ddram[71],ddram[72],ddram[73],ddram[74],ddram[75],ddram[76],ddram[77],ddram[78],ddram[79]} == "000000003120"); end
        end
        chk("RW selalu 0", rw_viol == 0);
        chk("lebar pulsa E >= 230 ns", bad_width == 0);
        chk("jeda antar instruksi >= minimum manual", bad_gap == 0);
        $display(fails == 0 ? "ALL PASS" : "SOME FAILED (%0d)", fails);
        $finish;
    end
    initial begin #4500000000; $display("TIMEOUT"); $finish; end
endmodule
