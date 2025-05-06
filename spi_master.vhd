-- Created by Gemini
-- Based on user's code and previous adaptations for ADXL345
-- Date: May 6, 2025
-- For Zybo Z7 Accelerometer Reading

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; -- Required for unsigned types and arithmetic

entity spi_master_adxl345 is
  port (
    iclk      : in  std_logic;  -- 4 MHz system clock
    reset     : in  std_logic;  -- synchronous, active-high
    miso      : in  std_logic;  -- from ADXL345
    sclk      : out std_logic;  -- to ADXL345, 1 MHz, CPOL=1
    mosi      : out std_logic;  -- to ADXL345
    cs        : out std_logic;  -- active-low chip-select
    acl_data  : out std_logic_vector(47 downto 0); -- {X[15:0], Y, Z}
    spi_busy  : out std_logic   -- high whenever CS='0'
  );
end spi_master_adxl345;

architecture rtl of spi_master_adxl345 is

  -- delay counts for ≈11.1 ms (44400@4 MHz) and ≈10 ms (40000@4 MHz)
  -- Using unsigned constants for consistency with unsigned counters
  constant POWERUP_DELAY_CYCLES : unsigned(31 downto 0) := to_unsigned(44400, 32);
  constant DATA_READY_DELAY_CYCLES : unsigned(31 downto 0) := to_unsigned(40000, 32);

  -- SPI sequence states
  type state_t is (
    POWERUP_DELAY,
    WRITE_POWER_CTL_CMD,
    WRITE_POWER_CTL_DATA,
    WAIT_WRITE_COMPLETE,
    POST_WRITE_DELAY,
    READ_DATA_CMD,
    READ_DATA_BYTES,
    WAIT_READ_COMPLETE,
    POST_READ_DELAY
  );
  signal state  : state_t := POWERUP_DELAY;

  -- Counters (using unsigned types)
  signal delay_cnt   : unsigned(31 downto 0) := (others => '0');
  signal bit_cnt     : unsigned(2 downto 0) := (others => '0'); -- 3 bits for 0 to 7
  signal byte_cnt    : unsigned(2 downto 0) := (others => '0'); -- 3 bits for 0 to 6

  -- Corrected 1MHz SCLK generation (divide by 4)
  signal sclk_div_counter : unsigned(1 downto 0) := (others => '0'); -- 2 bits for 0 to 3
  signal sclk_reg    : std_logic := '1'; -- CPOL=1, starts high
  signal sclk_prev   : std_logic := '1';

  -- TX/RX shift registers
  signal tx_shift    : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_shift    : std_logic_vector(7 downto 0) := (others => '0');

  -- Accumulators for X, Y, Z
  signal x_data, y_data, z_data : std_logic_vector(15 downto 0) := (others => '0');

