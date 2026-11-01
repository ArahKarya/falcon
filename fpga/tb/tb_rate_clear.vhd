--============================================================================
-- tb_rate_clear.vhd — regresi bug "ul_pps kumulatif".
--
-- Sebelum fix: rate_clear di wrapper = '0' konstan -> ul_pps menghitung total
-- paket sejak load bitstream. Sesudah fix: counter di-nol-kan tiap emit GLOBAL
-- (0x01), jadi ul_pps = paket per interval.
--
-- Skenario (falcon_top dipakai langsung, emit dikendalikan tb):
--   interval 1: kirim N1 frame GTP-U UL  -> emit_global -> ul_pps harus = N1
--   interval 2: kirim N2 frame GTP-U UL  -> emit_global -> ul_pps harus = N2
--   interval 3: kirim 0 frame            -> emit_global -> ul_pps harus = 0
-- Sebelum fix: N1, N1+N2, N1+N2 (kumulatif). Sesudah: N1, N2, 0.
--
-- Frame: 1 baris golden dari vectors/imsi_frames_60.txt (<teid> <dport> <hex>).
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.falcon_pkg.all;

entity tb_rate_clear is
end entity;

architecture sim of tb_rate_clear is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal tvalid : std_logic := '0';
  signal tlast  : std_logic := '0';
  signal tready : std_logic;

  signal emit_global : std_logic := '0';
  signal pkt_done    : std_logic;
  signal pkt_teid    : std_logic_vector(31 downto 0);
  signal tx_dgram    : std_logic_vector(543 downto 0);
  signal tx_len      : std_logic_vector(15 downto 0);
  signal tx_valid    : std_logic;

  constant CLK_PERIOD : time := 10 ns;
  signal fails : integer := 0;
  signal last_dg  : std_logic_vector(543 downto 0) := (others => '0');
  signal dg_count : integer := 0;

  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);

  function hc(c : character) return std_logic_vector is
  begin
    case c is
      when '0' => return x"0"; when '1' => return x"1"; when '2' => return x"2";
      when '3' => return x"3"; when '4' => return x"4"; when '5' => return x"5";
      when '6' => return x"6"; when '7' => return x"7"; when '8' => return x"8";
      when '9' => return x"9"; when 'a' | 'A' => return x"A"; when 'b' | 'B' => return x"B";
      when 'c' | 'C' => return x"C"; when 'd' | 'D' => return x"D"; when 'e' | 'E' => return x"E";
      when 'f' | 'F' => return x"F"; when others => return x"0";
    end case;
  end function;
begin
  clk <= not clk after CLK_PERIOD / 2;

  dut : entity work.falcon_top
    port map (
      clk => clk, rst => rst,
      rx_tdata => tdata, rx_tvalid => tvalid, rx_tready => tready, rx_tlast => tlast,
      emit_global => emit_global, emit_proto => '0', emit_teid => '0', emit_event => '0',
      ev_type => (others => '0'), ev_dir => (others => '0'), ev_teid => (others => '0'),
      ev_plen => (others => '0'), ev_ts => (others => '0'),
      auto_event => '0', pkt_done => pkt_done, pkt_teid_o => pkt_teid,
      ts_now => x"00000001", total_imsi => (others => '0'), active_teid => (others => '0'),
      rate_clear => '0',
      tx_dgram => tx_dgram, tx_len => tx_len, tx_valid => tx_valid);

  -- monitor: tangkap datagram tiap pulse valid (pulse hanya 1 siklus)
  mon : process(clk)
  begin
    if rising_edge(clk) then
      if tx_valid = '1' and tx_dgram(543 downto 536) = x"01" then
        last_dg  <= tx_dgram;
        dg_count <= dg_count + 1;
      end if;
    end if;
  end process;

  stim : process
    file fh : text;
    variable ln, fr : line;
    variable fstat  : file_open_status;
    variable teid_s : string(1 to 8);
    variable dport_s: string(1 to 4);
    variable ch, hi, lo : character;
    variable good   : boolean;
    variable frame  : byte_arr(0 to 255);
    variable nbytes : integer := 0;
    variable ul_seen: unsigned(31 downto 0);
    variable dg   : std_logic_vector(543 downto 0);

    procedure send_frame is
    begin
      for i in 0 to nbytes - 1 loop
        tdata  <= frame(i);
        tvalid <= '1';
        if i = nbytes - 1 then tlast <= '1'; else tlast <= '0'; end if;
        wait until rising_edge(clk);
      end loop;
      tvalid <= '0'; tlast <= '0';
      for i in 0 to 15 loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure send_n(n : integer) is
    begin
      for k in 1 to n loop send_frame; end loop;
    end procedure;

    procedure emit_and_check(expected : integer; tag : string) is
      variable before : integer;
    begin
      before := dg_count;
      emit_global <= '1';
      wait until rising_edge(clk);
      emit_global <= '0';
      for i in 0 to 80 loop
        wait until rising_edge(clk);
        exit when dg_count > before;
      end loop;
      wait for 1 ns;
      assert dg_count > before report tag & ": datagram 0x01 tidak muncul" severity failure;
      -- header 4B, lalu ts(4) imsi(4) ul(4): ul_pps = byte 12..15
      ul_seen := unsigned(last_dg(543 - 12*8 downto 543 - 12*8 - 31));
      report tag & ": ul_pps=" & integer'image(to_integer(ul_seen)) &
             " (expected " & integer'image(expected) & ")";
      if to_integer(ul_seen) /= expected then
        fails <= fails + 1;
        report "FAIL " & tag severity error;
      else
        report "PASS " & tag severity note;
      end if;
      for i in 0 to 30 loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    file_open(fstat, fh, "vectors/imsi_frames.txt", read_mode);
    assert fstat = open_ok report "tidak bisa buka vectors/imsi_frames.txt" severity failure;
    readline(fh, ln);
    read(ln, teid_s, good); read(ln, ch); read(ln, dport_s, good); read(ln, ch);
    loop
      read(ln, hi, good); exit when not good;
      read(ln, lo, good); exit when not good;
      frame(nbytes) := hc(hi) & hc(lo);
      nbytes := nbytes + 1;
    end loop;
    file_close(fh);

    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; for i in 0 to 5 loop wait until rising_edge(clk); end loop;

    send_n(5);  emit_and_check(5,  "interval1");
    send_n(3);  emit_and_check(3,  "interval2 (bukan kumulatif 8)");
    emit_and_check(0, "interval3 idle");
    send_n(7);  emit_and_check(7,  "interval4");

    if fails = 0 then
      report "=== RATE_CLEAR: ALL PASS ===" severity note;
    else
      report "=== RATE_CLEAR: FAIL " & integer'image(fails) severity failure;
    end if;
    wait;
  end process;
end architecture;
