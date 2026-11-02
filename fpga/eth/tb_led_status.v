`timescale 1ns / 1ps
module tb_led_status;
    reg clk = 0, rst = 1, gs = 0, ts = 0, dv = 0;
    wire [7:0] led;
    // 1 "detik" = 2000 clk, stretch = 200 clk
    led_status #(.LED_SEC(2000), .LED_STRETCH(200)) dut(.clk(clk), .rst(rst), .gtpu_strobe(gs), .tx_strobe(ts), .phy_rx_dv(dv), .led(led));
    always #4 clk = ~clk;
    integer fails = 0, i, hb_edges = 0;
    reg hb_prev = 0;
    task check(input [511:0] name, input cond);
        begin if (!cond) begin fails = fails + 1; $display("FAIL: %0s (led=%b)", name, led); end else $display("PASS: %0s", name); end
    endtask
    task pulse_g; begin @(posedge clk); gs <= 1; @(posedge clk); gs <= 0; end endtask
    task pulse_t; begin @(posedge clk); ts <= 1; @(posedge clk); ts <= 0; end endtask
    always @(posedge clk) begin if (led[0] !== hb_prev && !rst) hb_edges = hb_edges + 1; hb_prev <= led[0]; end

    initial begin
        repeat (5) @(posedge clk); rst = 0;
        // idle: semua LED selain heartbeat mati
        repeat (500) @(posedge clk);
        check("idle: LD1..LD7 mati", led[7:1] == 7'b0);
        // heartbeat: 1 periode = 2000 clk -> 2 tepi per 2000 clk. amati 6000 clk
        hb_edges = 0; repeat (6000) @(posedge clk);
        check("LD0 heartbeat berkedip (>=5 tepi per 3 periode)", hb_edges >= 5 && hb_edges <= 7);
        // GTP-U masuk -> LD1 nyala lalu padam setelah stretch
        pulse_g; repeat (3) @(posedge clk);
        check("LD1 nyala setelah paket GTP-U", led[1] == 1);
        repeat (260) @(posedge clk);
        check("LD1 padam setelah stretch", led[1] == 0);
        // telemetri keluar -> LD2
        pulse_t; repeat (3) @(posedge clk);
        check("LD2 nyala setelah telemetri", led[2] == 1 && led[1] == 0);
        repeat (260) @(posedge clk);
        check("LD2 padam", led[2] == 0);
        // frame ethernet -> LD3 (async dv)
        #3 dv = 1; repeat (10) @(posedge clk); dv = 0; repeat (6) @(posedge clk);
        check("LD3 nyala setelah frame Ethernet", led[3] == 1);
        repeat (260) @(posedge clk);
        check("LD3 padam", led[3] == 0);
        // bar beban: kirim 150 paket dalam 1 jendela -> LD4,LD5 (>=1,>=100) nyala; LD6 mati
        // sinkronkan ke awal jendela: tunggu load_bar berubah/tepi jendela dgn memantau hitungan internal
        wait (dut.win_cnt == 5); 
        for (i = 0; i < 150; i = i + 1) begin pulse_g; repeat (4) @(posedge clk); end
        wait (dut.win_cnt == 2000-2); repeat (4) @(posedge clk);
        check("bar: 150 paket/jendela -> LD4 & LD5 nyala, LD6/LD7 mati", led[7:4] == 4'b0011);
        // jendela berikut tanpa paket -> bar turun
        repeat (4200) @(posedge clk);
        check("bar turun ke 0 saat idle", led[7:4] == 4'b0000);
        // 1 paket saja -> hanya LD4
        pulse_g; repeat (2100) @(posedge clk);
        check("bar: 1 paket -> hanya LD4", led[7:4] == 4'b0001);
        // reset
        rst = 1; repeat (3) @(posedge clk);
        check("reset memadamkan semua LED", led == 8'b0);
        $display(fails == 0 ? "ALL PASS" : "SOME FAILED (%0d)", fails);
        $finish;
    end
endmodule
