library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity OledEx is
  Port (
    CLK   : in  STD_LOGIC;                -- 125 MHz system clock
    RST   : in  STD_LOGIC;                -- synchronous reset
    EN    : in  STD_LOGIC;                -- enable the example block
    CS    : out STD_LOGIC;                -- SPI chip select
    SDO   : out STD_LOGIC;                -- SPI data out
    SCLK  : out STD_LOGIC;                -- SPI clock
    DC    : out STD_LOGIC;                -- data/command select
    FIN   : out STD_LOGIC                 -- high when done
  );
end entity;

architecture Behavioral of OledEx is

  -- 8×8 bitmaps for X, Y, Z, and ':'
  type Glyph8 is array(0 to 7) of STD_LOGIC_VECTOR(7 downto 0);
  constant Glyph_X     : Glyph8 := (
    "10000001","01000010","00100100","00011000",
    "00011000","00100100","01000010","10000001"
  );
  constant Glyph_Y     : Glyph8 := (
    "10000001","01000010","00100100","00011000",
    "00010000","00010000","00010000","00010000"
  );
  constant Glyph_Z     : Glyph8 := (
    "11111111","00000010","00000100","00001000",
    "00010000","00100000","01000000","11111111"
  );
  constant Glyph_Colon : Glyph8 := (
    "00000000","00011000","00011000","00000000",
    "00000000","00011000","00011000","00000000"
  );

  -- screen memory: 4 pages × 16 columns
  type ScreenMem is array(0 to 3, 0 to 15) of STD_LOGIC_VECTOR(7 downto 0);
  constant my_screen : ScreenMem := (
    -- Page 0 → “X:” in cols 0–15
    ( Glyph_X(0), Glyph_X(1), Glyph_X(2), Glyph_X(3),
      Glyph_X(4), Glyph_X(5), Glyph_X(6), Glyph_X(7),
      Glyph_Colon(0),Glyph_Colon(1),Glyph_Colon(2),Glyph_Colon(3),
      Glyph_Colon(4),Glyph_Colon(5),Glyph_Colon(6),Glyph_Colon(7)
    ),
    -- Page 1 → “Y:”
    ( Glyph_Y(0), Glyph_Y(1), Glyph_Y(2), Glyph_Y(3),
      Glyph_Y(4), Glyph_Y(5), Glyph_Y(6), Glyph_Y(7),
      Glyph_Colon(0),Glyph_Colon(1),Glyph_Colon(2),Glyph_Colon(3),
      Glyph_Colon(4),Glyph_Colon(5),Glyph_Colon(6),Glyph_Colon(7)
    ),
    -- Page 2 → “Z:”
    ( Glyph_Z(0), Glyph_Z(1), Glyph_Z(2), Glyph_Z(3),
      Glyph_Z(4), Glyph_Z(5), Glyph_Z(6), Glyph_Z(7),
      Glyph_Colon(0),Glyph_Colon(1),Glyph_Colon(2),Glyph_Colon(3),
      Glyph_Colon(4),Glyph_Colon(5),Glyph_Colon(6),Glyph_Colon(7)
    ),
    -- Page 3 → blank
    ( (others => (others => '0')), (others => (others => '0')),
      (others => (others => '0')), (others => (others => '0')) )
  );

  -- SPI / state‐machine signals
  signal temp_spi_en    : STD_LOGIC := '0';
  signal temp_spi_data  : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
  signal temp_spi_fin   : STD_LOGIC;
  signal temp_dc        : STD_LOGIC := '0';

  constant TOTAL_PAGES  : integer := 4;
  constant PAGE_WIDTH   : integer := 16;

  signal page_idx       : integer range 0 to TOTAL_PAGES-1 := 0;
  signal col_idx        : integer range 0 to PAGE_WIDTH-1  := 0;
  signal current_state  : integer range 0 to 3 := 0;  -- 0=Idle,1=SendCmd,2=SendData,3=Done

begin

  -- map SPI controller (you still need SpiCtrl.vhd in project)
  SPI_COMP: entity work.SpiCtrl
    port map(
      CLK     => CLK,
      RST     => RST,
      SPI_EN  => temp_spi_en,
      SPI_DATA=> temp_spi_data,
      CS      => CS,
      SDO     => SDO,
      SCLK    => SCLK,
      SPI_FIN => temp_spi_fin
    );

  DC <= temp_dc;
  FIN <= '1' when current_state = 3 else '0';

  process(CLK)
  begin
    if rising_edge(CLK) then
      if RST = '1' then
        current_state <= 0;
        page_idx      <= 0;
        col_idx       <= 0;
      else
        case current_state is
          when 0 =>  -- Idle, wait for EN
            if EN = '1' then
              page_idx      <= 0;
              col_idx       <= 0;
              current_state <= 1;
            end if;

          when 1 =>  -- send SetPage & column commands
            -- for brevity, assume your top‐level has already set columns to 0
            -- here we only toggle DC and send the SetPage byte 0x22 and page number
            temp_dc       <= '0';
            temp_spi_data<= x"22";   -- Set Page command
            temp_spi_en  <= '1';
            if temp_spi_fin = '1' then
              temp_spi_en  <= '0';
              -- next send page address (0xB0 + page_idx)
              temp_spi_data<= std_logic_vector(to_unsigned(16#B0# + page_idx,8));
              temp_spi_en  <= '1';
              current_state<= 2;
            end if;

          when 2 =>  -- send actual data bytes for this page
            temp_dc       <= '1';
            if col_idx < PAGE_WIDTH then
              temp_spi_data <= my_screen(page_idx, col_idx);
              temp_spi_en   <= '1';
              if temp_spi_fin = '1' then
                temp_spi_en <= '0';
                col_idx     <= col_idx + 1;
              end if;
            else
              -- move to next page
              col_idx       <= 0;
              page_idx      <= page_idx + 1;
              if page_idx = TOTAL_PAGES-1 then
                current_state <= 3;  -- Done
              else
                current_state <= 1;  -- Set up next page
              end if;
            end if;

          when others =>  -- Done: just sit here
            temp_spi_en <= '0';
        end case;
      end if;
    end if;
  end process;

end architecture;
