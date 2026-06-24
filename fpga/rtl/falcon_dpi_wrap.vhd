--============================================================================
-- falcon_dpi_wrap.vhd — Fase 1.5 REFACTOR B (all-VHDL)
--
-- Port 1:1 dari falcon_dpi_wrap.v (Verilog) -> VHDL native, supaya boundary
-- mixed-lang VHDL<->Verilog HILANG sepenuhnya. Sebelumnya:
--     fpga_core(V) -> wrap(V) -> falcon_top(VHDL)   [2 boundary, XST trim]
-- Sekarang:
--     fpga_core(V) -> falcon_dpi_wrap(VHDL) -> falcon_top(VHDL)  [1 boundary,
--     falcon_top native VHDL-to-VHDL, no cross-lang trim]
--
-- Isi: timer emit 1Hz (GLOBAL+PROTO) + falcon_top + dgram_serializer (di-port
-- ke VHDL inline). Logika & fix Fase 1.5 dipertahankan persis:
--   - dgram_start = tx_valid LEVEL (bukan rising-edge) — tangkap back-to-back
--   - serializer pending-latch 1-deep — datagram ke-2/3 tak hilang saat busy
--
-- Bahasa: VHDL-93 (ISE/XST 14.7).
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity falcon_dpi_wrap is
  generic (
    EMIT_DIV : unsigned(31 downto 0) := to_unsigned(125_000_000, 32)  -- 1Hz @125MHz
  );
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;

    -- RX: UDP payload GTP-U (tap dari eth core, port 2152)
    rx_tdata   : in  std_logic_vector(7 downto 0);
    rx_tvalid  : in  std_logic;
    rx_tready  : out std_logic;
    rx_tlast   : in  std_logic;

    -- TX: telemetry AXIS byte (ke UDP TX eth core, dest :50000)
    tx_tdata   : out std_logic_vector(7 downto 0);
    tx_tvalid  : out std_logic;
    tx_tready  : in  std_logic;
    tx_tlast   : out std_logic;
    tx_busy    : out std_logic;
    tx_sof     : out std_logic;   -- FIX: pulse 1-cyc tiap datagram baru mulai (header trigger)
    tx_len_o   : out std_logic_vector(15 downto 0);   -- FIX: len datagram aktif (utk tx_udp_length)

    -- status / debug
    dbg_teid   : out std_logic_vector(31 downto 0);
    dbg_emit   : out std_logic
  );
end entity falcon_dpi_wrap;

architecture rtl of falcon_dpi_wrap is

  component falcon_top is
    port (
      clk          : in  std_logic;
      rst          : in  std_logic;
      rx_tdata     : in  std_logic_vector(7 downto 0);
      rx_tvalid    : in  std_logic;
      rx_tready    : out std_logic;
      rx_tlast     : in  std_logic;
      emit_global  : in  std_logic;
      emit_proto   : in  std_logic;
      emit_teid    : in  std_logic;
      emit_event   : in  std_logic;
      ev_type      : in  std_logic_vector(7 downto 0);
      ev_dir       : in  std_logic_vector(7 downto 0);
      ev_teid      : in  std_logic_vector(31 downto 0);
      ev_plen      : in  std_logic_vector(15 downto 0);
      ev_ts        : in  std_logic_vector(31 downto 0);
      auto_event   : in  std_logic;
      pkt_done     : out std_logic;
      pkt_teid_o   : out std_logic_vector(31 downto 0);
      ts_now       : in  std_logic_vector(31 downto 0);
      total_imsi   : in  std_logic_vector(31 downto 0);
      active_teid  : in  std_logic_vector(31 downto 0);
      rate_clear   : in  std_logic;
      tx_dgram     : out std_logic_vector(543 downto 0);
      tx_len       : out std_logic_vector(15 downto 0);
      tx_valid     : out std_logic
    );
  end component;

  -- ---- timer emit 1Hz ----
  signal emit_cnt    : unsigned(31 downto 0) := (others => '0');
  signal emit_global : std_logic := '0';
  signal emit_proto  : std_logic := '0';
  signal ts_counter  : unsigned(31 downto 0) := (others => '0');

  -- ---- falcon_top interface ----
  signal tx_dgram    : std_logic_vector(543 downto 0);
  signal tx_dlen     : std_logic_vector(15 downto 0);
  signal tx_dvalid   : std_logic;
  signal dgram_start : std_logic;
  signal pkt_done    : std_logic;
  signal pkt_teid    : std_logic_vector(31 downto 0);

  -- ---- serializer state (di-port dari dgram_serializer.v) ----
  signal buf_dgram   : std_logic_vector(543 downto 0) := (others => '0');
  signal byte_idx    : unsigned(15 downto 0) := (others => '0');
  signal byte_cnt    : unsigned(15 downto 0) := (others => '0');
  signal pend_dgram  : std_logic_vector(543 downto 0) := (others => '0');
  signal pend_len    : unsigned(15 downto 0) := (others => '0');
  signal pend_valid  : std_logic := '0';

  signal s_tdata     : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tvalid    : std_logic := '0';
  signal s_tlast     : std_logic := '0';
  signal s_busy      : std_logic := '0';
  signal s_sof       : std_logic := '0';   -- start-of-frame pulse

  -- byte ke-n (0=MSB) dari buffer: bit (543 - n*8 downto 536 - n*8)
  function get_byte(v : std_logic_vector(543 downto 0); n : unsigned(15 downto 0))
    return std_logic_vector is
    variable hi : integer;
  begin
    hi := 543 - to_integer(n) * 8;
    return v(hi downto hi - 7);
  end function;

