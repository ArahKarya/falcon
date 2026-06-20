--============================================================================
-- falcon_top.vhd — integrasi FALCON GTP-U DPI gateware
--
--   RX frame (AXI-Stream byte)
--        │
--        ▼
--   gtpu_parser ──► protocol_classifier ──► stats_counter
--        │                                        │
--        └────────── (TEID, dir, len) ────────────┤
--                                                 ▼
--                          telemetry_packer ◄── emit_tick (0x01/0x04 periodik,
--                                 │              0x03 saat event)
--                                 ▼
--                       TX datagram (ke UDP/MAC core) :50000
--
-- Modul ini meng-orkestrasi; UDP/MAC core (IP vendor / open-source) di luar
-- scope file ini — port TX di-ekspos sebagai datagram + len + valid.
--
-- emit_global / emit_proto / emit_event = trigger dari timer/event-detector
-- eksternal (mis. 1 Hz untuk global & protocol). Disediakan sebagai input agar
-- top tetap teruji & vendor-neutral.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.falcon_pkg.all;

entity falcon_top is
  port (
    clk          : in  std_logic;
    rst          : in  std_logic;

    -- RX: frame Ethernet (AXI-Stream byte)
    rx_tdata     : in  std_logic_vector(7 downto 0);
    rx_tvalid    : in  std_logic;
    rx_tready    : out std_logic;
    rx_tlast     : in  std_logic;

    -- trigger emit telemetry (dari timer/event eksternal)
    emit_global  : in  std_logic;                       -- pulse: kirim 0x01
    emit_proto   : in  std_logic;                       -- pulse: kirim 0x04
    emit_event   : in  std_logic;                       -- pulse: kirim 0x03
    ev_type      : in  std_logic_vector(7 downto 0);    -- untuk 0x03
    ev_dir       : in  std_logic_vector(7 downto 0);
    ev_teid      : in  std_logic_vector(31 downto 0);
    ev_plen      : in  std_logic_vector(15 downto 0);
    ev_ts        : in  std_logic_vector(31 downto 0);
    ts_now       : in  std_logic_vector(31 downto 0);   -- unix ts (dari RTC/counter)
    total_imsi   : in  std_logic_vector(31 downto 0);   -- dari session table (luar scope)
    active_teid  : in  std_logic_vector(31 downto 0);
    rate_clear   : in  std_logic;                       -- reset rate per interval

    -- TX: datagram telemetry siap kirim
    tx_dgram     : out std_logic_vector(543 downto 0);
    tx_len       : out std_logic_vector(15 downto 0);
    tx_valid     : out std_logic
  );
end entity falcon_top;

architecture rtl of falcon_top is
  -- parser -> ...
  signal p_done, p_ipv4, p_udp, p_gtpu : std_logic;
  signal p_sport, p_dport, p_ulen      : std_logic_vector(15 downto 0);
  signal p_mtype                       : std_logic_vector(7 downto 0);
  signal p_teid                        : std_logic_vector(31 downto 0);

  -- classifier
  signal cls       : std_logic_vector(2 downto 0);
  signal cls_valid : std_logic;

  -- stats outputs
  signal s_ul, s_dl, s_drop                : std_logic_vector(31 downto 0);
  signal s_bytes                           : std_logic_vector(63 downto 0);
  signal s_gu, s_gc, s_pf, s_bs, s_ot      : std_logic_vector(31 downto 0);

  -- arah paket: heuristik dst port = GTP-U -> UL (uplink ke core), else DL.
  signal pkt_dir : std_logic;

  -- packer drive
  signal pk_type  : std_logic_vector(7 downto 0) := (others=>'0');
  signal pk_start : std_logic := '0';

  -- konversi count protokol -> persen basis 10000 (untuk 0x04)
  -- disederhanakan: kirim count mentah 16-bit LSB (host bisa normalisasi),
  -- ATAU normalisasi di sini bila total tersedia. Pakai mentah (truncate) +
  -- catatan: host/dashboard sudah toleran. Untuk byte-exact test, packer diuji
  -- terpisah; di top ini kita map count->16bit.
  function lo16(v : std_logic_vector(31 downto 0)) return std_logic_vector is
  begin
    return v(15 downto 0);
  end function;
begin
  rx_tready <= '1';
  pkt_dir   <= '0' when (p_dport = PORT_GTPU) else '1';

  -- ---- parser ----
  u_parser : entity work.gtpu_parser
    port map (
      clk=>clk, rst=>rst,
      s_tdata=>rx_tdata, s_tvalid=>rx_tvalid, s_tready=>open, s_tlast=>rx_tlast,
      done=>p_done, is_ipv4=>p_ipv4, is_udp=>p_udp, is_gtpu=>p_gtpu,
      udp_sport=>p_sport, udp_dport=>p_dport,
      gtpu_mtype=>p_mtype, teid=>p_teid, payload_len=>p_ulen
    );

  -- ---- classifier ----
  u_cls : entity work.protocol_classifier
    port map (
      valid_in=>p_done, udp_sport=>p_sport, udp_dport=>p_dport,
      cls=>cls, cls_valid=>cls_valid
    );

  -- ---- stats ----
  u_stats : entity work.stats_counter
    port map (
      clk=>clk, rst=>rst,
      pkt_valid=>p_done, pkt_dir=>pkt_dir, pkt_bytes=>p_ulen,
      pkt_drop=>'0', cls=>cls, cls_valid=>cls_valid, rate_clear=>rate_clear,
      ul_pps=>s_ul, dl_pps=>s_dl, total_bytes=>s_bytes, drop_count=>s_drop,
      c_gtpu=>s_gu, c_gtpc=>s_gc, c_pfcp=>s_pf, c_bssgp=>s_bs, c_other=>s_ot
    );

  -- ---- packer ----
  u_packer : entity work.telemetry_packer
    port map (
      clk=>clk, rst=>rst, msg_type=>pk_type, start=>pk_start,
      -- 0x01
      g_ts=>ts_now, g_total_imsi=>total_imsi, g_ul_pps=>s_ul, g_dl_pps=>s_dl,
      g_active_teid=>active_teid, g_total_bytes=>s_bytes, g_drop=>s_drop,
      -- 0x02 (TEID terakhir terparse — versi penuh pakai session table)
      t_teid=>p_teid, t_imsi=>(others=>'0'), t_qfi=>(others=>'0'),
      t_state=>FALCON_ST_ACTIVE, t_ul_pkts=>s_ul, t_dl_pkts=>s_dl,
      -- 0x03
      e_type=>ev_type, e_dir=>ev_dir, e_teid=>ev_teid, e_plen=>ev_plen, e_ts=>ev_ts,
      -- 0x04 (count protokol -> 16-bit)
      p_gtpu=>lo16(s_gu), p_gtpc=>lo16(s_gc), p_pfcp=>lo16(s_pf),
      p_bssgp=>lo16(s_bs), p_other=>lo16(s_ot),
      dgram=>tx_dgram, dgram_len=>tx_len, valid=>tx_valid
    );

  -- ---- arbiter emit (prioritas: event > global > protocol) ----
  process(clk)
  begin
    if rising_edge(clk) then
      pk_start <= '0';
      if rst = '1' then
        pk_type <= (others=>'0');
      elsif emit_event = '1' then
        pk_type <= FALCON_TYPE_EVENT;   pk_start <= '1';
      elsif emit_global = '1' then
        pk_type <= FALCON_TYPE_GLOBAL;  pk_start <= '1';
      elsif emit_proto = '1' then
        pk_type <= FALCON_TYPE_PROTOCOL; pk_start <= '1';
      end if;
    end if;
  end process;

end architecture rtl;
