--============================================================================
-- tb_imsi_test.vhd — feed N frame GTP-U ber-IMSI (dari gen_imsi_test.py) ke
-- gtpu_parser, verifikasi TEID tiap sesi terparse benar.
--
-- Baca vectors/imsi_frames.txt : <teid_hex> <dport_hex> <frame_hex> per baris.
-- Untuk tiap frame: stream byte -> cek is_gtpu=1, dport=2152, teid=expected.
--
-- Ini "board virtual" (simulasi RTL) untuk uji ekstraksi metadata sebelum
-- board fisik. IMSI fiktif (peta di imsi_map.csv) dikelola host.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

library work;
use work.falcon_pkg.all;

entity tb_imsi_test is
end entity;

architecture sim of tb_imsi_test is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal tdata : std_logic_vector(7 downto 0) := (others=>'0');
  signal tvalid: std_logic := '0';
  signal tlast : std_logic := '0';

  signal done, is_ipv4, is_udp, is_gtpu : std_logic;
  signal sport, dport, plen : std_logic_vector(15 downto 0);
  signal mtype : std_logic_vector(7 downto 0);
  signal teid  : std_logic_vector(31 downto 0);

  constant CLK_PERIOD : time := 10 ns;
  signal fails : integer := 0;

  -- hex char -> 4-bit
  function hc(c : character) return std_logic_vector is
  begin
    case c is
      when '0' => return x"0"; when '1' => return x"1"; when '2' => return x"2";
      when '3' => return x"3"; when '4' => return x"4"; when '5' => return x"5";
      when '6' => return x"6"; when '7' => return x"7"; when '8' => return x"8";
      when '9' => return x"9"; when 'a'|'A' => return x"a"; when 'b'|'B' => return x"b";
      when 'c'|'C' => return x"c"; when 'd'|'D' => return x"d"; when 'e'|'E' => return x"e";
      when 'f'|'F' => return x"f"; when others => return x"0";
    end case;
  end function;
begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.gtpu_parser
    port map (
      clk=>clk, rst=>rst, s_tdata=>tdata, s_tvalid=>tvalid, s_tready=>open, s_tlast=>tlast,
      done=>done, is_ipv4=>is_ipv4, is_udp=>is_udp, is_gtpu=>is_gtpu,
      udp_sport=>sport, udp_dport=>dport, gtpu_mtype=>mtype, teid=>teid, payload_len=>plen
    );

  process
    file fh        : text;
    variable ln    : line;
    variable fstat : file_open_status;
    variable teid_s : string(1 to 8);
    variable dport_s: string(1 to 4);
    variable ch     : character;
    variable good   : boolean;
    variable exp_teid : std_logic_vector(31 downto 0);
    variable byteval  : std_logic_vector(7 downto 0);
    variable hi, lo   : character;
    variable cnt      : integer := 0;

    procedure chk(name : string; cond : boolean) is
    begin
      if cond then report "PASS " & name severity note;
      else fails <= fails + 1; report "FAIL " & name severity error; end if;
    end procedure;
  begin
    file_open(fstat, fh, "vectors/imsi_frames.txt", read_mode);
    if fstat /= open_ok then
      report "TIDAK BISA buka vectors/imsi_frames.txt (jalankan gen_imsi_test.py dulu)" severity failure;
      wait;
    end if;

    while not endfile(fh) loop
      readline(fh, ln);
      next when ln'length = 0;

      -- baca teid_hex (8 char)
      read(ln, teid_s, good);
      read(ln, ch);  -- spasi
      read(ln, dport_s, good);
      read(ln, ch);  -- spasi

      exp_teid := (others=>'0');
      for i in 1 to 8 loop
        exp_teid(35-4*i downto 32-4*i) := hc(teid_s(i));
      end loop;

      -- reset DUT antar frame
      rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
      rst <= '0'; wait until rising_edge(clk);

      -- stream frame: baca pasangan hex char dari sisa baris
      loop
        read(ln, hi, good); exit when not good;
        read(ln, lo, good); exit when not good;
        byteval := hc(hi) & hc(lo);
        tdata  <= byteval;
        tvalid <= '1';
        -- tlast saat byte terakhir (peek: kalau sisa baris kosong setelah ini)
        if ln'length = 0 then tlast <= '1'; else tlast <= '0'; end if;
        wait until rising_edge(clk);
      end loop;
      tvalid <= '0'; tlast <= '0';
      wait until rising_edge(clk);
      wait for 1 ns;

      cnt := cnt + 1;
      chk("frame#" & integer'image(cnt) & " is_gtpu", is_gtpu = '1');
      chk("frame#" & integer'image(cnt) & " dport=2152", dport = PORT_GTPU);
      chk("frame#" & integer'image(cnt) & " teid match", teid = exp_teid);
    end loop;
    file_close(fh);

    report "=== IMSI TEST: " & integer'image(cnt) & " frame diproses ===" severity note;
    if fails = 0 then
      report "=== ALL PASS - parser ekstrak TEID tiap sesi IMSI benar ===" severity note;
    else
      report "=== ADA FAIL: " & integer'image(fails) severity failure;
    end if;
    wait;
  end process;
end architecture sim;
