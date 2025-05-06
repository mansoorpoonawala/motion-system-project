library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spi_master is
  port (
    iclk      : in  std_logic;                     -- 4 MHz system clock
    reset     : in  std_logic;                     -- synchronous, active-high reset
    miso      : in  std_logic;                     -- SPI Master In Slave Out
    sclk      : out std_logic;                     -- SPI Serial Clock (1 MHz)
    mosi      : out std_logic;                     -- SPI Master Out Slave In
    cs        : out std_logic;                     -- SPI Chip Select (active low)
    acl_data  : out std_logic_vector(47 downto 0); -- {X[15:0], Y[15:0], Z[15:0]}
    spi_busy  : out std_logic                      -- high when cs='0'
  );
end entity;

architecture rtl of spi_master is

  -- ADXL345 commands
  constant POWER_CTL_ADDR   : std_logic_vector(5 downto 0) := "101101";  -- 0x2D
  constant WRITE_POWER_CTL  : std_logic_vector(7 downto 0) := "00" & POWER_CTL_ADDR;
  constant POWER_CTL_DATA   : std_logic_vector(7 downto 0) := x"08";
  constant DATAX0_ADDR      : std_logic_vector(5 downto 0) := "110010";  -- 0x32
  constant READ_DATA_BURST  : std_logic_vector(7 downto 0) := "11" & DATAX0_ADDR;

  -- Delays in cycles @4MHz
  constant POWERUP_DELAY    : integer := 44_400;
  constant POSTWRITE_DELAY  : integer := 40_000;
  constant POSTREAD_DELAY   : integer := 40_000;

  -- SPI clock division (4MHz → 1MHz): half-period = 2 cycles
  constant DIV_HALF_PERIOD  : integer := 2;

  -- FSM states
  type state_t is (
    POWERUP, WRITE_CMD, WRITE_DATA,
    WAIT_POSTWRITE, SEND_READ_CMD,
    READ_BYTES, WAIT_POSTREAD
  );
  signal state       : state_t;

  -- internal registers
  signal delay_cnt   : integer range 0 to POWERUP_DELAY;
  signal div_cnt     : integer range 0 to DIV_HALF_PERIOD;
  signal sclk_reg    : std_logic;
  signal cs_reg      : std_logic;
  signal mosi_reg    : std_logic;
  signal bit_cnt     : integer range 0 to 7;
  signal byte_cnt    : integer range 0 to 5;
  signal tx_shift    : std_logic_vector(7 downto 0);
  signal rx_shift    : std_logic_vector(7 downto 0);

  signal x_data, y_data, z_data : std_logic_vector(15 downto 0);

begin
  -- drive ports
  sclk     <= sclk_reg;
  cs       <= cs_reg;
  mosi     <= mosi_reg;
  spi_busy <= not cs_reg;
  acl_data <= x_data & y_data & z_data;

  ----------------------------------------------------------------
  -- single-clock process: reset, clk-div, edge-detect & FSM
  ----------------------------------------------------------------
  process(iclk)
    variable prev_sclk_v       : std_logic := '1';
    variable rising_sclk_edge  : boolean;
    variable falling_sclk_edge : boolean;
  begin
    if rising_edge(iclk) then
      if reset = '1' then
        -- initialize everything
        state     <= POWERUP;
        delay_cnt <= 0;
        div_cnt   <= 0;
        sclk_reg  <= '1';
        cs_reg    <= '1';
        mosi_reg  <= '0';
        bit_cnt   <= 7;
        byte_cnt  <= 0;
        tx_shift  <= (others=>'0');
        rx_shift  <= (others=>'0');
        x_data    <= (others=>'0');
        y_data    <= (others=>'0');
        z_data    <= (others=>'0');
        prev_sclk_v := '1';

      else
        ------------------------------------------------
        -- CLK DIV & CPOL=1 idle
        ------------------------------------------------
        if cs_reg = '0' then
          if div_cnt = DIV_HALF_PERIOD-1 then
            div_cnt  <= 0;
            sclk_reg <= not sclk_reg;
          else
            div_cnt <= div_cnt + 1;
          end if;
        else
          div_cnt  <= 0;
          sclk_reg <= '1';
        end if;

        -- detect edges
        rising_sclk_edge  := (prev_sclk_v = '0' and sclk_reg = '1');
        falling_sclk_edge := (prev_sclk_v = '1' and sclk_reg = '0');
        prev_sclk_v := sclk_reg;

        ------------------------------------------------
        -- MAIN + SPI FSM
        ------------------------------------------------
        case state is

          ----------------------------------------------------------------
          when POWERUP =>
            cs_reg <= '1';
            if delay_cnt < POWERUP_DELAY-1 then
              delay_cnt <= delay_cnt + 1;
            else
              delay_cnt <= 0;
              tx_shift <= WRITE_POWER_CTL;
              bit_cnt  <= 7;
              cs_reg   <= '0';        -- assert
              state    <= WRITE_CMD;
            end if;

          ----------------------------------------------------------------
          when WRITE_CMD =>
            if falling_sclk_edge then
              mosi_reg <= tx_shift(bit_cnt);
              if bit_cnt = 0 then
                tx_shift <= POWER_CTL_DATA;
                bit_cnt  <= 7;
                state    <= WRITE_DATA;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

          ----------------------------------------------------------------
          when WRITE_DATA =>
            if falling_sclk_edge then
              mosi_reg <= tx_shift(bit_cnt);
              if bit_cnt = 0 then
                state <= WAIT_POSTWRITE;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

          ----------------------------------------------------------------
          when WAIT_POSTWRITE =>
            if rising_sclk_edge then
              cs_reg <= '1';         -- deassert
              delay_cnt <= 0;
              state <= SEND_READ_CMD;
            end if;

            -- short dummy wait
            if delay_cnt < POSTWRITE_DELAY-1 then
              delay_cnt <= delay_cnt + 1;
            end if;

          ----------------------------------------------------------------
          when SEND_READ_CMD =>
            tx_shift <= READ_DATA_BURST;
            bit_cnt  <= 7;
            byte_cnt <= 0;
            cs_reg   <= '0';
            state    <= READ_BYTES;

          ----------------------------------------------------------------
          when READ_BYTES =>
            -- drive MOSI low on falling edge
            if falling_sclk_edge then
              mosi_reg <= '0';
              if bit_cnt = 0 then
                bit_cnt <= 7;
                byte_cnt <= byte_cnt + 1;
              else
                bit_cnt <= bit_cnt - 1;
              end if;
            end if;

            -- sample MISO on rising edge
            if rising_sclk_edge then
              rx_shift(bit_cnt) <= miso;
              if bit_cnt = 0 then
                case byte_cnt is
                  when 0 => x_data(7 downto 0)  <= rx_shift;
                  when 1 => x_data(15 downto 8) <= rx_shift;
                  when 2 => y_data(7 downto 0)  <= rx_shift;
                  when 3 => y_data(15 downto 8) <= rx_shift;
                  when 4 => z_data(7 downto 0)  <= rx_shift;
                  when 5 => z_data(15 downto 8) <= rx_shift;
                  when others => null;
                end case;
              end if;
              if byte_cnt = 5 and bit_cnt = 0 then
                cs_reg <= '1';
                delay_cnt <= 0;
                state <= WAIT_POSTREAD;
              end if;
            end if;

          ----------------------------------------------------------------
          when WAIT_POSTREAD =>
            if delay_cnt < POSTREAD_DELAY-1 then
              delay_cnt <= delay_cnt + 1;
            else
              state <= SEND_READ_CMD;  -- loop
            end if;

        end case;
      end if;
    end if;
  end process;

end architecture;



