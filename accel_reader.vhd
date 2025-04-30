library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity accel_reader is
  port (
    clk       : in  std_logic;                         -- 100 MHz system clock
    rst       : in  std_logic;                         -- active-high reset
    i2c_scl   : inout std_logic;                       -- PMOD JC SCL
    i2c_sda   : inout std_logic;                       -- PMOD JC SDA
    axis_x    : out std_logic_vector(15 downto 0);     -- X-axis reading
    axis_y    : out std_logic_vector(15 downto 0);     -- Y-axis reading
    axis_z    : out std_logic_vector(15 downto 0);     -- Z-axis reading
    i2c_busy  : out std_logic;                         -- high while I²C transaction
    i2c_err   : out std_logic                          -- high if NACK detected
  );
end entity accel_reader;

architecture Behavioral of accel_reader is

  -- ADXL345 I²C address and register map
  constant ACCEL_I2C_ADDR : std_logic_vector(6 downto 0) := "0011101";  -- 0x1D
  constant REG_X_LSB      : std_logic_vector(7 downto 0) := x"32";
  constant REG_X_MSB      : std_logic_vector(7 downto 0) := x"33";
  constant REG_Y_LSB      : std_logic_vector(7 downto 0) := x"34";
  constant REG_Y_MSB      : std_logic_vector(7 downto 0) := x"35";
  constant REG_Z_LSB      : std_logic_vector(7 downto 0) := x"36";
  constant REG_Z_MSB      : std_logic_vector(7 downto 0) := x"37";

  -- Instantiate I²C master component
  component i2c_master
    generic (
      input_clk : integer := 100_000_000;  -- 100 MHz
      bus_clk   : integer := 100_000       -- 100 kHz
    );
    port (
      clk       : in  std_logic;
      rst       : in  std_logic;
      start     : in  std_logic;
      addr      : in  std_logic_vector(6 downto 0);
      rw        : in  std_logic;
      data_in   : in  std_logic_vector(7 downto 0);
      busy      : out std_logic;
      data_out  : out std_logic_vector(7 downto 0);
      ack_error : out std_logic;
      sda       : inout std_logic;
      scl       : inout std_logic
    );
  end component;

  -- FSM states for reading all 6 axis bytes
  type state_type is (
    IDLE,
    READ_X_L, WAIT_X_L,
    READ_X_M, WAIT_X_M,
    READ_Y_L, WAIT_Y_L,
    READ_Y_M, WAIT_Y_M,
    READ_Z_L, WAIT_Z_L,
    READ_Z_M, WAIT_Z_M
  );
  signal state        : state_type := IDLE;
  signal start_i2c    : std_logic := '0';
  signal reg_addr     : std_logic_vector(7 downto 0) := (others => '0');
  signal data_byte    : std_logic_vector(7 downto 0);
  signal busy_i2c     : std_logic;
  signal err_i2c      : std_logic;

  -- Temporary storage for LSB/MSB of each axis
  signal x_lsb, x_msb : std_logic_vector(7 downto 0);
  signal y_lsb, y_msb : std_logic_vector(7 downto 0);
  signal z_lsb, z_msb : std_logic_vector(7 downto 0);

begin

  -- I²C master instantiation
  U_I2C: i2c_master
    generic map (
      input_clk => 100_000_000,
      bus_clk   => 100_000
    )
    port map (
      clk       => clk,
      rst       => rst,
      start     => start_i2c,
      addr      => ACCEL_I2C_ADDR,
      rw        => '1',           -- always read
      data_in   => (others => '0'),
      busy      => busy_i2c,
      data_out  => data_byte,
      ack_error => err_i2c,
      sda       => i2c_sda,
      scl       => i2c_scl
    );

  -- Control FSM: cycle through all six registers
  process(clk, rst)
  begin
    if rst = '1' then
      state      <= IDLE;
      start_i2c  <= '0';
      x_lsb      <= (others => '0');
      x_msb      <= (others => '0');
      y_lsb      <= (others => '0');
      y_msb      <= (others => '0');
      z_lsb      <= (others => '0');
      z_msb      <= (others => '0');
    elsif rising_edge(clk) then
      -- default: no new start
      start_i2c <= '0';

      case state is
        when IDLE =>
          state <= READ_X_L;

        when READ_X_L =>
          reg_addr    <= REG_X_LSB;
          start_i2c   <= '1';
          state       <= WAIT_X_L;

        when WAIT_X_L =>
          if busy_i2c = '0' then
            x_lsb <= data_byte;
            state <= READ_X_M;
          end if;

        when READ_X_M =>
          reg_addr  <= REG_X_MSB;
          start_i2c <= '1';
          state     <= WAIT_X_M;

        when WAIT_X_M =>
          if busy_i2c = '0' then
            x_msb <= data_byte;
            state <= READ_Y_L;
          end if;

        when READ_Y_L =>
          reg_addr  <= REG_Y_LSB;
          start_i2c <= '1';
          state     <= WAIT_Y_L;

        when WAIT_Y_L =>
          if busy_i2c = '0' then
            y_lsb <= data_byte;
            state <= READ_Y_M;
          end if;

        when READ_Y_M =>
          reg_addr  <= REG_Y_MSB;
          start_i2c <= '1';
          state     <= WAIT_Y_M;

        when WAIT_Y_M =>
          if busy_i2c = '0' then
            y_msb <= data_byte;
            state <= READ_Z_L;
          end if;

        when READ_Z_L =>
          reg_addr  <= REG_Z_LSB;
          start_i2c <= '1';
          state     <= WAIT_Z_L;

        when WAIT_Z_L =>
          if busy_i2c = '0' then
            z_lsb <= data_byte;
            state <= READ_Z_M;
          end if;

        when READ_Z_M =>
          reg_addr  <= REG_Z_MSB;
          start_i2c <= '1';
          state     <= WAIT_Z_M;

        when WAIT_Z_M =>
          if busy_i2c = '0' then
            z_msb <= data_byte;
            state <= IDLE;  -- loop back for continuous updates
          end if;

        when others =>
          state <= IDLE;
      end case;
    end if;
  end process;

  -- Output concatenation and status signals
  axis_x   <= x_msb & x_lsb;
  axis_y   <= y_msb & y_lsb;
  axis_z   <= z_msb & z_lsb;
  i2c_busy <= busy_i2c;
  i2c_err  <= err_i2c;

end architecture Behavioral;