begin

  -- =========================================================================
  -- timer emit 1Hz
  -- =========================================================================
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        emit_cnt    <= (others => '0');
        emit_global <= '0';
        emit_proto  <= '0';
        ts_counter  <= (others => '0');
      else
        emit_global <= '0';
        emit_proto  <= '0';
        if emit_cnt >= EMIT_DIV then
          emit_cnt    <= (others => '0');
          ts_counter  <= ts_counter + 1;
          emit_global <= '1';                 -- pulse GLOBAL tiap detik
        else
          emit_cnt <= emit_cnt + 1;
          if emit_cnt = ('0' & EMIT_DIV(31 downto 1)) then  -- EMIT_DIV >> 1
            emit_proto <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  -- =========================================================================
  -- falcon_top (VHDL native — no cross-lang boundary)
  -- =========================================================================
  -- dgram_start = tx_valid LEVEL (Fase 1.5 fix: jangan rising-edge)
  dgram_start <= tx_dvalid;

  u_falcon : falcon_top
    port map (
      clk         => clk,
      rst         => rst,
      rx_tdata    => rx_tdata,
      rx_tvalid   => rx_tvalid,
      rx_tready   => rx_tready,
      rx_tlast    => rx_tlast,
      emit_global => emit_global,
      emit_proto  => emit_proto,
      emit_teid   => '0',
      emit_event  => '0',
      ev_type     => (others => '0'),
      ev_dir      => (others => '0'),
      ev_teid     => (others => '0'),
      ev_plen     => (others => '0'),
      ev_ts       => (others => '0'),
      auto_event  => '0',
      pkt_done    => pkt_done,
      pkt_teid_o  => pkt_teid,
      ts_now      => std_logic_vector(ts_counter),
      total_imsi  => (others => '0'),
      active_teid => (others => '0'),
      rate_clear  => '0',
      tx_dgram    => tx_dgram,
      tx_len      => tx_dlen,
      tx_valid    => tx_dvalid
    );

  -- =========================================================================
  -- serializer dgram -> AXIS byte (di-port dari dgram_serializer.v)
  --   pending-latch 1-deep + level-start (fix Fase 1.5 dipertahankan)
  -- =========================================================================
  process(clk)
    variable v_len : unsigned(15 downto 0);
  begin
    if rising_edge(clk) then
      s_sof <= '0';   -- default, pulse 1 cycle
      if rst = '1' then
        s_tvalid   <= '0';
        s_tlast    <= '0';
        s_busy     <= '0';
        byte_idx   <= (others => '0');
        byte_cnt   <= (others => '0');
        s_tdata    <= (others => '0');
        pend_valid <= '0';
        pend_dgram <= (others => '0');
        pend_len   <= (others => '0');
      else
        v_len := unsigned(tx_dlen);

        -- tangkap start saat busy ke pending bila slot kosong
        if (dgram_start = '1') and (v_len /= 0) and (pend_valid = '0') and (s_busy = '1') then
          pend_dgram <= tx_dgram;
          pend_len   <= v_len;
          pend_valid <= '1';
        end if;

        if s_busy = '0' then
          s_tvalid <= '0';
          s_tlast  <= '0';
          if (dgram_start = '1') and (v_len /= 0) then
            buf_dgram <= tx_dgram;
            byte_cnt  <= v_len;
            byte_idx  <= (others => '0');
            s_busy    <= '1';
            s_sof     <= '1';   -- FIX: header trigger per datagram
            s_tdata   <= tx_dgram(543 downto 536);   -- byte-0
            s_tvalid  <= '1';
            if v_len = to_unsigned(1, 16) then
              s_tlast <= '1';
            else
              s_tlast <= '0';
            end if;
          elsif pend_valid = '1' then
            buf_dgram <= pend_dgram;
            byte_cnt  <= pend_len;
            byte_idx  <= (others => '0');
            s_busy    <= '1';
            s_sof     <= '1';   -- FIX: header trigger per pending datagram
            s_tdata   <= pend_dgram(543 downto 536);
            s_tvalid  <= '1';
            if pend_len = to_unsigned(1, 16) then
              s_tlast <= '1';
            else
              s_tlast <= '0';
            end if;
            pend_valid <= '0';
          end if;
        else
          -- busy: advance saat handshake (tvalid & tready)
          if (s_tvalid = '1') and (tx_tready = '1') then
            if (byte_idx + 1) >= byte_cnt then
              s_tvalid <= '0';
              s_tlast  <= '0';
              s_busy   <= '0';
            else
              byte_idx <= byte_idx + 1;
              s_tdata  <= get_byte(buf_dgram, byte_idx + 1);
              if (byte_idx + 2) >= byte_cnt then
                s_tlast <= '1';
              else
                s_tlast <= '0';
              end if;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- ---- output assignments ----
  tx_tdata  <= s_tdata;
  tx_tvalid <= s_tvalid;
  tx_tlast  <= s_tlast;
  tx_busy   <= s_busy;
  tx_sof    <= s_sof;
  tx_len_o  <= std_logic_vector(byte_cnt);   -- FIX: len datagram aktif

  dbg_teid  <= tx_dgram(543 downto 512);   -- debug tap
  dbg_emit  <= emit_global or emit_proto;

end architecture rtl;
