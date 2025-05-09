--------------------------------------------------------------------------------
-- motion_top.vhd
-- Top-level that chains acl_top → gyro_top → PmodOLEDCtrl (OLED)
-- With added calibration functionality
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity motion_top is
  port (
    --------------------------------------------------------------------------
    -- System clock & reset
    --------------------------------------------------------------------------
    sys_clk     : in  std_logic;                      -- e.g. 125 MHz
    sys_reset_n : in  std_logic;                      -- active-low reset (BTN0)
    
    --------------------------------------------------------------------------
    -- Calibration controls
    --------------------------------------------------------------------------
    cal_btn     : in  std_logic;                      -- Button to trigger calibration
    cal_en      : in  std_logic;                      -- Switch to enable/disable calibration
    
    --------------------------------------------------------------------------
    -- PMOD-ACCEL SPI interface (to ADXL345)
    --------------------------------------------------------------------------
    pmod_miso   : in  std_logic;
    pmod_sclk   : out std_logic;
    pmod_ss_n   : out std_logic_vector(0 downto 0);
    pmod_mosi   : out std_logic;

    --------------------------------------------------------------------------
    -- PMOD-OLED interface (to OLED display)
    --------------------------------------------------------------------------
    oled_cs     : out std_logic;
    oled_sdin   : out std_logic;
    oled_sclk   : out std_logic;
    oled_dc     : out std_logic;
    oled_res    : out std_logic;
    oled_vbat   : out std_logic;
    oled_vdd    : out std_logic;
    
    --------------------------------------------------------------------------
    -- PMOD-GYRO SPI interface
    --------------------------------------------------------------------------
    jc_miso     : in  std_logic;
    jc_mosi     : out std_logic;
    jc_sclk     : out std_logic;
    jc_ss_n     : out std_logic_vector(0 downto 0)
  );
end entity;

architecture rtl of motion_top is
  -- Raw acceleration and gyro outputs
  signal accel_x, accel_y, accel_z : std_logic_vector(15 downto 0);
  signal gyro_x, gyro_y, gyro_z : std_logic_vector(15 downto 0);
  
  -- Calibrated outputs
  signal cal_accel_x, cal_accel_y, cal_accel_z : std_logic_vector(15 downto 0);
  signal cal_gyro_x, cal_gyro_y, cal_gyro_z : std_logic_vector(15 downto 0);
  
  -- Calibration offsets
  signal accel_x_off, accel_y_off, accel_z_off : signed(15 downto 0) := (others=>'0');
  signal gyro_x_off, gyro_y_off, gyro_z_off : signed(15 downto 0) := (others=>'0');
  
  -- Calibration control signals
  signal cal_btn_r : std_logic := '0';  -- Debounced button
  signal cal_btn_edge : std_logic;      -- Rising edge detection
  signal calibrating : std_logic := '0'; -- Calibration in progress flag
  
  -- Active-high reset for internal modules
  signal reset_pos : std_logic;
