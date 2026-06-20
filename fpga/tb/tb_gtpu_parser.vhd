--============================================================================
-- tb_gtpu_parser.vhd — feed 1 frame GTP-U sintetis, verifikasi field terparse.
--
-- Frame (Ethernet II / IPv4 IHL=5 / UDP / GTP-U G-PDU):
--   Eth: dst=aabbccddeeff src=112233445566 type=0800
--   IPv4: 45 00 .. proto=11(UDP) .. (20B, IHL=5)
--   UDP: sport=0x0868(2152) dport=0x0868(2152) len=0x0020 csum=0000
--   GTP-U: flags=30 mtype=FF(G-PDU) len=000c TEID=A1B2C3D4 ...
--
-- Cek: is_ipv4=1, is_udp=1, is_gtpu=1, dport=2152, mtype=0xFF, teid=A1B2C3D4.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.falcon_pkg.all;

entity tb_gtpu_parser is
end entity;

architecture sim of tb_gtpu_parser is
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

  type byte_arr is array (natural range <>) of std_logic_vector(7 downto 0);
  -- frame lengkap (54 byte: 14 eth + 20 ip + 8 udp + 12 gtp)
  constant FRAME : byte_arr := (
    -- Ethernet (14)
    x"aa",x"bb",x"cc",x"dd",x"ee",x"ff", x"11",x"22",x"33",x"44",x"55",x"66", x"08",x"00",
    -- IPv4 (20): ver/ihl=45, tos=00, len=0028, id=0000, flags=0000, ttl=40, proto=11, csum=0000, src, dst
    x"45",x"00",x"00",x"28", x"00",x"00",x"00",x"00", x"40",x"11",x"00",x"00",
    x"0a",x"00",x"00",x"01", x"0a",x"00",x"00",x"02",
    -- UDP (8): sport=2152(0868) dport=2152(0868) len=0020 csum=0000
    x"08",x"68", x"08",x"68", x"00",x"20", x"00",x"00",
    -- GTP-U (12): flags=30 mtype=FF len=000c TEID=A1B2C3D4 seq=0000 npdu=00 next=00
    x"30",x"ff",x"00",x"0c", x"a1",x"b2",x"c3",x"d4", x"00",x"00",x"00",x"00"
  );
begin
  clk <= not clk after CLK_PERIOD/2;

  dut : entity work.gtpu_parser
    port map (
      clk=>clk, rst=>rst, s_tdata=>tdata, s_tvalid=>tvalid, s_tready=>open, s_tlast=>tlast,
      done=>done, is_ipv4=>is_ipv4, is_udp=>is_udp, is_gtpu=>is_gtpu,
      udp_sport=>sport, udp_dport=>dport, gtpu_mtype=>mtype, teid=>teid, payload_len=>plen
    );

  process
    procedure chk(name : string; cond : boolean) is
    begin
      if cond then report "PASS " & name severity note;
      else fails <= fails + 1; report "FAIL " & name severity error; end if;
    end procedure;
  begin
    rst <= '1'; wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);

    -- stream frame byte demi byte
    for i in FRAME'range loop
      tdata  <= FRAME(i);
      tvalid <= '1';
      if i = FRAME'high then tlast <= '1'; else tlast <= '0'; end if;
      wait until rising_edge(clk);
    end loop;
    tvalid <= '0'; tlast <= '0';
    wait until rising_edge(clk);
    wait for 1 ns;

    report "=== FALCON gtpu_parser - hasil parse frame GTP-U ===" severity note;
    chk("is_ipv4",      is_ipv4 = '1');
    chk("is_udp",       is_udp  = '1');
    chk("is_gtpu",      is_gtpu = '1');
    chk("dport=2152",   dport = PORT_GTPU);
    chk("sport=2152",   sport = PORT_GTPU);
    chk("mtype=0xFF",   mtype = x"ff");
    chk("teid=A1B2C3D4",teid = x"a1b2c3d4");
    chk("udp_len=0x20", plen = x"0020");

    if fails = 0 then
      report "=== ALL PASS - parser ekstrak field GTP-U benar ===" severity note;
    else
      report "=== ADA FAIL: " & integer'image(fails) severity failure;
    end if;
    wait;
  end process;
end architecture sim;
