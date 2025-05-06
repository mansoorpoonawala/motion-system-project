-- Created by Gemini
-- Based on Verilog code by David J. Marion
-- Date: May 6, 2025
-- For Zybo Z7 Accelerometer Reading

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all; -- Required for unsigned types and arithmetic

entity iclk_gen is
    port (
        clk       : in  std_logic; -- Zybo Z7 sys clk (125MHz)
        clk_4MHz  : out std_logic  -- Approximately 4MHz clk
    );
end entity iclk_gen;

architecture behavioral of iclk_gen is

    -- Counter to divide the input clock frequency
    -- We need to count up to 30 (31 cycles) for a division factor of 31
    -- 31 requires a 5-bit counter (0 to 30)
    signal counter : unsigned(4 downto 0) := (others => '0');

    -- Internal signal for the generated clock
    signal clk_reg : std_logic := '1'; -- Start high for initial state

    -- Define the toggle points for the counter
    -- Toggle 1: After 15 cycles (counter reaches 14)
    constant TOGGLE_POINT_1 : unsigned(4 downto 0) := to_unsigned(14, 5);
    -- Toggle 2: After 16 more cycles (counter reaches 30), reset counter
    constant TOGGLE_POINT_2 : unsigned(4 downto 0) := to_unsigned(30, 5);

begin

    process (clk)
    begin
        if rising_edge(clk) then
            -- Check if the counter has reached the first toggle point
            if counter = TOGGLE_POINT_1 then
                clk_reg <= not clk_reg; -- Toggle the clock signal
            -- Check if the counter has reached the second toggle point (end of period)
            elsif counter = TOGGLE_POINT_2 then
                clk_reg <= not clk_reg; -- Toggle the clock signal
                counter <= (others => '0'); -- Reset the counter
            else
                counter <= counter + 1; -- Increment the counter
            end if;
        end if;
    end process;

    -- Assign the internal clock signal to the output port
    clk_4MHz <= clk_reg;

end architecture behavioral;
