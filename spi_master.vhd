library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity spi_master is
    Port (
        iclk        : in  std_logic;                     -- Input clock (4MHz)
        reset       : in  std_logic;                     -- Synchronous reset, active high
        miso        : in  std_logic;                     -- SPI Master In Slave Out
        sclk        : out std_logic;                     -- SPI Serial Clock (1MHz)
        mosi        : out std_logic;                     -- SPI Master Out Slave In
        cs          : out std_logic;                     -- SPI Chip Select (active low)
        acl_data    : out std_logic_vector(47 downto 0); -- Concatenated X, Y, Z data
        spi_busy    : out std_logic                      -- SPI busy signal
    );
end spi_master;

architecture Behavioral of spi_master is
    -- Constants for ADXL345 registers and commands
    constant POWER_CTL_ADDR  : std_logic_vector(7 downto 0) := x"2D"; -- POWER_CTL register address
    constant POWER_CTL_DATA  : std_logic_vector(7 downto 0) := x"08"; -- Enable measurement mode
    constant DATAX0_ADDR     : std_logic_vector(7 downto 0) := x"32"; -- Starting address for data registers
    
    -- Command bytes for SPI operations
    -- Write to register: R/W bit (0) & MB bit (0) & Address (6 bits)
    constant WRITE_POWER_CTL : std_logic_vector(7 downto 0) := '0' & '0' & POWER_CTL_ADDR(5 downto 0);
    -- Read from register: R/W bit (1) & MB bit (1) & Address (6 bits)
    constant READ_DATA_BURST : std_logic_vector(7 downto 0) := '1' & '1' & DATAX0_ADDR(5 downto 0);
    
    -- Constants for timing
    constant CLK_DIV_COUNT   : integer := 1; -- For 1MHz SCLK from 4MHz iclk (divide by 4 -> count to 1)
    constant POWER_UP_DELAY  : integer := 44400; -- ~11.1ms at 4MHz clock
    constant DATA_READY_DELAY: integer := 40000; -- ~10ms at 4MHz clock
    constant SAMPLE_DELAY    : integer := 40000; -- ~10ms at 4MHz clock (100Hz ODR)
    
    -- SPI Mode 1: CPOL=1 (clock idles high), CPHA=1 (sample on rising edge)
    
    -- State machine types
    type main_state_type is (
        POWER_UP_WAIT,           -- Wait for ADXL345 to power up
        CONFIG_POWER_CTL,        -- Write to POWER_CTL to enable measurement
        DATA_READY_WAIT,         -- Wait for first data to be ready
        PREPARE_READ,            -- Prepare for reading data
        READ_DATA,               -- Read X, Y, Z data
        SAMPLE_WAIT              -- Wait for next sample period
    );
    
    type spi_state_type is (
        SPI_IDLE,                -- SPI is idle
        SPI_START,               -- Start SPI transaction
        SPI_TRANSFER,            -- Transfer data
        SPI_STOP                 -- Stop SPI transaction
    );
    
    -- Registers
    signal main_state     : main_state_type := POWER_UP_WAIT;
    signal spi_state      : spi_state_type := SPI_IDLE;
    
    signal delay_counter  : integer range 0 to 65535 := 0;
    signal clk_div_counter: integer range 0 to 3 := 0;
    signal bit_counter    : integer range 0 to 7 := 7;
    signal byte_counter   : integer range 0 to 7 := 0;
    
    signal sclk_internal  : std_logic := '1';  -- Start high (CPOL=1)
    signal cs_internal    : std_logic := '1';  -- Start deasserted
    signal mosi_internal  : std_logic := '0';
    
    signal tx_byte        : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_byte        : std_logic_vector(7 downto 0) := (others => '0');
    
    signal x_data         : std_logic_vector(15 downto 0) := (others => '0');
    signal y_data         : std_logic_vector(15 downto 0) := (others => '0');
    signal z_data         : std_logic_vector(15 downto 0) := (others => '0');
    
    signal spi_transaction: std_logic := '0';  -- Flag to indicate SPI transaction type
                                               -- '0' for write, '1' for read
    signal bytes_to_send  : integer range 0 to 7 := 0;
    signal bytes_to_receive : integer range 0 to 7 := 0;
    
