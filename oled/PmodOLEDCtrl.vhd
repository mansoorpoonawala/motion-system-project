library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity PmodOLEDCtrl is
  Port (
    sys_clk   : in  std_logic;  -- 125 MHz input clock
    sys_reset : in  std_logic;  -- active-high synchronous reset

    -- Pmod-OLED JD pins
    oled_res  : out std_logic;  -- JD1
    oled_cs   : out std_logic;  -- JD2
    oled_dc   : out std_logic;  -- JD3
    oled_sclk : out std_logic;  -- JD4
    oled_mosi : out std_logic   -- JD5
  );
end entity;

architecture Behavioral of PmodOLEDCtrl is

  -- divide 125 MHz → ~4 MHz
  signal clk_4MHz : std_logic;

  -- signals for Init block
  signal init_en     : std_logic := '0';
  signal init_done   : std_logic;
  signal init_cs     : std_logic;
  signal init_sdo    : std_logic;
  signal init_sclk   : std_logic;
  signal init_dc     : std_logic;

  -- signals for Example block
  signal example_en   : std_logic := '0';
  signal example_done : std_logic;
  signal example_cs   : std_logic;
  signal example_sdo  : std_logic;
  signal example_sclk : std_logic;
  signal example_dc   : std_logic;

  -- FSM states
  type t_state is (Idle, OledInitialize, OledExample, Done);
  signal state : t_state := Idle;

begin

  --====================================================
  -- 1) Clock divider instance
  --====================================================
  CLK_GEN : entity work.iclk_gen
    port map (
      clk      => sys_clk,
      clk_4MHz => clk_4MHz
    );

  --====================================================
  -- 2) OLED Initialization
  --====================================================
  INIT : entity work.OledInit
    port map (
      CLK   => clk_4MHz,
      RST   => sys_reset,
      EN    => init_en,
      CS    => init_cs,
      SDO   => init_sdo,
      SCLK  => init_sclk,
      DC    => init_dc,
      RES   => oled_res,   -- drive Reset pin
      VBAT  => '1',        -- tie VBAT high (external 3.3 V supply)
      VDD   => '1',        -- tie VDD   high
      FIN   => init_done
    );

  --====================================================
  -- 3) OLED Example (“X: Y: Z:”), hard-coded in OledEx.vhd
  --====================================================
  EXAMPLE : entity work.OledEx
    port map (
      CLK   => clk_4MHz,
      RST   => sys_reset,
      EN    => example_en,
      CS    => example_cs,
      SDO   => example_sdo,
      SCLK  => example_sclk,
      DC    => example_dc,
      FIN   => example_done
    );

  --====================================================
  -- 4) FSM to sequence Init → Example
  --====================================================
  process(clk_4MHz, sys_reset)
  begin
    if sys_reset = '1' then
      state         <= Idle;
      init_en       <= '0';
      example_en    <= '0';
    elsif rising_edge(clk_4MHz) then
      case state is
        when Idle =>
          init_en    <= '1';
          state      <= OledInitialize;

        when OledInitialize =>
          if init_done = '1' then
            init_en     <= '0';
            example_en  <= '1';
            state       <= OledExample;
          end if;

        when OledExample =>
          if example_done = '1' then
            example_en <= '0';
            state      <= Done;
          end if;

        when Done =>
          -- stay here
          null;
      end case;
    end if;
  end process;

  --====================================================
  -- 5) Output MUXes: drive the Pmod pins
  --====================================================
  oled_cs   <= init_cs   when state = OledInitialize else example_cs;
  oled_mosi <= init_sdo  when state = OledInitialize else example_sdo;
  oled_sclk <= init_sclk when state = OledInitialize else example_sclk;
  oled_dc   <= init_dc   when state = OledInitialize else example_dc;

  -- **LED mapping**: one‐hot reflect each FSM state
  leds(0) <= '1' when state = Idle           else '0';
  leds(1) <= '1' when state = OledInitialize else '0';
  leds(2) <= '1' when state = OledExample    else '0';
  leds(3) <= '1' when state = Done           else '0';

end architecture;
