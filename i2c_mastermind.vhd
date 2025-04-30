library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity i2c_master is
  generic(
    input_clk : integer := 100_000_000;  -- 100 MHz system clock
    bus_clk   : integer := 100_000       -- 100 kHz I²C clock
  );
  port(
    clk       : in  std_logic;               -- 100 MHz clock
    rst       : in  std_logic;               -- active-high reset
    start     : in  std_logic;               -- pulse ‘1’ to begin transaction
    addr      : in  std_logic_vector(6 downto 0);   -- 7-bit I²C address
    rw        : in  std_logic;               -- '0'=write, '1'=read
    data_in   : in  std_logic_vector(7 downto 0);   -- byte to write
    busy      : out std_logic;               -- high while busy
    data_out  : out std_logic_vector(7 downto 0);   -- byte read back
    ack_error : out std_logic;               -- high if NACK detected
    sda       : inout std_logic;             -- I²C data line
    scl       : inout std_logic              -- I²C clock line
  );
end entity;

architecture rtl of i2c_master is
  -- Divider generates 1/4-cycle phases of SCL
  constant divider : integer := (input_clk / bus_clk) / 4;

  type state_type is (
    ready, start_bit, command, slv_ack1,
    wr_byte, rd_byte, slv_ack2, mstr_ack, stop_bit
  );
  signal state      : state_type := ready;
  signal count      : integer range 0 to divider*4 := 0;
  signal scl_int    : std_logic := 'Z';
  signal data_clk   : std_logic := '0';
  signal scl_ena    : std_logic := '0';
  signal sda_int    : std_logic := '1';
  signal sda_ena_n  : std_logic := '1';

  signal addr_rw    : std_logic_vector(7 downto 0);
  signal data_tx    : std_logic_vector(7 downto 0);
  signal data_rx    : std_logic_vector(7 downto 0);
  signal bit_cnt    : integer range 0 to 7 := 7;
  signal stretch    : std_logic := '0';
begin

  -- Clock and data-phase generator
  process(clk, rst)
  begin
    if rst = '1' then
      count   <= 0;
      stretch <= '0';
    elsif rising_edge(clk) then
      if count = divider*4-1 then
        count <= 0;
      elsif stretch = '0' then
        count <= count + 1;
      end if;
      case count is
        when 0 to divider-1 =>
          scl_int  <= '0';
          data_clk <= '0';
        when divider to divider*2-1 =>
          scl_int  <= '0';
          data_clk <= '1';
        when divider*2 to divider*3-1 =>
          scl_int  <= 'Z';
          data_clk <= '1';
          if scl = '0' then
            stretch <= '1';
          else
            stretch <= '0';
          end if;
        when others =>
          scl_int  <= 'Z';
          data_clk <= '0';
      end case;
    end if;
  end process;

  -- Main I²C state machine
  process(data_clk, rst)
  begin
    if rst = '1' then
      state     <= ready;
      busy      <= '0';
      bit_cnt   <= 7;
      data_rd   <= (others => '0');
      addr_rw   <= (others => '0');
      data_tx   <= (others => '0');
      ack_error <= '0';
      scl_ena   <= '0';
      sda_int   <= '1';
    elsif data_clk'event and data_clk = '1' then
      case state is
        when ready =>
          busy <= '0';
          if start = '1' then
            busy    <= '1';
            addr_rw <= addr & rw;
            data_tx <= data_in;
            bit_cnt <= 7;
            state   <= start_bit;
          end if;

        when start_bit =>
          busy    <= '1';
          scl_ena <= '1';
          sda_int <= addr_rw(bit_cnt);
          state   <= command;

        when command =>
          if bit_cnt = 0 then
            sda_int <= '1';  -- release SDA for ACK
            bit_cnt <= 7;
            state   <= slv_ack1;
          else
            bit_cnt <= bit_cnt - 1;
            sda_int <= addr_rw(bit_cnt-1);
          end if;

        when slv_ack1 =>
          if addr_rw(0) = '0' then  -- write
            sda_int <= data_tx(bit_cnt);
            state   <= wr_byte;
          else                     -- read
            sda_int <= '1';         -- release SDA
            state   <= rd_byte;
          end if;

        when wr_byte =>
          if bit_cnt = 0 then
            sda_int <= '1';
            bit_cnt <= 7;
            state   <= slv_ack2;
          else
            bit_cnt <= bit_cnt - 1;
            sda_int <= data_tx(bit_cnt-1);
          end if;

        when rd_byte =>
          if bit_cnt = 0 then
            -- send NACK (sda_int='1') before stop
            data_rx(bit_cnt) <= sda;
            data_out        <= data_rx;
            state           <= mstr_ack;
            bit_cnt         <= 7;
          else
            data_rx(bit_cnt) <= sda;
            bit_cnt          <= bit_cnt - 1;
          end if;

        when slv_ack2 =>
          scl_ena <= '0';
          state   <= stop_bit;

        when mstr_ack =>
          scl_ena <= '0';
          state   <= stop_bit;

        when stop_bit =>
          scl_ena <= '0';
          busy    <= '0';
          state   <= ready;

        when others =>
          state <= ready;
      end case;
    end if;
  end process;

  -- ACK & data sampling on SCL falling edge
  process(data_clk, rst)
  begin
    if rst = '1' then
      ack_error <= '0';
    elsif data_clk'event and data_clk = '0' then
      case state is
        when slv_ack1 | slv_ack2 =>
          ack_error <= ack_error or sda;
        when rd_byte =>
          null; -- bits already captured above
        when others =>
          null;
      end case;
    end if;
  end process;

  -- Drive SDA/SCL pins
  scl <= scl_int when scl_ena = '1' else 'Z';
  sda <= '0'      when sda_ena_n = '0' else 'Z';

  -- SDA enable logic for start/stop bits
  with state select
    sda_ena_n <=
      data_clk when start_bit |
                  stop_bit |
                  command |
                  wr_byte |
                  slv_ack1 |
                  slv_ack2 |
                  mstr_ack,
      '1'       when others;

end architecture rtl;
