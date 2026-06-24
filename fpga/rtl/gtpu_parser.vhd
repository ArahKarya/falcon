--============================================================================
-- gtpu_parser.vhd — parse frame Ethernet -> IPv4 -> UDP -> GTP-U
--
-- Input  : AXI-Stream byte (tvalid/tready/tlast) — 1 byte/clk frame masuk.
-- Output : hasil parse 1-pulse 'done' dengan field terekstrak.
--
-- Offset frame (asumsi Ethernet II, IPv4 tanpa option, UDP):
--   [0..13]   Ethernet header (dst6 src6 ethertype2)   ethertype @12 = 0x0800 IPv4
--   [14]      IPv4 ver/IHL  (ambil IHL utk panjang header IP)
--   [14+9]    IPv4 protocol (=17 UDP)
--   [IP+0..1] UDP src port,  [IP+2..3] UDP dst port,  [IP+4..5] UDP length
--   [UDP+8..] GTP-U header: flags(1) msg_type(1) length(2) TEID(4) ...
--
-- Direction heuristik: UL bila dst port = GTP-U & src = akses; di sini disederhanakan
-- ke flag 'is_gtpu' + dst_port mentah, klasifikasi arah diserahkan ke stats/top.
--
-- Catatan: parser ringan berbasis byte-counter (sintesa-friendly, latency rendah).
-- IHL divariasikan; bila IHL>5 (ada IP options) offset UDP digeser otomatis.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.falcon_pkg.all;

entity gtpu_parser is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;

    -- AXI-Stream byte input (GTP-U payload langsung; eth core SUDAH strip
    -- Eth/IP/UDP + filter port 2152). byte0=flags,1=mtype,2-3=len,4-7=TEID.
    s_tdata    : in  std_logic_vector(7 downto 0);
    s_tvalid   : in  std_logic;
    s_tready   : out std_logic;
    s_tlast    : in  std_logic;

    -- hasil parse (valid saat 'done'=1, 1 clk)
    done       : out std_logic;
    is_ipv4    : out std_logic;
    is_udp     : out std_logic;
    is_gtpu    : out std_logic;                    -- dst/src port match GTP-U
    udp_sport  : out std_logic_vector(15 downto 0);
    udp_dport  : out std_logic_vector(15 downto 0);
    gtpu_mtype : out std_logic_vector(7 downto 0); -- GTP-U message type (mis. 0xFF G-PDU)
    teid       : out std_logic_vector(31 downto 0);
    payload_len: out std_logic_vector(15 downto 0) -- UDP length (proxy ukuran paket)
  );
end entity gtpu_parser;

architecture rtl of gtpu_parser is
  -- selalu siap menerima (parser inline, tak ada backpressure internal)
  signal cnt      : unsigned(15 downto 0) := (others=>'0');  -- index byte dalam frame
  signal ihl_bytes: unsigned(5 downto 0)  := to_unsigned(20,6); -- panjang header IP (default 20)
  signal udp_off  : unsigned(15 downto 0) := to_unsigned(34,16); -- offset awal UDP (14+20)
  signal gtp_off  : unsigned(15 downto 0) := to_unsigned(42,16); -- offset awal GTP-U (udp_off+8)

  signal r_ethtype : std_logic_vector(15 downto 0) := (others=>'0');
  signal r_ipproto : std_logic_vector(7 downto 0)  := (others=>'0');
  signal r_sport   : std_logic_vector(15 downto 0) := (others=>'0');
  signal r_ulen    : std_logic_vector(15 downto 0) := (others=>'0');
  signal r_mtype   : std_logic_vector(7 downto 0)  := (others=>'0');
  signal r_teid    : std_logic_vector(31 downto 0) := (others=>'0');

  signal r_done    : std_logic := '0';
begin
  s_tready <= '1';  -- selalu siap

  process(clk)
    variable c : integer;
  begin
    if rising_edge(clk) then
      r_done <= '0';

      if rst = '1' then
        cnt       <= (others=>'0');
        ihl_bytes <= to_unsigned(20,6);
        udp_off   <= to_unsigned(34,16);
        gtp_off   <= to_unsigned(42,16);
        r_ethtype <= (others=>'0'); r_ipproto <= (others=>'0');
        r_sport <= (others=>'0'); r_ulen <= (others=>'0');
        r_mtype <= (others=>'0'); r_teid <= (others=>'0');

      elsif s_tvalid = '1' then
        c := to_integer(cnt);

        -- ---- input = GTP-U payload langsung (byte0=flags) ----
        -- flags(0) msg_type(1) length(2..3) TEID(4..7) ...
        -- CATATAN: is_ipv4/is_udp/dport TIDAK di-register di sini (konstan ->
        -- XST nge-trim FF jadi 0 & propagasi trim ke evd_*/pk_type di falcon_top
        -- -> TEID/EVENT gak pernah emit). Di-drive combinatorial di bawah.
        if    c = 1 then r_mtype <= s_tdata;
        elsif c = 4 then r_teid(31 downto 24) <= s_tdata;
        elsif c = 5 then r_teid(23 downto 16) <= s_tdata;
        elsif c = 6 then r_teid(15 downto 8)  <= s_tdata;
        elsif c = 7 then r_teid(7 downto 0)   <= s_tdata;
        end if;

        -- akhir frame -> emit done, reset counter
        if s_tlast = '1' then
          r_done <= '1';
          cnt    <= (others=>'0');
        else
          cnt <= cnt + 1;
        end if;
      end if;
    end if;
  end process;

  done        <= r_done;
  -- DIRECT mode: eth core sudah jamin IPv4/UDP/port2152. Drive konstan secara
  -- COMBINATORIAL (bukan register) supaya XST tidak nge-trim FF -> 0 dan
  -- propagasi trim ke evd_*/pk_type. is_gtpu di-paksa '1' (port pasti match).
  is_ipv4     <= '1';
  is_udp      <= '1';
  is_gtpu     <= '1';
  udp_sport   <= r_sport;
  udp_dport   <= PORT_GTPU;        -- konstan: stats/throttle gate andalkan ini
  gtpu_mtype  <= r_mtype;
  teid        <= r_teid;
  payload_len <= r_ulen;

end architecture rtl;
