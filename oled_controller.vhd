library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity oled_controller is
  port (
    clk        : in  std_logic;  -- 4 MHz
    reset      : in  std_logic;  -- active-high
    oled_res   : out std_logic;  -- SSD1306 RES#
    oled_cs    : out std_logic;  -- SSD1306 CS#
    oled_dc    : out std_logic;  -- D/C#: 0=cmd,1=data
    oled_sclk  : out std_logic;  -- SPI clock
    oled_mosi  : out std_logic   -- SPI data in
  );
end entity;

architecture beh of oled_controller is
  -- Init command list
  type cmd_t is array (natural range <>) of std_logic_vector(7 downto 0);
  constant INIT_CMDS : cmd_t := (
    x"AE", x"D5", x"80", x"A8", x"3F", x"D3", x"00", x"40",
    x"8D", x"14", x"20", x"00", x"A1", x"C8", x"DA", x"12",
    x"81", x"CF", x"D9", x"F1", x"DB", x"40", x"A4", x"A6", x"AF"
  );
  constant N_INIT : integer := INIT_CMDS'length;

  -- test‐pattern fill (1024 bytes)
  constant PAT_BYTE : std_logic_vector(7 downto 0) := x"FF";

  -- SPI clk div (4 MHz→1 MHz)
  constant DIV_HALF : integer := 2;

  type st_t is (
    RST_LOW, RST_HIGH,
    CMD_START, CMD_SEND,
    CMD_WAIT, DATA_START,
    DATA_SEND, DATA_WAIT
  );
  signal st       : st_t;
  signal div_cnt  : integer range 0 to DIV_HALF;
  signal spi_clk  : std_logic := '1';
  signal prev_clk : std_logic := '1';
  signal bit_cnt  : integer range 0 to 7;
  signal idx_cmd  : integer range 0 to N_INIT-1;
  signal idx_dat  : integer range 0 to 1023;
  signal shift    : std_logic_vector(7 downto 0);

begin
  oled_sclk <= spi_clk;
  process(clk)
    variable rising, falling : boolean;
  begin
    if rising_edge(clk) then
      if reset='1' then
        st       <= RST_LOW;
        div_cnt  <= 0;
        spi_clk  <= '1';
        oled_res <= '0';
        oled_cs  <= '1';
        oled_dc  <= '0';
        bit_cnt  <= 7;
        idx_cmd  <= 0;
        idx_dat  <= 0;
      else
        -- SPI clock divider
        if div_cnt=DIV_HALF-1 then
          div_cnt<=0; spi_clk<=not spi_clk;
        else
          div_cnt<=div_cnt+1;
        end if;

        -- edge detect
        rising  := prev_clk='0' and spi_clk='1';
        falling := prev_clk='1' and spi_clk='0';
        prev_clk:= spi_clk;

        case st is
          when RST_LOW =>
            oled_res <= '0';
            if rising then st<=RST_HIGH; end if;

          when RST_HIGH =>
            oled_res <= '1';
            st<=CMD_START;

          when CMD_START =>
            if idx_cmd<N_INIT then
              shift   <= INIT_CMDS(idx_cmd);
              bit_cnt <= 7;
              oled_cs <= '0'; oled_dc <= '0';
              st<=CMD_SEND;
            else
              st<=DATA_START;
              idx_dat<=0;
            end if;

          when CMD_SEND =>
            if falling then
              oled_mosi<= shift(bit_cnt);
              if bit_cnt=0 then st<=CMD_WAIT; else bit_cnt<=bit_cnt-1; end if;
            end if;

          when CMD_WAIT =>
            if rising then
              oled_cs<= '1';
              idx_cmd<= idx_cmd+1;
              st<=CMD_START;
            end if;

          when DATA_START =>
            shift   <= PAT_BYTE;
            bit_cnt <= 7;
            oled_cs <= '0'; oled_dc <= '1';
            st<=DATA_SEND;

          when DATA_SEND =>
            if falling then
              oled_mosi<= shift(bit_cnt);
              if bit_cnt=0 then st<=DATA_WAIT; else bit_cnt<=bit_cnt-1; end if;
            end if;

          when DATA_WAIT =>
            if rising then
              oled_cs<= '1';
              idx_dat<= idx_dat+1;
              if idx_dat<1023 then st<=DATA_START; else st<=DATA_START; end if;
            end if;

          when others => st<=RST_LOW;
        end case;
      end if;
    end if;
  end process;
end architecture;
