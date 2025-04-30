library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity oled_driver is
  generic (
    SYS_CLK    : integer := 100_000_000;  -- 100 MHz system clock
    SPI_CLK    : integer :=   1_000_000   -- 1 MHz SPI clock
  );
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;                             -- active-high reset
    axis_x      : in  std_logic_vector(15 downto 0);
    axis_y      : in  std_logic_vector(15 downto 0);
    axis_z      : in  std_logic_vector(15 downto 0);
    spi_mosi    : out std_logic;
    spi_sclk    : out std_logic;
    spi_cs_n    : out std_logic;
    spi_dc      : out std_logic;                             -- '0'=command, '1'=data
    oled_rst_n  : out std_logic                              -- reset for OLED
  );
end entity oled_driver;

architecture rtl of oled_driver is

  -- ===================================================================
  -- Clock divider to generate SPI clock from SYS_CLK
  -- ===================================================================
  constant DIVIDER    : integer := SYS_CLK / (SPI_CLK * 2);
  signal clk_div_cnt  : integer range 0 to DIVIDER := 0;
  signal spi_clk_int  : std_logic := '0';

  -- ===================================================================
  -- SPI shift engine
  -- ===================================================================
  signal shift_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal bit_cnt      : integer range 0 to 7 := 7;
  signal spi_start    : std_logic := '0';

  -- ===================================================================
  -- FSM for initialization & data updates
  -- ===================================================================
  type state_t is (RESET_PULSE, INIT_CMDS, IDLE, SEND_BYTE, WAIT_SPI, DONE);
  signal state        : state_t := RESET_PULSE;
  signal cmd_index    : integer := 0;
  constant N_INIT     : integer := 4;
  type cmd_array_t is array(0 to N_INIT-1) of std_logic_vector(7 downto 0);
  -- Minimal init sequence (SSD1351, adjust for your OLED):
  constant INIT_CMDS : cmd_array_t := (
    x"AE",  -- DISPLAYOFF
    x"A1",  -- SETREMAP
    x"C8",  -- COMSCANDEC
    x"AF"   -- DISPLAYON
  );

  -- ===================================================================
  -- Data queue: you should fill this dynamically each update
  -- Here we show 12 hex nibbles: 4 for X, 4 for Y, 4 for Z
  -- ===================================================================
  constant N_DATA_BYTES : integer := 12;
  type data_array_t is array(0 to N_DATA_BYTES-1) of std_logic_vector(7 downto 0);
  signal data_queue   : data_array_t := (others => (others => '0'));
  signal data_index   : integer range 0 to N_DATA_BYTES := 0;

  -- Hex-to-ASCII converter
  function hex2asc(nib : std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u : integer := to_integer(unsigned(nib));
    variable out : std_logic_vector(7 downto 0);
  begin
    if u < 10 then
      out := std_logic_vector(to_unsigned(48 + u, 8));  -- '0'..'9'
    else
      out := std_logic_vector(to_unsigned(55 + u, 8));  -- 'A'..'F'
    end if;
    return out;
  end function hex2asc;

begin

  -- Generate SPI clock
  process(clk, rst)
  begin
    if rst = '1' then
      clk_div_cnt <= 0;
      spi_clk_int <= '0';
    elsif rising_edge(clk) then
      if clk_div_cnt = DIVIDER-1 then
        clk_div_cnt <= 0;
        spi_clk_int <= not spi_clk_int;
      else
        clk_div_cnt <= clk_div_cnt + 1;
      end if;
    end if;
  end process;
  spi_sclk <= spi_clk_int;

  -- Always select the OLED
  spi_cs_n <= '0';

  -- Main FSM
  process(clk, rst)
  begin
    if rst = '1' then
      state       <= RESET_PULSE;
      oled_rst_n  <= '0';
      cmd_index   <= 0;
      spi_start   <= '0';
      data_index  <= 0;
    elsif rising_edge(clk) then
      case state is

        -- Hold OLED in reset for a few µs
        when RESET_PULSE =>
          oled_rst_n <= '0';
          if clk_div_cnt = 0 then
            oled_rst_n <= '1';
            state      <= INIT_CMDS;
          end if;

        -- Send initialization commands
        when INIT_CMDS =>
          if cmd_index < N_INIT then
            shift_reg <= INIT_CMDS(cmd_index);
            spi_dc    <= '0';       -- command mode
            spi_start <= '1';
            state     <= SEND_BYTE;
          else
            state <= IDLE;
          end if;

        -- Idle: prepare the next data queue
        when IDLE =>
          -- Build data_queue with ASCII hex of axis_x,y,z
          data_queue(0)  <= hex2asc(axis_x(15 downto 12));
          data_queue(1)  <= hex2asc(axis_x(11 downto  8));
          data_queue(2)  <= hex2asc(axis_x( 7 downto  4));
          data_queue(3)  <= hex2asc(axis_x( 3 downto  0));
          data_queue(4)  <= hex2asc(axis_y(15 downto 12));
          data_queue(5)  <= hex2asc(axis_y(11 downto  8));
          data_queue(6)  <= hex2asc(axis_y( 7 downto  4));
          data_queue(7)  <= hex2asc(axis_y( 3 downto  0));
          data_queue(8)  <= hex2asc(axis_z(15 downto 12));
          data_queue(9)  <= hex2asc(axis_z(11 downto  8));
          data_queue(10) <= hex2asc(axis_z( 7 downto  4));
          data_queue(11) <= hex2asc(axis_z( 3 downto  0));
          data_index     <= 0;
          state          <= SEND_BYTE;

        -- Send either a command or data byte
        when SEND_BYTE =>
          if cmd_index < N_INIT then
            -- still in init sequence?
            -- (we should really track init vs data separately)
            null;
          else
            shift_reg <= data_queue(data_index);
            spi_dc    <= '1';       -- data mode
          end if;
          spi_start <= '1';
          state     <= WAIT_SPI;

        -- Wait for SPI byte to finish shifting out
        when WAIT_SPI =>
          if spi_clk_int = '1' then  -- just after MSB shifts
            if bit_cnt = 0 then
              spi_start <= '0';
              bit_cnt   <= 7;
              if cmd_index < N_INIT then
                cmd_index <= cmd_index + 1;
                state     <= INIT_CMDS;
              else
                if data_index < N_DATA_BYTES-1 then
                  data_index <= data_index + 1;
                  state      <= SEND_BYTE;
                else
                  state <= DONE;
                end if;
              end if;
            else
              bit_cnt <= bit_cnt - 1;
            end if;
          end if;

        when DONE =>
          -- Loop back and update display continuously
          state <= IDLE;

      end case;
    end if;
  end process;

  -- SPI shift register output
  process(spi_clk_int, spi_start)
  begin
    if spi_start = '1' then
      if rising_edge(spi_clk_int) then
        spi_mosi <= shift_reg(bit_cnt);
      end if;
    else
      spi_mosi <= '0';
    end if;
  end process;

end architecture rtl;
