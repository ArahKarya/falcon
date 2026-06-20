--============================================================================
-- stats_counter.vhd — akumulasi statistik global & distribusi protokol
--
-- Tiap pancaran (pulse) paket terklasifikasi: tambah counter sesuai kelas &
-- arah, akumulasi byte. Counter protokol (5 kelas) jadi basis telemetry 0x04.
-- Global counter (ul/dl packet, total bytes, drop) jadi basis 0x01.
--
-- 'sample' (mis. tiap 1 detik dari timer eksternal) mem-latch snapshot ke
-- output dan (opsional) reset rate counter — di sini snapshot saja, reset rate
-- dikelola top via 'rate_clear'.
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.falcon_pkg.all;

entity stats_counter is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;

    -- input per paket
    pkt_valid   : in  std_logic;                      -- 1-pulse: ada paket
    pkt_dir     : in  std_logic;                      -- 0=UL 1=DL
    pkt_bytes   : in  std_logic_vector(15 downto 0);  -- ukuran paket (UDP len proxy)
    pkt_drop    : in  std_logic;                      -- 1-pulse: paket drop/error
    cls         : in  std_logic_vector(2 downto 0);   -- kelas protokol (CLS_*)
    cls_valid   : in  std_logic;

    rate_clear  : in  std_logic;                      -- reset counter rate (pps) per interval

    -- output akumulasi (untuk packer)
    ul_pps      : out std_logic_vector(31 downto 0);
    dl_pps      : out std_logic_vector(31 downto 0);
    total_bytes : out std_logic_vector(63 downto 0);
    drop_count  : out std_logic_vector(31 downto 0);
    -- distribusi protokol (count mentah per kelas; konversi % di top/host)
    c_gtpu      : out std_logic_vector(31 downto 0);
    c_gtpc      : out std_logic_vector(31 downto 0);
    c_pfcp      : out std_logic_vector(31 downto 0);
    c_bssgp     : out std_logic_vector(31 downto 0);
    c_other     : out std_logic_vector(31 downto 0)
  );
end entity stats_counter;

architecture rtl of stats_counter is
  signal ul_r, dl_r, drop_r            : unsigned(31 downto 0) := (others=>'0');
  signal bytes_r                       : unsigned(63 downto 0) := (others=>'0');
  signal gu, gc, pf, bs, ot            : unsigned(31 downto 0) := (others=>'0');
begin
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        ul_r<=(others=>'0'); dl_r<=(others=>'0'); drop_r<=(others=>'0');
        bytes_r<=(others=>'0');
        gu<=(others=>'0'); gc<=(others=>'0'); pf<=(others=>'0');
        bs<=(others=>'0'); ot<=(others=>'0');
      else
        -- reset rate counter per interval (akumulasi byte & drop tetap)
        if rate_clear = '1' then
          ul_r <= (others=>'0');
          dl_r <= (others=>'0');
        end if;

        if pkt_valid = '1' then
          if pkt_dir = '0' then ul_r <= ul_r + 1; else dl_r <= dl_r + 1; end if;
          bytes_r <= bytes_r + resize(unsigned(pkt_bytes), 64);
        end if;

        if pkt_drop = '1' then
          drop_r <= drop_r + 1;
        end if;

        if cls_valid = '1' then
          case cls is
            when CLS_GTPU  => gu <= gu + 1;
            when CLS_GTPC  => gc <= gc + 1;
            when CLS_PFCP  => pf <= pf + 1;
            when CLS_BSSGP => bs <= bs + 1;
            when others    => ot <= ot + 1;
          end case;
        end if;
      end if;
    end if;
  end process;

  ul_pps      <= std_logic_vector(ul_r);
  dl_pps      <= std_logic_vector(dl_r);
  total_bytes <= std_logic_vector(bytes_r);
  drop_count  <= std_logic_vector(drop_r);
  c_gtpu      <= std_logic_vector(gu);
  c_gtpc      <= std_logic_vector(gc);
  c_pfcp      <= std_logic_vector(pf);
  c_bssgp     <= std_logic_vector(bs);
  c_other     <= std_logic_vector(ot);

end architecture rtl;
