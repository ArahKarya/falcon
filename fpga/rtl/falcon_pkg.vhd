--============================================================================
-- falcon_pkg.vhd — package konstanta & tipe bersama FALCON FPGA gateware
--
-- Kontrak byte WAJIB sinkron dengan host: falcon/shared/contract.py
-- Semua field telemetry big-endian (network order).
--============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package falcon_pkg is

  -- ---- message type id (header byte 0) ----
  constant FALCON_TYPE_GLOBAL   : std_logic_vector(7 downto 0) := x"01";
  constant FALCON_TYPE_TEID     : std_logic_vector(7 downto 0) := x"02";
  constant FALCON_TYPE_EVENT    : std_logic_vector(7 downto 0) := x"03";
  constant FALCON_TYPE_PROTOCOL : std_logic_vector(7 downto 0) := x"04";
  constant FALCON_PROTO_VERSION : std_logic_vector(7 downto 0) := x"01";

  -- ---- panjang payload (byte) per tipe ----
  constant FALCON_LEN_GLOBAL    : natural := 64;
  constant FALCON_LEN_TEID      : natural := 48;
  constant FALCON_LEN_EVENT     : natural := 32;
  constant FALCON_LEN_PROTOCOL  : natural := 32;
  constant FALCON_HDR_LEN       : natural := 4;

  -- ---- event code (0x03) ----
  constant FALCON_EV_CREATE     : std_logic_vector(7 downto 0) := x"01";
  constant FALCON_EV_DELETE     : std_logic_vector(7 downto 0) := x"02";
  constant FALCON_EV_MODIFY     : std_logic_vector(7 downto 0) := x"03";
  constant FALCON_EV_ERROR      : std_logic_vector(7 downto 0) := x"04";

  -- ---- session state (0x02) ----
  constant FALCON_ST_IDLE       : std_logic_vector(7 downto 0) := x"00";
  constant FALCON_ST_ACTIVE     : std_logic_vector(7 downto 0) := x"01";
  constant FALCON_ST_SUSPENDED  : std_logic_vector(7 downto 0) := x"02";

  -- ---- direction ----
  constant FALCON_DIR_UL        : std_logic_vector(7 downto 0) := x"00";
  constant FALCON_DIR_DL        : std_logic_vector(7 downto 0) := x"01";

  -- ---- UDP port klasifikasi protokol ----
  constant PORT_GTPU   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(2152,  16)); -- TS 29.281
  constant PORT_GTPC   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(2123,  16)); -- TS 29.274
  constant PORT_PFCP   : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(8805,  16)); -- TS 29.244
  constant PORT_BSSGP  : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(23000, 16)); -- placeholder

  -- ---- transport FALCON (sesuai PRD & host) ----
  constant FALCON_TELEMETRY_PORT : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(50000, 16)); -- FPGA -> Host
  constant FALCON_INGEST_PORT    : std_logic_vector(15 downto 0) := std_logic_vector(to_unsigned(9000,  16)); -- Host -> FPGA

  -- ---- klasifikasi protokol (output classifier) ----
  constant CLS_GTPU  : std_logic_vector(2 downto 0) := "000";
  constant CLS_GTPC  : std_logic_vector(2 downto 0) := "001";
  constant CLS_PFCP  : std_logic_vector(2 downto 0) := "010";
  constant CLS_BSSGP : std_logic_vector(2 downto 0) := "011";
  constant CLS_OTHER : std_logic_vector(2 downto 0) := "100";

  -- ---- helper: big-endian header (4B): type | version | length(16) ----
  function falcon_header(msg_type : std_logic_vector(7 downto 0);
                         length    : natural) return std_logic_vector;

end package falcon_pkg;

package body falcon_pkg is

  function falcon_header(msg_type : std_logic_vector(7 downto 0);
                         length    : natural) return std_logic_vector is
    variable hdr : std_logic_vector(31 downto 0);
  begin
    -- byte0=type, byte1=version, byte2..3=length BE
    hdr := msg_type
           & FALCON_PROTO_VERSION
           & std_logic_vector(to_unsigned(length, 16));
    return hdr;  -- 32-bit, MSB-first = big-endian byte order
  end function;

end package body falcon_pkg;
