library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity gyro_ctrl is
  generic (
    THRESH      : integer := 40;        -- angular-rate threshold (~40 counts)
    SAMPLE_DIV  : integer := 125_000;   -- 1 kHz tick @125 MHz
    PULSE_MS    : integer := 100;       -- LED on-time in ms
    CAL_SAMPLES : integer := 100        -- ms for zero-offset calibration
  );
  port (
    clk       : in  std_logic;
    reset     : in  std_logic;
    x_rate    : in  std_logic_vector(15 downto 0);
    y_rate    : in  std_logic_vector(15 downto 0);
    z_rate    : in  std_logic_vector(15 downto 0);
    leds      : out std_logic_vector(3 downto 0)  -- 0=X 1=Y 2=Z 3=HB
  );
end entity;

architecture rtl of gyro_ctrl is

  signal xs, ys, zs : signed(15 downto 0);

  -- 1 kHz strobe generator
  signal div_cnt : integer range 0 to SAMPLE_DIV-1 := 0;
  signal strobe  : std_logic := '0';

  -- calibration accumulators
  signal cal_cnt        : integer range 0 to CAL_SAMPLES := 0;
  signal sum_x, sum_y, sum_z : integer := 0;
  signal base_x, base_y, base_z : integer := 0;

  -- pulse timers
  constant PULSE_CNT : integer := PULSE_MS; 
  signal px_cnt, py_cnt, pz_cnt : integer range 0 to PULSE_CNT := 0;

  signal leds_r : std_logic_vector(3 downto 0) := (others => '0');

begin

  leds <= leds_r;
  xs <= signed(x_rate);
  ys <= signed(y_rate);
  zs <= signed(z_rate);

  ----------------------------------------------------------------
  -- 1 kHz strobe
  ----------------------------------------------------------------
  process(clk, reset)
  begin
    if reset = '1' then
      div_cnt <= 0;  strobe <= '0';
    elsif rising_edge(clk) then
      if div_cnt = SAMPLE_DIV-1 then
        div_cnt <= 0;  strobe <= '1';
      else
        div_cnt <= div_cnt + 1;  strobe <= '0';
      end if;
    end if;
  end process;

  ----------------------------------------------------------------
  -- main pulse-stretch logic
  ----------------------------------------------------------------
  process(clk, reset)
    variable dx, dy, dz : integer;
  begin
    if reset = '1' then
      cal_cnt   <= 0;  sum_x <= 0; sum_y <= 0; sum_z <= 0;
      base_x    <= 0;  base_y <= 0; base_z <= 0;
      px_cnt    <= 0;  py_cnt <= 0; pz_cnt <= 0;
      leds_r    <= (others => '0');
    elsif rising_edge(clk) then

      -- heartbeat toggle on bit 3
      if strobe = '1' then
        leds_r(3) <= not leds_r(3);
      end if;
     

      -- baseline capture for first CAL_SAMPLES ms
      if strobe = '1' and cal_cnt < CAL_SAMPLES then
        sum_x <= sum_x + to_integer(xs);
        sum_y <= sum_y + to_integer(ys);
        sum_z <= sum_z + to_integer(zs);
        cal_cnt <= cal_cnt + 1;
        if cal_cnt = CAL_SAMPLES-1 then
          base_x <= sum_x / CAL_SAMPLES;
          base_y <= sum_y / CAL_SAMPLES;
          base_z <= sum_z / CAL_SAMPLES;
        end if;

      -- after baseline, threshold & pulse
      elsif strobe = '1' and cal_cnt = CAL_SAMPLES then
        dx := abs(to_integer(xs) - base_x);
        dy := abs(to_integer(ys) - base_y);
        dz := abs(to_integer(zs) - base_z);

        -- X-axis
        if dx > THRESH then
          px_cnt   <= PULSE_CNT;  leds_r(0) <= '1';
        elsif px_cnt > 0 then
          px_cnt <= px_cnt - 1;
          if px_cnt = 1 then leds_r(0) <= '0'; end if;
        end if;

        -- Y-axis
        if dy > THRESH then
          py_cnt   <= PULSE_CNT;  leds_r(1) <= '1';
        elsif py_cnt > 0 then
          py_cnt <= py_cnt - 1;
          if py_cnt = 1 then leds_r(1) <= '0'; end if;
        end if;

        -- Z-axis
        if dz > THRESH then
          pz_cnt   <= PULSE_CNT;  leds_r(2) <= '1';
        elsif pz_cnt > 0 then
          pz_cnt <= pz_cnt - 1;
          if pz_cnt = 1 then leds_r(2) <= '0'; end if;
        end if;
      end if;
    end if;
  end process;

end architecture;



