--============================================================================
-- tb_telemetry_packer.vhd — testbench BYTE-EXACT lawan vektor contract.py
--
-- Drive telemetry_packer dengan nilai identik gen_golden.py, lalu bandingkan
-- output 'dgram[0 .. dgram_len-1]' terhadap fpga/tb/vectors/golden.txt.
-- Jika semua tipe cocok byte-per-byte -> kontrak FPGA<->host tersinkron.
--
-- Jalankan: lihat fpga/sim/run_packer_tb.sh (GHDL).
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

library work;
use work.falcon_pkg.all;

entity tb_telemetry_packer is
end entity;

architecture sim of tb_telemetry_packer is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal msg_type : std_logic_vector(7 downto 0) := (others=>'0');
  signal start    : std_logic := '0';

  -- field 0x01
  signal g_ts, g_total_imsi, g_ul_pps, g_dl_pps, g_active_teid, g_drop : std_logic_vector(31 downto 0) := (others=>'0');
  signal g_total_bytes : std_logic_vector(63 downto 0) := (others=>'0');
  -- field 0x02
  signal t_teid, t_ul_pkts, t_dl_pkts : std_logic_vector(31 downto 0) := (others=>'0');
  signal t_imsi : std_logic_vector(127 downto 0) := (others=>'0');
  signal t_qfi, t_state : std_logic_vector(7 downto 0) := (others=>'0');
  -- field 0x03
  signal e_type, e_dir : std_logic_vector(7 downto 0) := (others=>'0');
  signal e_teid, e_ts : std_logic_vector(31 downto 0) := (others=>'0');
  signal e_plen : std_logic_vector(15 downto 0) := (others=>'0');
  -- field 0x04
  signal p_gtpu, p_gtpc, p_pfcp, p_bssgp, p_other : std_logic_vector(15 downto 0) := (others=>'0');

  signal dgram     : std_logic_vector(543 downto 0);
  signal dgram_len : std_logic_vector(15 downto 0);
  signal valid     : std_logic;

  constant CLK_PERIOD : time := 10 ns;
  signal fail_count : integer := 0;

  -- ASCII IMSI "310410123456789" pad 16B (kiri-rata, nol di kanan)
  -- byte: 33 31 30 34 31 30 31 32 33 34 35 36 37 38 39 00
  constant IMSI16 : std_logic_vector(127 downto 0) :=
    x"33313034313031323334353637383900";

begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.telemetry_packer
    port map (
      clk=>clk, rst=>rst, msg_type=>msg_type, start=>start,
      g_ts=>g_ts, g_total_imsi=>g_total_imsi, g_ul_pps=>g_ul_pps, g_dl_pps=>g_dl_pps,
      g_active_teid=>g_active_teid, g_total_bytes=>g_total_bytes, g_drop=>g_drop,
      t_teid=>t_teid, t_imsi=>t_imsi, t_qfi=>t_qfi, t_state=>t_state,
      t_ul_pkts=>t_ul_pkts, t_dl_pkts=>t_dl_pkts,
      e_type=>e_type, e_dir=>e_dir, e_teid=>e_teid, e_plen=>e_plen, e_ts=>e_ts,
      p_gtpu=>p_gtpu, p_gtpc=>p_gtpc, p_pfcp=>p_pfcp, p_bssgp=>p_bssgp, p_other=>p_other,
      dgram=>dgram, dgram_len=>dgram_len, valid=>valid
    );

  -- baca golden.txt ke tabel (mtype -> hexstring)
  process
    file vf : text;
    variable ln : line;
    variable mtype_s : string(1 to 2);
    variable sp : character;
    variable hexbuf : string(1 to 200);
    variable hexlen : integer;
    variable c : character;
    variable ok : boolean;

    -- ambil byte ke-i (0-based) dari dgram (byte 0 = MSB 543..536)
    function dgram_byte(d : std_logic_vector(543 downto 0); i : integer)
      return std_logic_vector is
    begin
      return d(543 - i*8 downto 536 - i*8);
    end function;

    -- konversi 1 hex char -> 4-bit
    function hex2nib(ch : character) return std_logic_vector is
    begin
      case ch is
        when '0' => return "0000"; when '1' => return "0001";
        when '2' => return "0010"; when '3' => return "0011";
        when '4' => return "0100"; when '5' => return "0101";
        when '6' => return "0110"; when '7' => return "0111";
        when '8' => return "1000"; when '9' => return "1001";
        when 'a'|'A' => return "1010"; when 'b'|'B' => return "1011";
        when 'c'|'C' => return "1100"; when 'd'|'D' => return "1101";
        when 'e'|'E' => return "1110"; when 'f'|'F' => return "1111";
        when others => return "XXXX";
      end case;
    end function;

    procedure drive_and_check(this_type : std_logic_vector(7 downto 0);
                              golden_hex : string; golden_len : integer) is
      variable nbytes : integer := golden_len / 2;
      variable exp_byte : std_logic_vector(7 downto 0);
      variable got_byte : std_logic_vector(7 downto 0);
      variable mism : integer := 0;
    begin
      msg_type <= this_type;
      start <= '1';
      wait until rising_edge(clk);
      start <= '0';
      wait until rising_edge(clk);   -- output register settle
      wait for 1 ns;

      assert to_integer(unsigned(dgram_len)) = nbytes
        report "LEN MISMATCH type=" & integer'image(to_integer(unsigned(this_type))) &
               " got=" & integer'image(to_integer(unsigned(dgram_len))) &
               " want=" & integer'image(nbytes) severity error;

      for i in 0 to nbytes-1 loop
        exp_byte := hex2nib(golden_hex(i*2+1)) & hex2nib(golden_hex(i*2+2));
        got_byte := dgram_byte(dgram, i);
        if got_byte /= exp_byte then
          mism := mism + 1;
          report "  byte[" & integer'image(i) & "] got=" &
            integer'image(to_integer(unsigned(got_byte))) & " want=" &
            integer'image(to_integer(unsigned(exp_byte))) severity warning;
        end if;
      end loop;

      if mism = 0 then
        report "PASS type=0x0" & integer'image(to_integer(unsigned(this_type))) &
               " (" & integer'image(nbytes) & "B exact)" severity note;
      else
        fail_count <= fail_count + 1;
        report "FAIL type=0x0" & integer'image(to_integer(unsigned(this_type))) &
               " mismatches=" & integer'image(mism) severity error;
      end if;
    end procedure;

    -- simpan golden per tipe
    variable g01,g02,g03,g04 : string(1 to 200);
    variable l01,l02,l03,l04 : integer := 0;
  begin
    -- reset
    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    -- load golden.txt
    file_open(vf, "fpga/tb/vectors/golden.txt", read_mode);
    while not endfile(vf) loop
      readline(vf, ln);
      read(ln, mtype_s);          -- 2 char type
      read(ln, sp);               -- spasi
      hexlen := 0;
      loop
        read(ln, c, ok);
        exit when not ok;
        hexlen := hexlen + 1;
        hexbuf(hexlen) := c;
      end loop;
      if    mtype_s = "01" then g01(1 to hexlen) := hexbuf(1 to hexlen); l01 := hexlen;
      elsif mtype_s = "02" then g02(1 to hexlen) := hexbuf(1 to hexlen); l02 := hexlen;
      elsif mtype_s = "03" then g03(1 to hexlen) := hexbuf(1 to hexlen); l03 := hexlen;
      elsif mtype_s = "04" then g04(1 to hexlen) := hexbuf(1 to hexlen); l04 := hexlen;
      end if;
    end loop;
    file_close(vf);

    -- ===== drive nilai IDENTIK gen_golden.py =====
    -- 0x01 GLOBAL
    g_ts          <= x"11223344";
    g_total_imsi  <= std_logic_vector(to_unsigned(142, 32));
    g_ul_pps      <= std_logic_vector(to_unsigned(18000, 32));
    g_dl_pps      <= std_logic_vector(to_unsigned(9500, 32));
    g_active_teid <= std_logic_vector(to_unsigned(130, 32));
    g_total_bytes <= x"0000000200000001";
    g_drop        <= std_logic_vector(to_unsigned(7, 32));
    -- 0x02 TEID
    t_teid    <= x"A1B2C3D4";
    t_imsi    <= IMSI16;
    t_qfi     <= std_logic_vector(to_unsigned(7, 8));
    t_state   <= FALCON_ST_ACTIVE;
    t_ul_pkts <= std_logic_vector(to_unsigned(1200, 32));
    t_dl_pkts <= std_logic_vector(to_unsigned(980, 32));
    -- 0x03 EVENT
    e_type <= FALCON_EV_CREATE;
    e_dir  <= FALCON_DIR_UL;
    e_teid <= x"AABBCCDD";
    e_plen <= std_logic_vector(to_unsigned(312, 16));
    e_ts   <= x"55667788";
    -- 0x04 PROTOCOL (basis 10000): 78.20->7820, 9.10->910, 6.40->640, 3.00->300, 3.30->330
    p_gtpu  <= std_logic_vector(to_unsigned(7820, 16));
    p_gtpc  <= std_logic_vector(to_unsigned(910, 16));
    p_pfcp  <= std_logic_vector(to_unsigned(640, 16));
    p_bssgp <= std_logic_vector(to_unsigned(300, 16));
    p_other <= std_logic_vector(to_unsigned(330, 16));
    wait until rising_edge(clk);

    report "=== FALCON telemetry_packer - byte-exact check vs contract.py ===" severity note;
    drive_and_check(FALCON_TYPE_GLOBAL,   g01, l01);
    drive_and_check(FALCON_TYPE_TEID,     g02, l02);
    drive_and_check(FALCON_TYPE_EVENT,    g03, l03);
    drive_and_check(FALCON_TYPE_PROTOCOL, g04, l04);

    if fail_count = 0 then
      report "=== ALL PASS - FPGA packer byte-exact dengan host contract.py ===" severity note;
    else
      report "=== ADA FAIL: " & integer'image(fail_count) & " tipe ===" severity failure;
    end if;
    wait;
  end process;

end architecture sim;
