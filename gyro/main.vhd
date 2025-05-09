library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top_gyro_zybo is
    Port (
        --------------------------------------------------------------------
        -- 125-MHz system clock
        --------------------------------------------------------------------
        sys_clk : in  std_logic;

        --------------------------------------------------------------------
        -- PMOD-SPI pins (header JC, arrow at V15)
        --------------------------------------------------------------------
        jc_miso  : in  std_logic;                    -- JC3 (T11)
        jc_mosi  : out std_logic;                    -- JC2 (W15)
        jc_sclk  : out std_logic;                    -- JC1 (V15)
        jc_ss_n  : out std_logic_vector(0 downto 0); -- JC4 (T10)

        --------------------------------------------------------------------
        -- Three user LEDs + heartbeat
        --------------------------------------------------------------------
        led_x  : out std_logic; -- LD0 pulses on X-axis change
        led_y  : out std_logic; -- LD1 pulses on Y-axis change
        led_z  : out std_logic; -- LD2 pulses on Z-axis change
        led_hb : out std_logic  -- LD3 slow heartbeat
    );
end top_gyro_zybo;

architecture rtl of top_gyro_zybo is

  ------------------------------------------------------------------
  -- Raw 16-bit angular-rate outputs from the gyro wrapper
  ------------------------------------------------------------------
  signal angular_x, angular_y, angular_z : std_logic_vector(15 downto 0);

  ------------------------------------------------------------------
  -- SPI nets to/from the gyro wrapper
  ------------------------------------------------------------------
  signal sclk_sig : std_logic;
  signal ss_vec   : std_logic_vector(0 downto 0);

  ------------------------------------------------------------------
  -- Pulse generator output (one bit per axis)
  ------------------------------------------------------------------
  signal leds_dbg_sig : std_logic_vector(3 downto 0);

  ------------------------------------------------------------------
  -- Heartbeat divider  (bit 23 toggles at ≈0.7 Hz @125 MHz)
  ------------------------------------------------------------------
  signal hb_div : unsigned(23 downto 0) := (others => '0');

  ------------------------------------------------------------------
  -- Tie gyro-wrapper resets inactive so it runs immediately
  ------------------------------------------------------------------
  constant rst_n : std_logic := '1';

begin

  ------------------------------------------------------------------
  -- Instantiate the L3G4200D Pmod-wrapper (no modifications)
  ------------------------------------------------------------------
  gyro_inst : entity work.pmod_gyro_l3g4200d
    generic map (
      clk_freq  => 125,   -- match your sys_clk
      data_rate => "00",  -- default rate
      bandwidth => "00"   -- default bw
    )
    port map (
      clk             => sys_clk,
      reset_n         => rst_n,
      miso            => jc_miso,
      sclk            => sclk_sig,
      ss_n            => ss_vec,
      mosi            => jc_mosi,
      angular_rate_x  => angular_x,
      angular_rate_y  => angular_y,
      angular_rate_z  => angular_z
    );

  ------------------------------------------------------------------
  -- Drive the PMOD-header pins
  ------------------------------------------------------------------
  jc_sclk <= sclk_sig;  
  jc_ss_n <= ss_vec;     

  ------------------------------------------------------------------
  -- Change-detector: pulses a bit when an axis word changes
  -- Re-use your existing 'acl_ctrl' entity verbatim
  ------------------------------------------------------------------
  ctrl_inst : entity work.gyro_ctrl
    port map (
      clk      => sys_clk,
      reset    => '0',         -- keep LED-pulse FSM in reset-inactive
      x_rate    => angular_x,
      y_rate     => angular_y,
      z_rate   => angular_z,
      leds => leds_dbg_sig
    );

  ------------------------------------------------------------------
  -- Hook up the LEDs
  ------------------------------------------------------------------
  led_x  <= leds_dbg_sig(0);  -- LD0
  led_y  <= leds_dbg_sig(1);  -- LD1
  led_z  <= leds_dbg_sig(2);  -- LD2

  -- slow heartbeat on LD3
  process(sys_clk)
  begin
    if rising_edge(sys_clk) then
      hb_div <= hb_div + 1;
    end if;
  end process;
  led_hb <= hb_div(23);

end architecture rtl;



