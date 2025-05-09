library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top_gyro_zybo is
  generic (
    FILTER_SHIFT : natural := 5      -- 2^4 = 16 → 1/16 smoothing
  );
  port (
    -- system
    sys_clk  : in  std_logic;
    reset    : in  std_logic;

    -- PMOD-SPI pins (put this gyro on header **JD** or a spare JC CS line)
    jc_miso  : in  std_logic;
    jc_mosi  : out std_logic;
    jc_sclk  : out std_logic;
    jc_ss_n  : out std_logic_vector(0 downto 0);

    -- filtered 16-bit angular-rate outputs
    x_out    : out std_logic_vector(15 downto 0);
    y_out    : out std_logic_vector(15 downto 0);
    z_out    : out std_logic_vector(15 downto 0)
  );
end entity;

architecture rtl of top_gyro_zybo is
  -- raw from wrapper
  signal raw_x, raw_y, raw_z : std_logic_vector(15 downto 0);

  -- SPI nets
  signal sclk_int : std_logic;
  signal ss_vec   : std_logic_vector(0 downto 0);

  -- active-low reset for wrapper
  signal rst_n    : std_logic;

  -- IIR filter registers (width = 16+SHIFT)
  constant W  : natural := 16 + FILTER_SHIFT;
  subtype filt_t is signed(W-1 downto 0);
  signal xf, yf, zf : filt_t := (others=>'0');
begin
  rst_n <= not reset;

  --------------------------------------------------------------------------
  -- L3G4200D PMOD wrapper  (unchanged)
  --------------------------------------------------------------------------
  gyro_inst : entity work.pmod_gyro_l3g4200d
    generic map ( clk_freq => 125, data_rate => "00", bandwidth => "00")
    port map (
      clk             => sys_clk,
      reset_n         => rst_n,
      miso            => jc_miso,
      sclk            => sclk_int,
      jc_ss_n         => ss_vec,
      mosi            => jc_mosi,
      angular_rate_x  => raw_x,
      angular_rate_y  => raw_y,
      angular_rate_z  => raw_z );

  --------------------------------------------------------------------------
  -- 1-pole IIR:  y = y + (x - y)/2^SHIFT
  --------------------------------------------------------------------------
  process(sys_clk)
    variable dx, dy, dz : filt_t;
  begin
    if rising_edge(sys_clk) then
      if reset = '1' then
        xf <= (others=>'0');  yf <= (others=>'0');  zf <= (others=>'0');
      else
        dx := resize(signed(raw_x), W) - xf;
        dy := resize(signed(raw_y), W) - yf;
        dz := resize(signed(raw_z), W) - zf;
        xf <= xf + (dx srl FILTER_SHIFT);
        yf <= yf + (dy srl FILTER_SHIFT);
        zf <= zf + (dz srl FILTER_SHIFT);
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- pins & outputs
  --------------------------------------------------------------------------
  jc_sclk <= sclk_int;
  jc_ss_n <= ss_vec;

  x_out   <= std_logic_vector( xf(W-1 downto FILTER_SHIFT) );
  y_out   <= std_logic_vector( yf(W-1 downto FILTER_SHIFT) );
  z_out   <= std_logic_vector( zf(W-1 downto FILTER_SHIFT) );
end architecture;



