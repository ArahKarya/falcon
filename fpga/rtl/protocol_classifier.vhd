--============================================================================
-- protocol_classifier.vhd — klasifikasi paket berdasar UDP port
--
-- Kombinatorial murni: dari src/dst UDP port -> kelas protokol (3-bit).
-- Dipakai stats_counter untuk distribusi protokol (telemetry 0x04).
--   GTP-U 2152 · GTP-C 2123 · PFCP 8805 · BSSGP 23000(placeholder) · else OTHER
--============================================================================
library ieee;
use ieee.std_logic_1164.all;

library work;
use work.falcon_pkg.all;

entity protocol_classifier is
  port (
    valid_in  : in  std_logic;                      -- paket valid utk diklasifikasi
    udp_sport : in  std_logic_vector(15 downto 0);
    udp_dport : in  std_logic_vector(15 downto 0);
    cls       : out std_logic_vector(2 downto 0);    -- CLS_* dari falcon_pkg
    cls_valid : out std_logic
  );
end entity protocol_classifier;

architecture rtl of protocol_classifier is
  function match(p : std_logic_vector(15 downto 0);
                 s : std_logic_vector(15 downto 0);
                 d : std_logic_vector(15 downto 0)) return boolean is
  begin
    return (s = p) or (d = p);
  end function;
begin
  process(valid_in, udp_sport, udp_dport)
  begin
    cls_valid <= valid_in;
    if    match(PORT_GTPU,  udp_sport, udp_dport) then cls <= CLS_GTPU;
    elsif match(PORT_GTPC,  udp_sport, udp_dport) then cls <= CLS_GTPC;
    elsif match(PORT_PFCP,  udp_sport, udp_dport) then cls <= CLS_PFCP;
    elsif match(PORT_BSSGP, udp_sport, udp_dport) then cls <= CLS_BSSGP;
    else                                               cls <= CLS_OTHER;
    end if;
  end process;
end architecture rtl;
