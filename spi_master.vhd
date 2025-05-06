library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_master_adxl345 is
  port (
    iclk      : in  std_logic;  -- 4 MHz system clock
    reset     : in  std_logic;  -- synchronous, active-high
    miso      : in  std_logic;  -- from ADXL345
    sclk      : out std_logic;  -- to ADXL345, 1 MHz, CPOL=1
    mosi      : out std_logic;  -- to ADXL345
    cs        : out std_logic;  -- active-low chip-select
    acl_data  : out std_logic_vector(47 downto 0); -- {X[15:0], Y, Z}
    spi_busy  : out std_logic   -- high whenever CS='0'
  );
end spi_master_adxl345;

architecture rtl of spi_master_adxl345 is

  -- delay counts for ≈11.1 ms (44400@4 MHz) and ≈10 ms (40000@4 MHz)
  constant POWERUP_DELAY_CYCLES : integer := 44400;
  constant DATA_READY_DELAY_CYCLES : integer := 40000;

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
  signal state  : state_t := POWERUP_DELAY;

  -- Counters
  signal delay_cnt   : integer range 0 to POWERUP_DELAY_CYCLES := 0;
  signal bit_cnt     : integer range 0 to 7 := 7;
  signal byte_cnt    : integer range 0 to 6 := 0;

  -- SCLK generation (divide by 2 toggles every other iclk => 1 MHz)
  signal div2        : std_logic := '0';
  signal sclk_reg    : std_logic := '1';
  signal sclk_prev   : std_logic := '1';

  -- TX/RX shift registers
  signal tx_shift    : std_logic_vector(7 downto 0) := (others => '0');
  signal rx_shift    : std_logic_vector(7 downto 0) := (others => '0');

  -- Accumulators for X, Y, Z
  signal x_data, y_data, z_data : std_logic_vector(15 downto 0) := (others => '0');

begin

  -- outputs
  sclk     <= sclk_reg;
  spi_busy <= not cs;           -- busy whenever CS=0

  --------------------------------------------------------------------------
  -- Main synchronous process: generates SCLK, detects its edges, and
  -- runs the SPI state machine all on the 4 MHz clock.
  --------------------------------------------------------------------------
  process(iclk)
    variable falling_edge_sclk : boolean;
    variable rising_edge_sclk  : boolean;
  begin
    if rising_edge(iclk) then
      if reset = '1' then
        -- reset everything
        state       <= POWERUP_DELAY;
        delay_cnt   <= 0;
        cs          <= '1';
        mosi        <= '0';
        div2        <= '0';
        sclk_reg    <= '1';
        sclk_prev   <= '1';
        bit_cnt     <= 7;
        byte_cnt    <= 0;
        tx_shift    <= (others => '0');
        rx_shift    <= (others => '0');
        x_data      <= (others => '0');
        y_data      <= (others => '0');
        z_data      <= (others => '0');
        acl_data    <= (others => '0');
      else
        -- 1) SCLK generation / idle behavior
        sclk_prev <= sclk_reg;
        if cs = '0' then
          -- in a transaction: toggle every other iclk => 1 MHz
          if div2 = '1' then
            div2     <= '0';
            sclk_reg <= not sclk_reg;
          else
            div2 <= '1';
          end if;
        else
          -- idle: SCLK stays high (CPOL=1)
          div2     <= '0';
          sclk_reg <= '1';
        end if;

        -- detect edges
        falling_edge_sclk := (sclk_prev = '1' and sclk_reg = '0');
        rising_edge_sclk  := (sclk_prev = '0' and sclk_reg = '1');

        -- 2) SPI state machine
        case state is

          ------------------------------------------------------------
          when POWERUP_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < POWERUP_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= 0;
              state     <= WRITE_POWER_CTL_CMD;
            end if;

          ------------------------------------------------------------
          when WRITE_POWER_CTL_CMD =>
            cs <= '0';
            -- on first entry: load command 0x2D
            if delay_cnt = 0 then
              tx_shift  <= x"2D";  
              bit_cnt   <= 7;
              delay_cnt <= 1;     -- mark started
            end if;
            if falling_edge_sclk then
              mosi <= tx_shift(bit_cnt);
              if bit_cnt = 0 then
                state <= WRITE_POWER_CTL_DATA;
                delay_cnt <= 0;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

          ------------------------------------------------------------
          when WRITE_POWER_CTL_DATA =>
            cs <= '0';
            -- load the data byte 0x08
            if delay_cnt = 0 then
              tx_shift  <= x"08";
              bit_cnt   <= 7;
              delay_cnt <= 1;
            end if;
            if falling_edge_sclk then
              mosi <= tx_shift(bit_cnt);
              if bit_cnt = 0 then
                state <= WAIT_WRITE_COMPLETE;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

          ------------------------------------------------------------
          when WAIT_WRITE_COMPLETE =>
            -- wait for the final rising edge, then deassert CS
            if rising_edge_sclk then
              cs    <= '1';
              state <= POST_WRITE_DELAY;
              delay_cnt <= 0;
            end if;

          ------------------------------------------------------------
          when POST_WRITE_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < DATA_READY_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= 0;
              state     <= READ_DATA_CMD;
            end if;

          ------------------------------------------------------------
          when READ_DATA_CMD =>
            cs <= '0';
            if delay_cnt = 0 then
              tx_shift  <= x"F2";  -- 1111_0010: R/W=1, MB=1, Addr=0x32
              bit_cnt   <= 7;
              delay_cnt <= 1;
            end if;
            if falling_edge_sclk then
              mosi <= tx_shift(bit_cnt);
              if bit_cnt = 0 then
                state    <= READ_DATA_BYTES;
                byte_cnt <= 0;
                bit_cnt  <= 7;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

          ------------------------------------------------------------
          when READ_DATA_BYTES =>
            cs <= '0';
            -- drive MOSI low during data‐in
            if falling_edge_sclk then
              mosi <= '0';
              if bit_cnt = 0 then
                bit_cnt  <= 7;
                byte_cnt <= byte_cnt + 1;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;
            -- sample MISO on rising edge
            if rising_edge_sclk then
              rx_shift(bit_cnt) <= miso;
              -- when full byte received, latch into X/Y/Z
              if bit_cnt = 0 then
                case byte_cnt is
                  when 1 => x_data(15 downto 8) <= rx_shift;
                  when 3 => y_data(15 downto 8) <= rx_shift;
                  when 5 => z_data(15 downto 8) <= rx_shift;
                  when others =>
                    if byte_cnt = 0 then       x_data(7 downto 0) <= rx_shift;
                    elsif byte_cnt = 2 then    y_data(7 downto 0) <= rx_shift;
                    elsif byte_cnt = 4 then    z_data(7 downto 0) <= rx_shift;
                    end if;
                end case;
              end if;
            end if;
            -- after 6 bytes, move on
            if byte_cnt = 6 and bit_cnt = 0 and rising_edge_sclk then
              state <= WAIT_READ_COMPLETE;
            end if;

          ------------------------------------------------------------
          when WAIT_READ_COMPLETE =>
            cs <= '1';
            -- pack and present new data
            acl_data <= x_data & y_data & z_data;
            if rising_edge_sclk then
              state <= POST_READ_DELAY;
              delay_cnt <= 0;
            end if;

          ------------------------------------------------------------
          when POST_READ_DELAY =>
            cs   <= '1';
            mosi <= '0';
            if delay_cnt < DATA_READY_DELAY_CYCLES - 1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= 0;
              state <= READ_DATA_CMD;  -- loop back
            end if;

        end case;
      end if;
    end if;
  end process;

end rtl;
