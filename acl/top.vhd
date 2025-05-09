-- top_accel.vhd  ── Zybo-Z7  +  ADXL345 PMOD  (axis-change LEDs)
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
  port (
    --------------------------------------------------------------------------
    -- 125-MHz system clock
    --------------------------------------------------------------------------
    sys_clk : in  std_logic;

    --------------------------------------------------------------------------
    -- PMOD-SPI pins (header JC, arrow at V15)
    --------------------------------------------------------------------------
    pmod_miso : in  std_logic;                              -- JC3 (T11)
    pmod_sclk : out std_logic;                              -- JC4 (T10)
    pmod_ss_n : out std_logic_vector(0 downto 0);           -- JC1 (V15)
    pmod_mosi : out std_logic;                              -- JC2 (W15)

    --------------------------------------------------------------------------
    -- Four user LEDs
    --------------------------------------------------------------------------
    led_x  : out std_logic;   -- LD0  flashes on X-axis change
    led_y  : out std_logic;   -- LD1  flashes on Y-axis change
    led_z  : out std_logic;   -- LD2  flashes on Z-axis change
    led_hb : out std_logic    -- LD3  slow heartbeat
  );
end entity top;

architecture rtl of top is
  ------------------------------------------------------------------
  -- Internal SPI nets
  ------------------------------------------------------------------
  signal sclk_sig : std_logic;                       -- SCLK
  signal ss_vec   : std_logic_vector(0 downto 0);    -- 1-bit CS* vector

  ------------------------------------------------------------------
  -- Acceleration buses / debug vector
  ------------------------------------------------------------------
  signal accel_x, accel_y, accel_z : std_logic_vector(15 downto 0);
  signal leds_dbg_sig              : std_logic_vector(3 downto 0);

  ------------------------------------------------------------------
  -- Heartbeat divider  (bit 23 ≈ 0.7 Hz @ 125 MHz)
  ------------------------------------------------------------------
  signal hb_div : unsigned(23 downto 0) := (others => '0');

  -- Resets are forced inactive in this build
  constant rst_n : std_logic := '1';    -- PMOD driver enabled
  constant rst   : std_logic := '0';    -- acl_ctrl not in reset
begin
  --------------------------------------------------------------------------
  -- ADXL345 PMOD driver  (clk_div already 25 inside the component)
  --------------------------------------------------------------------------
  accel_inst : entity work.pmod_accelerometer_adxl345
    generic map (
      clk_freq   => 125,
      data_rate  => "0100",
      data_range => "00")
    port map (
      clk             => sys_clk,
      reset_n         => rst_n,
      miso            => pmod_miso,
      sclk            => sclk_sig,
      ss_n            => ss_vec,
      mosi            => pmod_mosi,
      acceleration_x  => accel_x,
      acceleration_y  => accel_y,
      acceleration_z  => accel_z);

  --------------------------------------------------------------------------
  -- acl_ctrl  - pulses a bit whenever an axis value changes
  --------------------------------------------------------------------------
  ctrl_inst : entity work.acl_ctrl
    port map (
      clk      => sys_clk,
      reset    => rst,
      x_in     => accel_x,
      y_in     => accel_y,
      z_in     => accel_z,
      leds_dbg => leds_dbg_sig);

  --------------------------------------------------------------------------
  -- Drive PMOD header pins
  --------------------------------------------------------------------------
  pmod_sclk <= sclk_sig;
  pmod_ss_n <= ss_vec;          -- ss_vec(0) = chip-select

  --------------------------------------------------------------------------
  -- LEDs
  --------------------------------------------------------------------------
  led_x <= leds_dbg_sig(0);     -- X-axis change
  led_y <= leds_dbg_sig(1);     -- Y-axis change
  led_z <= leds_dbg_sig(2);     -- Z-axis change

  -- slow heartbeat on LD3
  process (sys_clk)
  begin
    if rising_edge(sys_clk) then
      hb_div <= hb_div + 1;
    end if;
  end process;
  led_hb <= hb_div(23);
end architecture rtl;



