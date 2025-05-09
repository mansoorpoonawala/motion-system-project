--------------------------------------------------------------------------------
--  acl_top.vhd  - ADXL345 front-end with improved low-pass filter
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
  generic (
    FILTER_SHIFT : natural := 2;   -- Reduced from 4 to 2 (1/4 smoothing instead of 1/16)
    USE_FILTER   : boolean := true  -- Enable/disable filter for debugging
  );
  port (
    --------------------------------------------------------------------------
    -- System
    --------------------------------------------------------------------------
    clk    : in  std_logic;                     -- 125-MHz system clock
    reset  : in  std_logic;                     -- active-high reset

    --------------------------------------------------------------------------
    -- SPI interface to ADXL345 PMOD  (JC header)
    --------------------------------------------------------------------------
    miso   : in  std_logic;
    sclk   : out std_logic;
    ss_n   : out std_logic_vector(0 downto 0);
    mosi   : out std_logic;

    --------------------------------------------------------------------------
    -- Filtered 16-bit acceleration outputs
    --------------------------------------------------------------------------
    x_out  : out std_logic_vector(15 downto 0);
    y_out  : out std_logic_vector(15 downto 0);
    z_out  : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of top is
  ------------------------------------------------------------------
  -- Internal nets
  ------------------------------------------------------------------
  signal sclk_int : std_logic;
  signal ss_vec   : std_logic_vector(0 downto 0);

  signal accel_x, accel_y, accel_z : std_logic_vector(15 downto 0);

  -- active-low reset for the PMOD core
  signal reset_n : std_logic;

  ------------------------------------------------------------------
  -- IIR filter registers  (3 extra bits for head-room)
  ------------------------------------------------------------------
  constant F_WIDTH : natural := 16 + FILTER_SHIFT;  -- Width adjusted based on FILTER_SHIFT
  subtype filt_t   is signed(F_WIDTH-1 downto 0);

  signal xf, yf, zf : filt_t := (others => '0');
  
  -- Raw acceleration values (signed)
  signal x_raw, y_raw, z_raw : signed(15 downto 0);

begin
  --------------------------------------------------------------------------
  -- Reset polarity conversion
  --------------------------------------------------------------------------
  reset_n <= not reset;

  --------------------------------------------------------------------------
  -- 1)  ADXL345 PMOD driver (unchanged)
  --------------------------------------------------------------------------
  accel_inst : entity work.pmod_accelerometer_adxl345
    generic map (
      clk_freq   => 125,
      data_rate  => "0100",  -- 25Hz output rate
      data_range => "00")    -- ±2g range
    port map (
      clk            => clk,
      reset_n        => reset_n,
      miso           => miso,
      sclk           => sclk_int,
      ss_n           => ss_vec,
      mosi           => mosi,
      acceleration_x => accel_x,
      acceleration_y => accel_y,
      acceleration_z => accel_z);

  -- Convert raw acceleration values to signed
  x_raw <= signed(accel_x);
  y_raw <= signed(accel_y);
  z_raw <= signed(accel_z);

  --------------------------------------------------------------------------
  -- 2)  Improved low-pass filter with adaptive smoothing
  --------------------------------------------------------------------------
  process(clk)
    variable dx, dy, dz : filt_t;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        -- Reset filter state
        xf <= (others => '0');
        yf <= (others => '0');
        zf <= (others => '0');
      else
        -- Calculate difference between current reading and filtered value
        dx := resize(x_raw, F_WIDTH) - xf;
        dy := resize(y_raw, F_WIDTH) - yf;
        dz := resize(z_raw, F_WIDTH) - zf;

        -- Apply filter: y(n) = y(n-1) + (x(n) - y(n-1)) >> FILTER_SHIFT
        xf <= xf + (dx srl FILTER_SHIFT);
        yf <= yf + (dy srl FILTER_SHIFT);
        zf <= zf + (dz srl FILTER_SHIFT);
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- 3)  Drive external pins and outputs
  --------------------------------------------------------------------------
  sclk <= sclk_int;
  ss_n <= ss_vec;

  -- Output selection based on USE_FILTER generic
  filter_output: process(accel_x, accel_y, accel_z, xf, yf, zf)
  begin
    if USE_FILTER then
      -- Use filtered outputs
      x_out <= std_logic_vector(xf(F_WIDTH-1 downto FILTER_SHIFT));
      y_out <= std_logic_vector(yf(F_WIDTH-1 downto FILTER_SHIFT));
      z_out <= std_logic_vector(zf(F_WIDTH-1 downto FILTER_SHIFT));
    else
      -- Bypass filter for debugging
      x_out <= accel_x;
      y_out <= accel_y;
      z_out <= accel_z;
    end if;
  end process;

end architecture rtl;


