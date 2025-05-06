
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; -- Required for unsigned types and comparisons
use ieee.std_logic_unsigned.all; -- Alternative for arithmetic with std_logic_vector (if preferred)

entity acl_led_indicator is
    port (
        clk_125mhz : in  std_logic; -- 125MHz system clock from Zybo Z7
        reset      : in  std_logic; -- Synchronous reset input
        acl_data   : in  std_logic_vector(47 downto 0); -- Input accelerometer data (X, Y, Z - 16 bits each)

        leds_out   : out std_logic_vector(3 downto 0) -- Output to the 4 user LEDs on the Zybo Z7
    );
end entity acl_led_indicator;

architecture behavioral of acl_led_indicator is

    -- Internal signal to hold the LED output values
    signal leds_reg : std_logic_vector(3 downto 0) := (others => '0');

begin

    -- Assign the internal LED register to the output port
    leds_out <= leds_reg;

    -- Process to control the LEDs based on received accelerometer data
    process (clk_125mhz, reset)
    begin
        if reset = '1' then
            leds_reg <= (others => '0'); -- Turn all LEDs off on reset
        elsif rising_edge(clk_125mhz) then
            -- Check if the received accelerometer data is not all zeros.
            -- If any bit in acl_data is '1', it indicates some data is being received.
            if acl_data /= (others => '0') then
                -- Turn on the first LED (LED0) if data is non-zero
                leds_reg(0) <= '1';
            else
                -- Turn off the first LED (LED0) if data is all zeros
                leds_reg(0) <= '0';
            end if;

            -- Keep the other LEDs off for now
            leds_reg(1) <= '0';
            leds_reg(2) <= '0';
            leds_reg(3) <= '0';

            -- You could expand this later to use other LEDs to indicate
            -- specific conditions based on the accelerometer data values (e.g., high acceleration).

        end if;
    end process;

end architecture behavioral;