begin
  --------------------------------------------------------------------------------
  -- Convert your BTN reset (active-low) to active-high
  --------------------------------------------------------------------------------
  reset_pos <= not sys_reset_n;

  --------------------------------------------------------------------------------
  -- 1) Instantiate the ADXL345 SPI→acceleration core
  --------------------------------------------------------------------------------
  acl_inst : entity work.top
    port map (
      clk     => sys_clk,
      reset   => reset_pos,     -- active-high reset into acl_top
      -- SPI interface to ADXL345 PMOD
      miso    => pmod_miso,
      sclk    => pmod_sclk,
      ss_n    => pmod_ss_n,
      mosi    => pmod_mosi,
      -- Raw 16-bit axis outputs
      x_out   => accel_x,
      y_out   => accel_y,
      z_out   => accel_z
    );

  --------------------------------------------------------------------------------
  -- 2) Instantiate the gyroscope module
  --------------------------------------------------------------------------------
  gyro_inst : entity work.top_gyro_zybo
    port map(
      sys_clk => sys_clk,
      reset   => reset_pos,     -- active-high reset
      -- SPI interface to Gyro PMOD
      jc_miso => jc_miso,
      jc_sclk => jc_sclk,
      jc_ss_n => jc_ss_n,
      jc_mosi => jc_mosi,
      -- Raw 16-bit axis outputs
      x_out   => gyro_x,
      y_out   => gyro_y,
      z_out   => gyro_z
    );

  --------------------------------------------------------------------------------
  -- 3) Calibration logic
  --------------------------------------------------------------------------------
  -- Button debouncing and edge detection
  process(sys_clk)
    variable count : integer range 0 to 125000 := 0; -- Debounce for 1ms at 125MHz
  begin
    if rising_edge(sys_clk) then
      if reset_pos = '1' then
        cal_btn_r <= '0';
        count := 0;
      elsif count = 125000 then
        cal_btn_r <= cal_btn;
        count := 0;
      else
        count := count + 1;
      end if;
    end if;
  end process;

  -- Rising edge detection
  cal_btn_edge <= '1' when cal_btn = '1' and cal_btn_r = '0' else '0';

  -- Capture offset values when calibration button is pressed
  process(sys_clk)
  begin
    if rising_edge(sys_clk) then
      if reset_pos = '1' then
        -- Reset offsets
        accel_x_off <= (others => '0');
        accel_y_off <= (others => '0');
        accel_z_off <= (others => '0');
        gyro_x_off <= (others => '0');
        gyro_y_off <= (others => '0');
        gyro_z_off <= (others => '0');
        calibrating <= '0';
      elsif cal_btn_edge = '1' then
        -- Capture current values as offsets
        accel_x_off <= signed(accel_x);
        accel_y_off <= signed(accel_y);
        accel_z_off <= signed(accel_z);
        gyro_x_off <= signed(gyro_x);
        gyro_y_off <= signed(gyro_y);
        gyro_z_off <= signed(gyro_z);
        calibrating <= '1';
      end if;
    end if;
  end process;

  -- Apply calibration if enabled
  cal_accel_x <= std_logic_vector(signed(accel_x) - accel_x_off) when cal_en = '1' and calibrating = '1' else accel_x;
  cal_accel_y <= std_logic_vector(signed(accel_y) - accel_y_off) when cal_en = '1' and calibrating = '1' else accel_y;
  cal_accel_z <= std_logic_vector(signed(accel_z) - accel_z_off) when cal_en = '1' and calibrating = '1' else accel_z;
  cal_gyro_x <= std_logic_vector(signed(gyro_x) - gyro_x_off) when cal_en = '1' and calibrating = '1' else gyro_x;
  cal_gyro_y <= std_logic_vector(signed(gyro_y) - gyro_y_off) when cal_en = '1' and calibrating = '1' else gyro_y;
  cal_gyro_z <= std_logic_vector(signed(gyro_z) - gyro_z_off) when cal_en = '1' and calibrating = '1' else gyro_z;

  --------------------------------------------------------------------------------
  -- 4) Instantiate the OLED controller, feeding it calibrated sensor data
  --------------------------------------------------------------------------------
  oled_ctrl : entity work.PmodOLEDCtrl
    port map (
      CLK       => sys_clk,
      RST       => reset_pos,     -- active-high reset into OLED ctrl
      -- SPI interface to OLED PMOD
      CS        => oled_cs,
      SDIN      => oled_sdin,
      SCLK      => oled_sclk,
      DC        => oled_dc,
      RES       => oled_res,
      VBAT      => oled_vbat,
      VDD       => oled_vdd,
      -- Calibrated acceleration data
      x_val_acl => cal_accel_x,
      y_val_acl => cal_accel_y,
      z_val_acl => cal_accel_z,
      -- Calibrated gyro data
      x_val_gyro => cal_gyro_x,
      y_val_gyro => cal_gyro_y,
      z_val_gyro => cal_gyro_z,
      -- (you can tie off the demo LEDs inside PmodOLEDCtrl if unused)
      leds      => open
    );

end architecture rtl;
