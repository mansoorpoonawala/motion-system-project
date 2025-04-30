library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity oled_driver is
  generic(
    SYS_CLK : integer := 100_000_000;
    SPI_CLK : integer :=   1_000_000
  );
  port(
    clk        : in  std_logic;
    rst        : in  std_logic;
    axis_x     : in  std_logic_vector(15 downto 0);
    axis_y     : in  std_logic_vector(15 downto 0);
    axis_z     : in  std_logic_vector(15 downto 0);
    spi_mosi   : out std_logic;
    spi_sclk   : out std_logic;
    spi_cs_n   : out std_logic;
    spi_dc     : out std_logic;
    oled_rst_n : out std_logic
  );
end entity;

architecture rtl of oled_driver is
  constant DIV : integer := SYS_CLK/(SPI_CLK*2);
  signal cnt     : integer range 0 to DIV := 0;
  signal sclk_i  : std_logic := '0';
  signal shiftb  : std_logic_vector(7 downto 0);
  signal bitn    : integer range 0 to 7 := 7;
  signal start_b : std_logic := '0';
  type st2 is (RST_P, INIT, IDLE, SEND, WAIT, DONE);
  signal st      : st2 := RST_P;
  constant CMDS  : std_logic_vector(7 downto 0)  array (0 to 3) :=
    (x"AE",x"A1",x"C8",x"AF");  -- OFF, remap, scandec, ON
  signal ci      : integer range 0 to 3 := 0;
  constant NBY   : integer := 12;
  type data_t is array(0 to NBY-1) of std_logic_vector(7 downto 0);
  signal dbuf    : data_t := (others=>(others=>'0'));
  signal di      : integer range 0 to NBY := 0;

  function h2a(nib: std_logic_vector(3 downto 0)) return std_logic_vector is
    variable u: integer := to_integer(unsigned(nib));
  begin
    if u<10 then return std_logic_vector(to_unsigned(48+u, 8));
    else         return std_logic_vector(to_unsigned(55+u, 8));
    end if;
  end function;

begin

  -- SPI CLK divider
  process(clk,rst)
  begin
    if rst='1' then cnt<=0; sclk_i<='0';
    elsif rising_edge(clk) then
      if cnt=DIV-1 then cnt<=0; sclk_i<=not sclk_i;
      else cnt<=cnt+1; end if;
    end if;
  end process;
  spi_sclk<=sclk_i;
  spi_cs_n<='0';

  -- Main FSM
  process(clk,rst)
  begin
    if rst='1' then
      st<=RST_P; oled_rst_n<='0';
      ci<=0; di<=0; start_b<='0'; bitn<=7;
    elsif rising_edge(clk) then
      case st is
        when RST_P =>
          oled_rst_n<='0';
          if cnt=0 then oled_rst_n<='1'; st<=INIT; end if;

        when INIT =>
          if ci<4 then
            shiftb<=CMDS(ci); spi_dc<='0'; start_b<='1';
            st<=SEND;
          else st<=IDLE; end if;

        when IDLE =>
          dbuf(0)<=h2a(axis_x(15 downto 12));
          dbuf(1)<=h2a(axis_x(11 downto  8));
          dbuf(2)<=h2a(axis_x( 7 downto  4));
          dbuf(3)<=h2a(axis_x( 3 downto  0));
          dbuf(4)<=h2a(axis_y(15 downto 12));
          dbuf(5)<=h2a(axis_y(11 downto  8));
          dbuf(6)<=h2a(axis_y( 7 downto  4));
          dbuf(7)<=h2a(axis_y( 3 downto  0));
          dbuf(8)<=h2a(axis_z(15 downto 12));
          dbuf(9)<=h2a(axis_z(11 downto  8));
          dbuf(10)<=h2a(axis_z( 7 downto  4));
          dbuf(11)<=h2a(axis_z( 3 downto  0));
          di<=0; start_b<='1'; spi_dc<='1'; shiftb<=dbuf(0);
          st<=SEND;

        when SEND =>
          if start_b='1' then
            start_b<='0'; bitn<=7;
          elsif rising_edge(sclk_i) then
            spi_mosi<=shiftb(bitn);
            if bitn=0 then st<=WAIT; else bitn<=bitn-1; end if;
          end if;

        when WAIT =>
          if st='WAIT' and sclk_i='1' then
            if ci<4 then ci<=ci+1; st<=INIT;
            else
              if di<NBY-1 then di<=di+1;
                shiftb<=dbuf(di+1); start_b<='1'; st<=SEND;
              else st<=DONE; end if;
            end if;
          end if;

        when DONE =>
          st<=IDLE;
      end case;
    end if;
  end process;

end architecture;
