library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;  -- For unsigned conversions and comparisons

entity acl_led_indicator is
    port (
        clk_125mhz : in  std_logic;                     -- 125 MHz system clock
        reset      : in  std_logic;                     -- synchronous, active-high reset
        acl_data   : in  std_logic_vector(47 downto 0); -- Accel data: {X[15:0], Y[15:0], Z[15:0]}
        leds_out   : out std_logic_vector(3 downto 0)   -- 4 user LEDs
    );
end entity acl_led_indicator;

architecture behavioral of acl_led_indicator is
    signal leds_reg : std_logic_vector(3 downto 0) := (others => '0');
begin
    leds_out <= leds_reg;

    process(clk_125mhz, reset)
    begin
        if reset = '1' then
            leds_reg <= (others => '0');
        elsif rising_edge(clk_125mhz) then
            -- Turn on LED0 if any bit of acl_data is non-zero
            if unsigned(acl_data) /= 0 then
                leds_reg(0) <= '1';
            else
                leds_reg(0) <= '0';
            end if;
            -- Other LEDs remain off (expand as needed)
            leds_reg(1) <= '0';
            leds_reg(2) <= '0';
            leds_reg(3) <= '0';
        end if;
    end process;
end architecture behavioral;
