-- Created by Gemini
-- Based on Verilog code by David J. Marion
-- Adapted for ADXL345 based on datasheet
-- Date: May 6, 2025
-- For Zybo Z7 Accelerometer Reading

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; -- Required for unsigned types and arithmetic
-- use ieee.std_logic_unsigned.all; -- Alternative for arithmetic with std_logic_vector (if preferred) - numeric_std is generally preferred

entity spi_master is
    port (
        iclk       : in  std_logic; -- 4MHz clock input
        reset      : in  std_logic; -- Synchronous reset input
        miso       : in  std_logic; -- SPI Master In Slave Out
        sclk       : out std_logic; -- SPI Serial Clock (1MHz generated internally)
        mosi       : out std_logic; -- SPI Master Out Slave In
        cs         : out std_logic; -- SPI Chip Select (active low)
        acl_data   : out std_logic_vector(47 downto 0); -- Output accelerometer data (X[15:0], Y[15:0], Z[15:0])
        spi_busy   : out std_logic -- Indicates if SPI is busy
    );
end entity spi_master;

architecture behavioral of spi_master is

    -- Internal signal for the generated 1MHz SCLK
    signal sclk_control : std_logic := '0';
    -- Corrected 1MHz SCLK generation from 4MHz iclk (divide by 4)
    signal sclk_div_counter : unsigned(1 downto 0) := (others => '0');
    signal sclk_reg_int : std_logic := '0';

    -- Constants for ADXL345 commands and register addresses
    -- First byte format: R/W (1 bit), MB (1 bit), Address (6 bits)
    constant ADXL345_WRITE : std_logic := '0';
    constant ADXL345_READ  : std_logic := '1';
    constant ADXL345_SINGLE_BYTE : std_logic := '0';
    constant ADXL345_MULTI_BYTE  : std_logic := '1';

    constant POWER_CTL_ADDR : std_logic_vector(5 downto 0) := "101101"; -- 0x2D
    constant DATAX0_ADDR    : std_logic_vector(5 downto 0) := "110010"; -- 0x32

    -- Data byte to write to POWER_CTL to enable measurement mode (Measure bit D3 = 1)
    -- Assuming other bits are 0 for simplicity. Refer to datasheet for other POWER_CTL bits.
    constant POWER_CTL_MEASURE_EN : std_logic_vector(7 downto 0) := x"08";

    -- Internal registers to hold received data (16 bits per axis for ADXL345)
    signal X_data : std_logic_vector(15 downto 0) := (others => '0');
    signal Y_data : std_logic_vector(15 downto 0) := (others => '0');
    signal Z_data : std_logic_vector(15 downto 0) := (others => '0');

    -- State machine sync counter (running at 4MHz)
    -- Used for timing delays. 4000 ticks per ms at 4MHz.
    signal counter : unsigned(31 downto 0) := (others => '0');

    -- State Machine States
    type spi_state is (
        POWER_UP_DELAY,     -- Wait for sensor power-up
        BEGIN_WRITE_POWER_CTL, -- Start writing to POWER_CTL
        SEND_POWER_CTL_CMD, -- Send command byte for POWER_CTL
        SEND_POWER_CTL_DATA, -- Send data byte for POWER_CTL
        END_WRITE_POWER_CTL,   -- End write transaction
        WAIT_FOR_DATA_READY, -- Wait for data to be ready (based on ODR)
        BEGIN_READ_DATA,    -- Start reading data registers
        SEND_READ_DATA_CMD, -- Send command byte for DATAX0 (multi-byte read)
        RECEIVE_DATA_BYTES, -- Receive all 6 data bytes
        END_READ_DATA       -- End read transaction
    );
    signal state_reg : spi_state := POWER_UP_DELAY; -- Initial state

    -- Signals for SPI communication
    signal spi_tx_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_rx_byte : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_bit_counter : unsigned(2 downto 0) := (others => '0'); -- 0 to 7 for 8 bits
    signal spi_byte_counter : unsigned(2 downto 0) := (others => '0'); -- 0 to 5 for 6 data bytes + command/address byte

    signal mosi_reg : std_logic := '0';
    signal cs_reg : std_logic := '1'; -- Chip Select starts high (inactive)

    -- Signal to indicate SPI busy status
    signal spi_busy_reg : std_logic := '0';

