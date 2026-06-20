--============================================================================
-- telemetry_packer.vhd — susun datagram telemetry FALCON (header 4B + payload)
--
-- BYTE-EXACT terhadap host falcon/shared/contract.py.
-- Semua field big-endian. Payload di-pad nol sampai panjang tetap per tipe.
--
-- Antarmuka: register input per tipe + pulse 'start' -> output datagram lengkap
-- pada port 'dgram' (lebar tetap = HDR 4B + payload terbesar 64B = 68B = 544 bit),
-- dengan 'dgram_len' menyatakan byte valid (4+payload). Cocok di-stream ke
-- UDP/MAC core (potong sesuai dgram_len).
--
-- Catatan: fokus modul ini = correctness byte layout (diuji oleh testbench
-- lawan vektor contract.py). Streaming/handshake AXI ada di falcon_top.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.falcon_pkg.all;

entity telemetry_packer is
  port (
    clk        : in  std_logic;
    rst        : in  std_logic;                       -- sync active-high
    -- pilih tipe pesan yang akan dipack
    msg_type   : in  std_logic_vector(7 downto 0);
    start      : in  std_logic;                       -- pulse 1-clk

    -- ---- field 0x01 GLOBAL ----
    g_ts          : in std_logic_vector(31 downto 0);
    g_total_imsi  : in std_logic_vector(31 downto 0);
    g_ul_pps      : in std_logic_vector(31 downto 0);
    g_dl_pps      : in std_logic_vector(31 downto 0);
    g_active_teid : in std_logic_vector(31 downto 0);
    g_total_bytes : in std_logic_vector(63 downto 0);
    g_drop        : in std_logic_vector(31 downto 0);

    -- ---- field 0x02 PER-TEID ----
    t_teid     : in std_logic_vector(31 downto 0);
    t_imsi     : in std_logic_vector(127 downto 0);   -- 16 byte ASCII (sudah dipad nol di luar)
    t_qfi      : in std_logic_vector(7 downto 0);
    t_state    : in std_logic_vector(7 downto 0);
    t_ul_pkts  : in std_logic_vector(31 downto 0);
    t_dl_pkts  : in std_logic_vector(31 downto 0);

    -- ---- field 0x03 EVENT ----
    e_type     : in std_logic_vector(7 downto 0);
    e_dir      : in std_logic_vector(7 downto 0);
    e_teid     : in std_logic_vector(31 downto 0);
    e_plen     : in std_logic_vector(15 downto 0);
    e_ts       : in std_logic_vector(31 downto 0);

    -- ---- field 0x04 PROTOCOL (basis 10000) ----
    p_gtpu     : in std_logic_vector(15 downto 0);
    p_gtpc     : in std_logic_vector(15 downto 0);
    p_pfcp     : in std_logic_vector(15 downto 0);
    p_bssgp    : in std_logic_vector(15 downto 0);
    p_other    : in std_logic_vector(15 downto 0);

    -- ---- output ----
    dgram      : out std_logic_vector(543 downto 0);  -- 68 byte, MSB = byte ke-0 (header)
    dgram_len  : out std_logic_vector(15 downto 0);   -- byte valid (4 + payload)
    valid      : out std_logic                        -- 1-clk pulse saat dgram siap
  );
end entity telemetry_packer;

