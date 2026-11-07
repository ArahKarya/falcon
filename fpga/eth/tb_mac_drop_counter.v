// tb_mac_drop_counter.v — uji counter drop MAC (iverilog). Menunjukkan: hitung benar, tumbukan dua pulsa
// dijumlah (bukan OR), saturasi tidak membungkus, reset menolkan.
`timescale 1ns / 1ps
module tb_mac_drop_counter;
    reg clk = 0, rst = 1;
    reg ov = 0, bf = 0, gf = 0;
    wire [31:0] drop, ovf, bad, ok;
    integer fails = 0;

    mac_drop_counter dut (.clk(clk), .rst(rst), .ev_overflow(ov), .ev_bad_frame(bf), .ev_good_frame(gf),
                          .drop_total(drop), .overflow_total(ovf), .bad_total(bad), .frames_ok(ok));
    always #4 clk = ~clk;

    task chk(input [255:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got === want) $display("PASS %0s = %0d", name, got);
            else begin $display("FAIL %0s: got %0d want %0d", name, got, want); fails = fails + 1; end
        end
    endtask

    task pulse(input o, input b, input g);
        begin
            @(negedge clk); ov = o; bf = b; gf = g;
            @(negedge clk); ov = 0; bf = 0; gf = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(negedge clk); rst = 0;
        // 1. awal nol
        chk("awal drop", drop, 0); chk("awal ok", ok, 0);
        // 2. 5 good, 3 overflow, 2 bad (terpisah)
        for (i = 0; i < 5; i = i + 1) pulse(0, 0, 1);
        for (i = 0; i < 3; i = i + 1) pulse(1, 0, 0);
        for (i = 0; i < 2; i = i + 1) pulse(0, 1, 0);
        repeat (2) @(negedge clk);
        chk("ok", ok, 5); chk("overflow", ovf, 3); chk("bad", bad, 2); chk("drop = ovf+bad", drop, 5);
        // 3. overflow & bad pada siklus SAMA -> drop +2 (bukan +1)
        pulse(1, 1, 0);
        repeat (2) @(negedge clk);
        chk("tumbukan: drop +2", drop, 7); chk("tumbukan: ovf", ovf, 4); chk("tumbukan: bad", bad, 3);
        // 4. good bersamaan dengan drop tidak saling mengganggu
        pulse(1, 0, 1);
        repeat (2) @(negedge clk);
        chk("campur: ok", ok, 6); chk("campur: drop", drop, 8);
        // 5. reset menolkan
        @(negedge clk); rst = 1; @(negedge clk); rst = 0; @(negedge clk);
        chk("reset drop", drop, 0); chk("reset ok", ok, 0);
        // 6. saturasi: paksa nilai mendekati batas lewat deposit nilai internal
        force dut.drop_r = 32'hFFFF_FFFD; force dut.ok_r = 32'hFFFF_FFFF;
        @(negedge clk); release dut.drop_r; release dut.ok_r;
        pulse(1, 1, 1);     // +2 -> harus tersaturasi 0xFFFFFFFF, bukan membungkus
        repeat (2) @(negedge clk);
        chk("saturasi drop", drop, 32'hFFFF_FFFF);
        chk("saturasi ok tidak membungkus", ok, 32'hFFFF_FFFF);
        pulse(1, 0, 0); repeat (2) @(negedge clk);
        chk("tetap jenuh", drop, 32'hFFFF_FFFF);
        $display("---- %0s", fails == 0 ? "SEMUA LULUS" : "ADA YANG GAGAL");
        if (fails != 0) $fatal(1);
        $finish;
    end
endmodule