begin

  -- outputs
  sclk     <= sclk_reg;
  spi_busy <= not cs;           -- busy whenever CS=0

  -- Corrected 1MHz SCLK generation process
  process(iclk)
  begin
    if rising_edge(iclk) then
      sclk_prev <= sclk_reg; -- Capture previous SCLK value for edge detection

      if cs = '0' then -- Only generate SCLK when CS is low
        sclk_div_counter <= sclk_div_counter + 1;
        -- Toggle SCLK at count 1 and 3 of the 2-bit counter (0, 1, 2, 3 sequence)
        if sclk_div_counter = to_unsigned(1, 2) or sclk_div_counter = to_unsigned(3, 2) then
          sclk_reg <= not sclk_reg;
        end if;
      else -- SCLK idles high when CS is high (CPOL=1)
        sclk_reg <= '1';
        sclk_div_counter <= (others => '0'); -- Reset counter when idle
      end if;
    end if;
  end process;


  --------------------------------------------------------------------------
  -- Main synchronous process: runs the SPI state machine and handles
  -- TX/RX shifting based on SCLK edges.
  --------------------------------------------------------------------------
  process(iclk)
    -- Variables for edge detection (evaluated each iclk cycle)
    variable falling_edge_sclk : boolean;
    variable rising_edge_sclk  : boolean;
  begin
    if rising_edge(iclk) then
      -- Detect SCLK edges based on current and previous SCLK values
      falling_edge_sclk := (sclk_prev = '1' and sclk_reg = '0');
      rising_edge_sclk  := (sclk_prev = '0' and sclk_reg = '1');

      if reset = '1' then
        -- reset everything
        state       <= POWERUP_DELAY;
        delay_cnt   <= (others => '0');
        cs          <= '1';
        mosi        <= '0';
        bit_cnt     <= (others => '0');
        byte_cnt    <= (others => '0');
        tx_shift    <= (others => '0');
        rx_shift    <= (others => '0');
        x_data      <= (others => '0');
        y_data      <= (others => '0');
        z_data      <= (others => '0');
        acl_data    <= (others => '0');
      else
        -- 1) SPI TX/RX Shifting (sensitive to SCLK edges)
        if falling_edge_sclk then -- Change MOSI on falling edge (CPHA=1)
          mosi <= tx_shift(to_integer(bit_cnt)); -- Send MSB first
          -- Shift TX data (prepare next bit)
          tx_shift <= tx_shift(6 downto 0) & '0';
        end if;

        if rising_edge_sclk then -- Sample MISO on rising edge (CPHA=1)
          rx_shift(to_integer(bit_cnt)) <= miso; -- Capture incoming data
          -- Shift RX data (prepare next bit)
          rx_shift <= rx_shift(6 downto 0) & '0'; -- This shift is not strictly needed if assigning byte by byte

          -- Increment bit counter after sampling
          if bit_cnt = to_unsigned(7, 3) then
            bit_cnt <= (others => '0');
          else
            bit_cnt <= bit_cnt + 1;
          end if;
        end if;


        -- 2) SPI state machine (sensitive to iclk)
        case state is

          ------------------------------------------------------------
          when POWERUP_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < POWERUP_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= (others => '0');
              state     <= WRITE_POWER_CTL_CMD;
            end if;

          ------------------------------------------------------------
          when WRITE_POWER_CTL_CMD =>
            cs <= '0';
            -- Load command 0x2D on the first iclk cycle of this state
            if delay_cnt = to_unsigned(0, 32) then
              tx_shift  <= x"2D";
              bit_cnt   <= to_unsigned(7, 3); -- Start from MSB
              delay_cnt <= delay_cnt + 1; -- Mark started
            end if;

            -- Transition after sending 8 bits
            if bit_cnt = to_unsigned(0, 3) and rising_edge_sclk then -- After the 8th rising edge
              state <= WRITE_POWER_CTL_DATA;
              delay_cnt <= (others => '0');
            end if;


          ------------------------------------------------------------
          when WRITE_POWER_CTL_DATA =>
            cs <= '0';
            -- Load the data byte 0x08 on the first iclk cycle of this state
            if delay_cnt = to_unsigned(0, 32) then
              tx_shift  <= x"08";
              bit_cnt   <= to_unsigned(7, 3); -- Start from MSB
              delay_cnt <= delay_cnt + 1; -- Mark started
            end if;

            -- Transition after sending 8 bits
            if bit_cnt = to_unsigned(0, 3) and rising_edge_sclk then -- After the 8th rising edge
              state <= WAIT_WRITE_COMPLETE;
            end if;

          ------------------------------------------------------------
          when WAIT_WRITE_COMPLETE =>
            -- wait for the final rising edge to ensure last bit is sampled
            if rising_edge_sclk then
              cs    <= '1'; -- Deassert CS
              state <= POST_WRITE_DELAY;
              delay_cnt <= (others => '0');
            end if;

          ------------------------------------------------------------
          when POST_WRITE_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < DATA_READY_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= (others => '0');
              state     <= READ_DATA_CMD;
            end if;

          ------------------------------------------------------------
          when READ_DATA_CMD =>
            cs <= '0';
            if delay_cnt = to_unsigned(0, 32) then
              tx_shift  <= x"F2";  -- 1111_0010: R/W=1, MB=1, Addr=0x32
              bit_cnt   <= to_unsigned(7, 3); -- Start from MSB
              delay_cnt <= delay_cnt + 1;
            end if;

            -- Transition after sending 8 bits
            if bit_cnt = to_unsigned(0, 3) and rising_edge_sclk then -- After the 8th rising edge
              state    <= READ_DATA_BYTES;
              byte_cnt <= to_unsigned(0, 3); -- Start with byte 0
              bit_cnt  <= to_unsigned(7, 3); -- Start from MSB for receiving
            end if;

          ------------------------------------------------------------
          when READ_DATA_BYTES =>
            cs <= '0';
            -- drive MOSI low during data-in (ADXL345 doesn't read MOSI during read data)
            if falling_edge_sclk then
              mosi <= '0';
            end if;

            -- Sample MISO and process received bytes on rising edge
            if rising_edge_sclk then
              rx_shift(to_integer(bit_cnt)) <= miso; -- Capture incoming data

              -- Check if a full byte has been received
              if bit_cnt = to_unsigned(0, 3) then -- After the 8th bit is sampled
                -- Latch received byte into the appropriate accumulator
                case byte_cnt is
                  when to_unsigned(0, 3) => x_data(7 downto 0) <= rx_shift; -- X LSB
                  when to_unsigned(1, 3) => x_data(15 downto 8) <= rx_shift; -- X MSB
                  when to_unsigned(2, 3) => y_data(7 downto 0) <= rx_shift; -- Y LSB
                  when to_unsigned(3, 3) => y_data(15 downto 8) <= rx_shift; -- Y MSB
                  when to_unsigned(4, 3) => z_data(7 downto 0) <= rx_shift; -- Z LSB
                  when to_unsigned(5, 3) => z_data(15 downto 8) <= rx_shift; -- Z MSB
                  when others => null; -- Should not happen
                end case;

                -- Increment byte counter and reset bit counter for the next byte
                if byte_cnt = to_unsigned(5, 3) then -- After receiving the last byte (6th byte, index 5)
                  state <= WAIT_READ_COMPLETE;
                else
                  byte_cnt <= byte_cnt + 1;
                  bit_cnt  <= to_unsigned(7, 3); -- Reset bit counter to start from MSB for next byte
                end if;
              end if;
            end if;


          ------------------------------------------------------------
          when WAIT_READ_COMPLETE =>
            -- wait for the final rising edge to ensure last bit is sampled
            if rising_edge_sclk then
              cs    <= '1'; -- Deassert CS
              -- pack and present new data (update acl_data after transaction ends)
              acl_data <= x_data & y_data & z_data;
              state <= POST_READ_DELAY;
              delay_cnt <= (others => '0');
            end if;

          ------------------------------------------------------------
          when POST_READ_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < DATA_READY_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= (others => '0');
              state <= READ_DATA_CMD;  -- loop back
            end if;

        end case;
      end if; -- End of reset check
    end if; -- End of rising_edge(iclk)
  end process;

end rtl;