begin
    -- Connect internal signals to outputs
    sclk <= sclk_internal;
    cs <= cs_internal;
    mosi <= mosi_internal;
    spi_busy <= not cs_internal;  -- busy when cs is low
    acl_data <= x_data & y_data & z_data;  -- Concatenate X, Y, Z data
    
    -- Main state machine process
    process(iclk)
    begin
        if rising_edge(iclk) then
            if reset = '1' then
                -- Reset state
                main_state <= POWER_UP_WAIT;
                delay_counter <= 0;
                x_data <= (others => '0');
                y_data <= (others => '0');
                z_data <= (others => '0');
            else
                case main_state is
                    when POWER_UP_WAIT =>
                        -- Wait for ADXL345 to power up
                        if delay_counter >= POWER_UP_DELAY - 1 then
                            delay_counter <= 0;
                            main_state <= CONFIG_POWER_CTL;
                        else
                            delay_counter <= delay_counter + 1;
                        end if;
                        
                    when CONFIG_POWER_CTL =>
                        -- Write to POWER_CTL register to enable measurement mode
                        if spi_state = SPI_IDLE and delay_counter = 0 then
                            -- Setup for SPI write transaction
                            spi_transaction <= '0';  -- Write transaction
                            tx_byte <= WRITE_POWER_CTL;
                            bytes_to_send <= 2;  -- Address byte + data byte
                            bytes_to_receive <= 0;
                            delay_counter <= 1;  -- To trigger SPI start on next cycle
                        elsif delay_counter = 1 then
                            delay_counter <= 2;  -- Wait one more cycle
                        elsif delay_counter = 2 then
                            -- Start SPI transaction
                            delay_counter <= 0;
                            main_state <= DATA_READY_WAIT;
                        end if;
                        
                    when DATA_READY_WAIT =>
                        -- Wait for first data to be ready after enabling measurement mode
                        if spi_state = SPI_IDLE then  -- Make sure previous SPI transaction completed
                            if delay_counter >= DATA_READY_DELAY - 1 then
                                delay_counter <= 0;
                                main_state <= PREPARE_READ;
                            else
                                delay_counter <= delay_counter + 1;
                            end if;
                        end if;
                        
                    when PREPARE_READ =>
                        -- Prepare for reading X, Y, Z data
                        if spi_state = SPI_IDLE then
                            -- Setup for SPI read transaction
                            spi_transaction <= '1';  -- Read transaction
                            tx_byte <= READ_DATA_BURST;
                            bytes_to_send <= 1;      -- Command byte only
                            bytes_to_receive <= 6;   -- 6 bytes of data (X, Y, Z)
                            main_state <= READ_DATA;
                        end if;
                        
                    when READ_DATA =>
                        -- Wait for SPI read transaction to complete
                        if spi_state = SPI_IDLE and cs_internal = '1' then
                            main_state <= SAMPLE_WAIT;
                            delay_counter <= 0;
                        end if;
                        
                    when SAMPLE_WAIT =>
                        -- Wait for the next sample period
                        if delay_counter >= SAMPLE_DELAY - 1 then
                            delay_counter <= 0;
                            main_state <= PREPARE_READ;  -- Start next read cycle
                        else
                            delay_counter <= delay_counter + 1;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;
    
    -- SPI state machine process
    process(iclk)
    begin
        if rising_edge(iclk) then
            if reset = '1' then
                -- Reset SPI state
                spi_state <= SPI_IDLE;
                cs_internal <= '1';
                sclk_internal <= '1';  -- Idle high (CPOL=1)
                mosi_internal <= '0';
                bit_counter <= 7;
                byte_counter <= 0;
                clk_div_counter <= 0;
                rx_byte <= (others => '0');
            else
                case spi_state is
                    when SPI_IDLE =>
                        -- Idle state - wait for transaction request
                        cs_internal <= '1';
                        sclk_internal <= '1';  -- Idle high (CPOL=1)
                        
                        -- Check if main state machine requested SPI transaction
                        if (main_state = CONFIG_POWER_CTL and delay_counter = 2) or 
                           (main_state = PREPARE_READ) then
                            spi_state <= SPI_START;
                            bit_counter <= 7;
                            byte_counter <= 0;
                            clk_div_counter <= 0;
                        end if;
                        
                    when SPI_START =>
                        -- Start SPI transaction
                        cs_internal <= '0';  -- Assert CS
                        
                        -- Prepare first bit of data
                        if spi_transaction = '0' then
                            -- For write transaction, first byte is command
                            mosi_internal <= tx_byte(bit_counter);
                        else
                            -- For read transaction, first byte is command
                            mosi_internal <= tx_byte(bit_counter);
                        end if;
                        
                        spi_state <= SPI_TRANSFER;
                        
                    when SPI_TRANSFER =>
                        -- Transfer data bits
                        -- Clock division for SCLK generation
                        if clk_div_counter >= CLK_DIV_COUNT then
                            clk_div_counter <= 0;
                            
                            -- Toggle SCLK
                            sclk_internal <= not sclk_internal;
                            
                            if sclk_internal = '0' then
                                -- Rising edge of SCLK (since we're about to toggle to '1')
                                -- Sample MISO on rising edge (CPHA=1)
                                rx_byte(bit_counter) <= miso;
                                
                                if bit_counter = 0 then
                                    -- Byte complete
                                    bit_counter <= 7;
                                    
                                    -- Process received byte
                                    if spi_transaction = '1' and byte_counter > 0 then
                                        -- Reading data bytes
                                        case byte_counter is
                                            when 1 => -- X LSB
                                                x_data(7 downto 0) <= rx_byte;
                                            when 2 => -- X MSB
                                                x_data(15 downto 8) <= rx_byte;
                                            when 3 => -- Y LSB
                                                y_data(7 downto 0) <= rx_byte;
                                            when 4 => -- Y MSB
                                                y_data(15 downto 8) <= rx_byte;
                                            when 5 => -- Z LSB
                                                z_data(7 downto 0) <= rx_byte;
                                            when 6 => -- Z MSB
                                                z_data(15 downto 8) <= rx_byte;
                                            when others =>
                                                null;
                                        end case;
                                    end if;
                                    
                                    -- Move to next byte or finish
                                    if spi_transaction = '0' then
                                        -- Write transaction
                                        if byte_counter = 0 then
                                            -- First byte sent (command), prepare data byte
                                            byte_counter <= byte_counter + 1;
                                            tx_byte <= POWER_CTL_DATA;
                                        elsif byte_counter >= bytes_to_send - 1 then
                                            -- All bytes sent
                                            spi_state <= SPI_STOP;
                                        else
                                            -- More bytes to send
                                            byte_counter <= byte_counter + 1;
                                        end if;
                                    else
                                        -- Read transaction
                                        if byte_counter >= bytes_to_send + bytes_to_receive - 1 then
                                            -- All bytes received
                                            spi_state <= SPI_STOP;
                                        else
                                            -- More bytes to receive
                                            byte_counter <= byte_counter + 1;
                                        end if;
                                    end if;
                                else
                                    -- Move to next bit
                                    bit_counter <= bit_counter - 1;
                                end if;
                            else
                                -- Falling edge of SCLK (since we're about to toggle to '0')
                                -- Setup next bit on MOSI on falling edge
                                if spi_transaction = '0' then
                                    -- Write transaction
                                    if byte_counter = 0 then
                                        -- Command byte
                                        if bit_counter > 0 then
                                            mosi_internal <= tx_byte(bit_counter - 1);
                                        end if;
                                    else
                                        -- Data byte
                                        if bit_counter > 0 then
                                            mosi_internal <= tx_byte(bit_counter - 1);
                                        end if;
                                    end if;
                                else
                                    -- Read transaction
                                    if byte_counter = 0 then
                                        -- Command byte
                                        if bit_counter > 0 then
                                            mosi_internal <= tx_byte(bit_counter - 1);
                                        else
                                            mosi_internal <= '0';  -- Default to 0 for read data
                                        end if;
                                    else
                                        -- During data read, keep MOSI at 0
                                        mosi_internal <= '0';
                                    end if;
                                end if;
                            end if;
                        else
                            clk_div_counter <= clk_div_counter + 1;
                        end if;
                        
                    when SPI_STOP =>
                        -- Stop SPI transaction
                        cs_internal <= '1';  -- Deassert CS
                        sclk_internal <= '1';  -- Return to idle state (CPOL=1)
                        spi_state <= SPI_IDLE;
                        
                end case;
            end if;
        end if;
    end process;
    
end Behavioral;