architecture rtl of telemetry_packer is
  -- 68 byte = 544 bit. Byte 0 = MSB (543 downto 536).
  signal dgram_r : std_logic_vector(543 downto 0);
  signal len_r   : unsigned(15 downto 0);
  signal valid_r : std_logic;

  -- helper: pad payload ke 'total' byte (nol di sisi LSB)
  function pad_to(payload : std_logic_vector; total_bytes : natural)
    return std_logic_vector is
    variable total_bits : natural := total_bytes * 8;
    variable r : std_logic_vector(total_bits-1 downto 0) := (others => '0');
  begin
    -- payload di MSB, sisanya nol
    r(total_bits-1 downto total_bits-payload'length) := payload;
    return r;
  end function;

  -- bingkai datagram lengkap: header(32) + payload(pad) -> kiri-rata di 544 bit
  function frame(msg_type : std_logic_vector(7 downto 0);
                 len_payload : natural;
                 payload_padded : std_logic_vector)  -- len_payload*8 bit
    return std_logic_vector is
    variable full   : std_logic_vector(543 downto 0) := (others => '0');
    variable nbits  : natural := 32 + len_payload*8;
    variable packed : std_logic_vector(32 + len_payload*8 - 1 downto 0);
  begin
    packed := falcon_header(msg_type, len_payload) & payload_padded;
    full(543 downto 543 - nbits + 1) := packed;  -- byte-0 di MSB
    return full;
  end function;

begin

  process(clk)
    -- payload sementara per tipe (sebelum pad)
    variable pl_global : std_logic_vector(FALCON_LEN_GLOBAL*8-1 downto 0);
    variable pl_teid   : std_logic_vector(FALCON_LEN_TEID*8-1 downto 0);
    variable pl_event  : std_logic_vector(FALCON_LEN_EVENT*8-1 downto 0);
    variable pl_proto  : std_logic_vector(FALCON_LEN_PROTOCOL*8-1 downto 0);
    -- body 'berisi' (sebelum pad nol) sesuai contract.py
    variable body_global : std_logic_vector(32*8-1 downto 0);  -- 32B isi
    variable body_teid   : std_logic_vector(30*8-1 downto 0);  -- 30B isi
    variable body_event  : std_logic_vector(12*8-1 downto 0);  -- 12B isi
    variable body_proto  : std_logic_vector(10*8-1 downto 0);  -- 10B isi
  begin
    if rising_edge(clk) then
      valid_r <= '0';
      if rst = '1' then
        dgram_r <= (others => '0');
        len_r   <= (others => '0');
      elsif start = '1' then
        case msg_type is

          --------------------------------------------------------------------
          -- 0x01 GLOBAL  (contract: >IIIIIQI = ts,imsi,ul,dl,teid,bytes(u64),drop)
          --------------------------------------------------------------------
          when FALCON_TYPE_GLOBAL =>
            body_global := g_ts & g_total_imsi & g_ul_pps & g_dl_pps &
                           g_active_teid & g_total_bytes & g_drop;  -- 4+4+4+4+4+8+4 = 32B
            pl_global := pad_to(body_global, FALCON_LEN_GLOBAL);
            dgram_r <= frame(FALCON_TYPE_GLOBAL, FALCON_LEN_GLOBAL, pl_global);
            len_r   <= to_unsigned(FALCON_HDR_LEN + FALCON_LEN_GLOBAL, 16);
            valid_r <= '1';

          --------------------------------------------------------------------
          -- 0x02 PER-TEID (contract: >I16sBBII = teid,imsi[16],qfi,state,ul,dl)
          --------------------------------------------------------------------
          when FALCON_TYPE_TEID =>
            body_teid := t_teid & t_imsi & t_qfi & t_state & t_ul_pkts & t_dl_pkts; -- 4+16+1+1+4+4 = 30B
            pl_teid := pad_to(body_teid, FALCON_LEN_TEID);
            dgram_r <= frame(FALCON_TYPE_TEID, FALCON_LEN_TEID, pl_teid);
            len_r   <= to_unsigned(FALCON_HDR_LEN + FALCON_LEN_TEID, 16);
            valid_r <= '1';

          --------------------------------------------------------------------
          -- 0x03 EVENT (contract: >BBIHI = type,dir,teid,plen,ts)
          --------------------------------------------------------------------
          when FALCON_TYPE_EVENT =>
            body_event := e_type & e_dir & e_teid & e_plen & e_ts;  -- 1+1+4+2+4 = 12B
            pl_event := pad_to(body_event, FALCON_LEN_EVENT);
            dgram_r <= frame(FALCON_TYPE_EVENT, FALCON_LEN_EVENT, pl_event);
            len_r   <= to_unsigned(FALCON_HDR_LEN + FALCON_LEN_EVENT, 16);
            valid_r <= '1';

          --------------------------------------------------------------------
          -- 0x04 PROTOCOL (contract: >HHHHH = gtp_u,gtp_c,pfcp,bssgp,other)
          --------------------------------------------------------------------
          when FALCON_TYPE_PROTOCOL =>
            body_proto := p_gtpu & p_gtpc & p_pfcp & p_bssgp & p_other;  -- 5*2 = 10B
            pl_proto := pad_to(body_proto, FALCON_LEN_PROTOCOL);
            dgram_r <= frame(FALCON_TYPE_PROTOCOL, FALCON_LEN_PROTOCOL, pl_proto);
            len_r   <= to_unsigned(FALCON_HDR_LEN + FALCON_LEN_PROTOCOL, 16);
            valid_r <= '1';

          when others =>
            -- tipe tak dikenal: jangan emit
            null;
        end case;
      end if;
    end if;
  end process;

  dgram     <= dgram_r;
  dgram_len <= std_logic_vector(len_r);
  valid     <= valid_r;

end architecture rtl;