begin

    -- Assign outputs
    sclk <= '0' when sclk_control = '0' else sclk_reg_int;
    mosi <= mosi_reg;
    cs   <= cs_reg;
    -- Concatenate X, Y, Z data for output
    acl_data <= X_data & Y_data & Z_data;
    spi_busy <= spi_busy_reg; -- Assign the internal busy signal to the output

    -- Corrected 1MHz SCLK generation from 4MHz iclk (divide by 4)
    process (iclk)
    begin
        if rising_edge(iclk) then
            sclk_div_counter <= sclk_div_counter + 1;
            -- Corrected toggle points for 1MHz from 4MHz
            if sclk_div_counter = to_unsigned(1, 2) or sclk_div_counter = to_unsigned(3, 2) then -- Toggle at count 1 and 3 (0,1,2,3 sequence)
                 sclk_reg_int <= not sclk_reg_int;
            end if;
        end if;
    end process;

    -- SPI Communication Process (Handles SCLK, MOSI, MISO shifting)
    -- Implements SPI Mode 1 (CPOL=1, CPHA=1)
    process (sclk_reg_int, reset)
    begin
        if reset = '1' then
            mosi_reg <= '0';
            spi_tx_byte <= (others => '0');
            spi_rx_byte <= (others => '0');
            spi_bit_counter <= (others => '0');
        elsif rising_edge(sclk_reg_int) then -- Sample MISO on rising edge (CPHA=1)
            spi_rx_byte(7 - to_integer(spi_bit_counter)) <= miso;
            if spi_bit_counter = to_unsigned(7, 3) then -- Correct comparison with unsigned literal
                spi_bit_counter <= (others => '0');
            else
                spi_bit_counter <= spi_bit_counter + 1;
            end if;
        elsif falling_edge(sclk_reg_int) then -- Change MOSI on falling edge (CPHA=1)
             mosi_reg <= spi_tx_byte(7 - to_integer(spi_bit_counter));
        end if;
    end process;

    -- State Machine Process
    process (iclk, reset)
    begin
        if reset = '1' then
            state_reg <= POWER_UP_DELAY;
            counter <= (others => '0');
            cs_reg <= '1';
            sclk_control <= '0';
            spi_byte_counter <= (others => '0');
            X_data <= (others => '0');
            Y_data <= (others => '0');
            Z_data <= (others => '0');
            spi_busy_reg <= '0'; -- Reset busy signal
        elsif rising_edge(iclk) then
            counter <= counter + 1; -- Increment state machine sync counter

            case state_reg is
                when POWER_UP_DELAY =>
                    spi_busy_reg <= '0'; -- Not busy during initial delay
                    -- Wait for power-up time (approx. 11.1ms at 100Hz ODR = 11.1 * 4000 = 44400 ticks)
                    -- Adjust this value based on your chosen ODR and ADXL345 datasheet.
                    if counter = to_unsigned(44400 - 1, 32) then
                        counter <= (others => '0'); -- Reset counter for next stage
                        state_reg <= BEGIN_WRITE_POWER_CTL;
                    end if;

                when BEGIN_WRITE_POWER_CTL =>
                    spi_busy_reg <= '1'; -- SPI is busy
                    cs_reg <= '0'; -- Activate Chip Select
                    sclk_control <= '1'; -- Enable SCLK generation
                    -- Prepare command byte for writing to POWER_CTL (R/W=0, MB=0, Address=0x2D)
                    spi_tx_byte <= ADXL345_WRITE & ADXL345_SINGLE_BYTE & POWER_CTL_ADDR;
                    spi_byte_counter <= to_unsigned(0, 3); -- Start with command byte (Corrected type)
                    state_reg <= SEND_POWER_CTL_CMD;

                when SEND_POWER_CTL_CMD =>
                     spi_busy_reg <= '1'; -- SPI is busy
                     -- Wait for 8 SCLK cycles to send command byte
                     if spi_bit_counter = to_unsigned(7, 3) and rising_edge(sclk_reg_int) then -- After 8 bits are shifted out (Corrected comparison)
                         spi_tx_byte <= POWER_CTL_MEASURE_EN; -- Prepare data byte
                         state_reg <= SEND_POWER_CTL_DATA;
                         spi_bit_counter <= to_unsigned(0, 3); -- Reset bit counter for next byte (Corrected type)
                     end if;

                when SEND_POWER_CTL_DATA =>
                    spi_busy_reg <= '1'; -- SPI is busy
                    -- Wait for 8 SCLK cycles to send data byte
                    if spi_bit_counter = to_unsigned(7, 3) and rising_edge(sclk_reg_int) then -- After 8 bits are shifted out (Corrected comparison)
                        state_reg <= END_WRITE_POWER_CTL;
                    end if;

                when END_WRITE_POWER_CTL =>
                    spi_busy_reg <= '0'; -- SPI is no longer busy
                    cs_reg <= '1'; -- Deactivate Chip Select
                    sclk_control <= '0'; -- Disable SCLK
                    -- Wait for tCS,DIS (min 150ns, let's wait a few 4MHz cycles, e.g., 10 cycles = 2.5us)
                    if counter = to_unsigned(10 - 1, 32) then -- Corrected comparison
                        counter <= (others => '0'); -- Reset counter
                        state_reg <= WAIT_FOR_DATA_READY;
                    end if;

                when WAIT_FOR_DATA_READY =>
                    spi_busy_reg <= '0'; -- Not busy during wait
                    -- Wait for data to be ready (approx. 10ms at 100Hz ODR = 10 * 4000 = 40000 ticks)
                    -- A better approach is to use the DATA_READY interrupt.
                    if counter = to_unsigned(40000 - 1, 32) then -- Corrected comparison
                         counter <= (others => '0'); -- Reset counter
                         state_reg <= BEGIN_READ_DATA;
                    end if;

                when BEGIN_READ_DATA =>
                    spi_busy_reg <= '1'; -- SPI is busy
                    cs_reg <= '0'; -- Activate Chip Select
                    sclk_control <= '1'; -- Enable SCLK generation
                    -- Prepare command byte for reading DATAX0 (R/W=1, MB=1, Address=0x32)
                    spi_tx_byte <= ADXL345_READ & ADXL345_MULTI_BYTE & DATAX0_ADDR;
                    spi_byte_counter <= to_unsigned(0, 3); -- Start with command/address byte (Corrected type)
                    state_reg <= SEND_READ_DATA_CMD;

                when SEND_READ_DATA_CMD =>
                    spi_busy_reg <= '1'; -- SPI is busy
                    -- Wait for 8 SCLK cycles to send command/address byte
                    if spi_bit_counter = to_unsigned(7, 3) and rising_edge(sclk_reg_int) then -- After 8 bits are shifted out (Corrected comparison)
                        -- Prepare for receiving data bytes (MOSI can be don't care, send 0s)
                        spi_tx_byte <= (others => '0');
                        spi_byte_counter <= to_unsigned(1, 3); -- Move to first data byte (X LSB) (Corrected type)
                        state_reg <= RECEIVE_DATA_BYTES;
                        spi_bit_counter <= to_unsigned(0, 3); -- Reset bit counter for next byte (Corrected type)
                    end if;

                when RECEIVE_DATA_BYTES =>
                    spi_busy_reg <= '1'; -- SPI is busy
                    -- Receive 6 data bytes (X LSB, X MSB, Y LSB, Y MSB, Z LSB, Z MSB)
                    if spi_bit_counter = to_unsigned(7, 3) and rising_edge(sclk_reg_int) then -- After 8 bits are shifted out (Corrected comparison)
                        -- Store the received byte based on byte counter
                        case spi_byte_counter is
                            when 1 => X_data(7 downto 0) <= spi_rx_byte; -- X LSB
                            when 2 => X_data(15 downto 8) <= spi_rx_byte; -- X MSB
                            when 3 => Y_data(7 downto 0) <= spi_rx_byte; -- Y LSB
                            when 4 => Y_data(15 downto 8) <= spi_rx_byte; -- Y MSB
                            when 5 => Z_data(7 downto 0) <= spi_rx_byte; -- Z LSB
                            when 6 => Z_data(15 downto 8) <= spi_rx_byte; -- Z MSB
                            when others => null; -- Should not happen
                        end case;

                        if spi_byte_counter = to_unsigned(6, 3) then -- After receiving the last data byte (Corrected comparison)
                            state_reg <= END_READ_DATA;
                        else
                            spi_byte_counter <= spi_byte_counter + 1; -- Move to next data byte
                            spi_bit_counter <= to_unsigned(0, 3); -- Reset bit counter for next byte (Corrected type)
                        end if;
                    end if;

                when END_READ_DATA =>
                    spi_busy_reg <= '0'; -- SPI is no longer busy
                    cs_reg <= '1'; -- Deactivate Chip Select
                    sclk_control <= '0'; -- Disable SCLK
                    -- Wait for tCS,DIS (min 150ns, let's wait a few 4MHz cycles, e.g., 10 cycles = 2.5us)
                     if counter = to_unsigned(10 - 1, 32) then -- Corrected comparison
                        counter <= (others => '0'); -- Reset counter
                        state_reg <= WAIT_FOR_DATA_READY; -- Loop back to wait for next data
                    end if;

                when others =>
                    state_reg <= POWER_UP_DELAY; -- Default to initial state

            end case;
        end if;
    end process;

end architecture behavioral;
