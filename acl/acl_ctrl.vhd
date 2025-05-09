library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity acl_ctrl is
  generic (
    THRESH      : integer := 40;       -- about ±0.16 g at ±2 g
    SAMPLE_DIV  : integer := 125_000;  -- 1 kHz with 125-MHz clock
    PULSE_MS    : integer := 100;      -- LED on-time
    CAL_SAMPLES : integer := 100       -- samples for baseline
  );
  port (
    clk       : in  std_logic;
    reset     : in  std_logic;
    x_in      : in  std_logic_vector(15 downto 0);
    y_in      : in  std_logic_vector(15 downto 0);
    z_in      : in  std_logic_vector(15 downto 0);
    leds_dbg  : out std_logic_vector(3 downto 0)   -- 0=X 1=Y 2=Z 3=HB
  );
end entity;

architecture rtl of acl_ctrl is
  -- signed versions
  signal xs, ys, zs : signed(15 downto 0);

  -- 1-kHz strobe
  signal div_cnt : integer range 0 to SAMPLE_DIV-1 := 0;
  signal strobe  : std_logic := '0';

  -- baseline accumulators
  signal cal_cnt : integer range 0 to CAL_SAMPLES := 0;
  signal bx, by, bz : integer := 0;           -- running sums
  signal base_x, base_y, base_z : integer := 0; -- final offsets

  -- pulse timers
  constant PULSE_CNT : integer := PULSE_MS;    -- counts ms
  signal px_cnt, py_cnt, pz_cnt : integer range 0 to PULSE_CNT := 0;

  signal leds_r : std_logic_vector(3 downto 0) := (others=>'0');
begin
  leds_dbg <= leds_r;

  xs <= signed(x_in);
  ys <= signed(y_in);
  zs <= signed(z_in);

  ----------------------------------------------------------------
  -- generate 1-kHz strobe
  ----------------------------------------------------------------
  process(clk, reset)
  begin
    if reset='1' then
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
  -- main process: baseline-capture, threshold, pulse-stretch
  ----------------------------------------------------------------
  process(clk, reset)
    variable dx, dy, dz : integer;
  begin
    if reset='1' then
      cal_cnt   <= 0;  bx <= 0; by <= 0; bz <= 0;
      base_x    <= 0;  base_y <= 0; base_z <= 0;
      px_cnt    <= 0;  py_cnt <= 0; pz_cnt <= 0;
      leds_r    <= (others=>'0');
    elsif rising_edge(clk) then
      ----------------------------------------------------------------
      -- heartbeat (toggles every ms)
      ----------------------------------------------------------------
      if strobe='1' then leds_r(3) <= not leds_r(3); end if;

      ----------------------------------------------------------------
      -- baseline acquisition during first CAL_SAMPLES ms
      ----------------------------------------------------------------
      if strobe='1' and cal_cnt < CAL_SAMPLES then
        bx <= bx + to_integer(xs);
        by <= by + to_integer(ys);
        bz <= bz + to_integer(zs);
        cal_cnt <= cal_cnt + 1;
        if cal_cnt = CAL_SAMPLES-1 then
          base_x <= bx / CAL_SAMPLES;
          base_y <= by / CAL_SAMPLES;
          base_z <= bz / CAL_SAMPLES;
        end if;
      end if;

      ----------------------------------------------------------------
      -- threshold compare after baseline ready
      ----------------------------------------------------------------
      if strobe='1' and cal_cnt = CAL_SAMPLES then
        dx := abs(to_integer(xs) - base_x);
        dy := abs(to_integer(ys) - base_y);
        dz := abs(to_integer(zs) - base_z);

        -- X
        if dx > THRESH then
          px_cnt   <= PULSE_CNT;  leds_r(0) <= '1';
        elsif px_cnt > 0 then
          px_cnt <= px_cnt - 1;
          if px_cnt = 1 then leds_r(0) <= '0'; end if;
        end if;

        -- Y
        if dy > THRESH then
          py_cnt   <= PULSE_CNT;  leds_r(1) <= '1';
        elsif py_cnt > 0 then
          py_cnt <= py_cnt - 1;
          if py_cnt = 1 then leds_r(1) <= '0'; end if;
        end if;

        -- Z
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



