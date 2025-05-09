--------------------------------------------------------------------------------
--
--   FileName:         pmod_gyro_l3g4200d.vhd
--   Dependencies:     spi_master.vhd
--   Design Software:  Quartus Prime Version 17.0.0 Build 595 SJ Lite Edition
--
--   HDL CODE IS PROVIDED "AS IS."  DIGI-KEY EXPRESSLY DISCLAIMS ANY
--   WARRANTY OF ANY KIND, WHETHER EXPRESS OR IMPLIED, INCLUDING BUT NOT
--   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
--   PARTICULAR PURPOSE, OR NON-INFRINGEMENT. IN NO EVENT SHALL DIGI-KEY
--   BE LIABLE FOR ANY INCIDENTAL, SPECIAL, INDIRECT OR CONSEQUENTIAL
--   DAMAGES, LOST PROFITS OR LOST DATA, HARM TO YOUR EQUIPMENT, COST OF
--   PROCUREMENT OF SUBSTITUTE GOODS, TECHNOLOGY OR SERVICES, ANY CLAIMS
--   BY THIRD PARTIES (INCLUDING BUT NOT LIMITED TO ANY DEFENSE THEREOF),
--   ANY CLAIMS FOR INDEMNITY OR CONTRIBUTION, OR OTHER SIMILAR COSTS.
--
--   Version History
--   Version 1.0 06/13/2022 Scott Larson
--     Initial Public Release
--   Version 1.1 07/29/2022 Scott Larson
--     Fixed potential intermittent problem coming out of reset
--    
--------------------------------------------------------------------------------

LIBRARY ieee;
USE ieee.std_logic_1164.all;

ENTITY pmod_gyro_l3g4200d IS
  GENERIC(
    clk_freq  : INTEGER := 50;             --system clock frequency in MHz
    data_rate : STD_LOGIC_VECTOR := "00";  --data rate code to configure the gyro
    bandwidth : STD_LOGIC_VECTOR := "00"); --bandwidth code to configure the gyro
  PORT(
    clk            : IN      STD_LOGIC;                      --system clock
    reset_n        : IN      STD_LOGIC;                      --active low asynchronous reset
    miso           : IN      STD_LOGIC;                      --SPI bus: master in, slave out
    sclk           : BUFFER  STD_LOGIC;                      --SPI bus: serial clock
    ss_n           : BUFFER  STD_LOGIC_VECTOR(0 DOWNTO 0);   --SPI bus: slave select
    mosi           : OUT     STD_LOGIC;                      --SPI bus: master out, slave in
    angular_rate_x : OUT     STD_LOGIC_VECTOR(15 DOWNTO 0);  --x-axis angular rate data
    angular_rate_y : OUT     STD_LOGIC_VECTOR(15 DOWNTO 0);  --y-axis angular rate data
    angular_rate_z : OUT     STD_LOGIC_VECTOR(15 DOWNTO 0)); --z-axis angular rate data
END pmod_gyro_l3g4200d;

ARCHITECTURE behavior OF pmod_gyro_l3g4200d IS
  TYPE machine IS(start, pause, configure, read_data, output_result); --needed states
  SIGNAL state              : machine := start;                       --state machine
  SIGNAL spi_busy_prev      : STD_LOGIC;                              --previous value of the SPI component's busy signal
  SIGNAL spi_busy           : STD_LOGIC;                              --busy signal from SPI component
  SIGNAL spi_ena            : STD_LOGIC;                              --enable for SPI component
  SIGNAL spi_cont           : STD_LOGIC;                              --continuous mode signal for SPI component
  SIGNAL spi_tx_data        : STD_LOGIC_VECTOR(7 DOWNTO 0);           --transmit data for SPI component
  SIGNAL spi_rx_data        : STD_LOGIC_VECTOR(7 DOWNTO 0);           --received data from SPI component
  SIGNAL angular_rate_x_int : STD_LOGIC_VECTOR(15 DOWNTO 0);          --internal x-axis angular rate data buffer
  SIGNAL angular_rate_y_int : STD_LOGIC_VECTOR(15 DOWNTO 0);          --internal y-axis angular rate data buffer
  SIGNAL angular_rate_z_int : STD_LOGIC_VECTOR(15 DOWNTO 0);          --internal z-axis angular rate data buffer

  --declare SPI Master component
  COMPONENT spi_master IS
     GENERIC(
        slaves  : INTEGER := 1;  --number of spi slaves
        d_width : INTEGER := 8); --data bus width
     PORT(
        clock   : IN     STD_LOGIC;                             --system clock
        reset_n : IN     STD_LOGIC;                             --asynchronous reset
        enable  : IN     STD_LOGIC;                             --initiate transaction
        cpol    : IN     STD_LOGIC;                             --spi clock polarity
        cpha    : IN     STD_LOGIC;                             --spi clock phase
        cont    : IN     STD_LOGIC;                             --continuous mode command
        clk_div : IN     INTEGER;                               --system clock cycles per 1/2 period of sclk
        addr    : IN     INTEGER;                               --address of slave
        tx_data : IN     STD_LOGIC_VECTOR(d_width-1 DOWNTO 0);  --data to transmit
        miso    : IN     STD_LOGIC;                             --master in, slave out
        sclk    : BUFFER STD_LOGIC;                             --spi clock
        ss_n    : BUFFER STD_LOGIC_VECTOR(slaves-1 DOWNTO 0);   --slave select
        mosi    : OUT    STD_LOGIC;                             --master out, slave in
        busy    : OUT    STD_LOGIC;                             --busy / data ready signal
        rx_data : OUT    STD_LOGIC_VECTOR(d_width-1 DOWNTO 0)); --data received
  END COMPONENT spi_master;

BEGIN

  --instantiate the SPI Master component
  spi_master_0:  spi_master
    GENERIC MAP(slaves => 1, d_width => 8)
    PORT MAP(clock => clk, reset_n => reset_n, enable => spi_ena, cpol => '1', cpha => '1',
          cont => spi_cont, clk_div => clk_freq/10, addr => 0, tx_data => spi_tx_data, miso => miso,
          sclk => sclk, ss_n => ss_n, mosi => mosi, busy => spi_busy, rx_data => spi_rx_data);

  PROCESS(clk)
    VARIABLE count : INTEGER := 0; --universal counter
  BEGIN
    IF(reset_n = '0') THEN              --reset activated
      spi_busy_prev <= '0';               --clear previous value of SPI component's busy signal
      spi_ena <= '0';                     --clear SPI component enable
      spi_cont <= '0';                    --clear SPI component continuous mode signal
      spi_tx_data <= (OTHERS => '0');     --clear SPI component transmit data
      angular_rate_x <= (OTHERS => '0');  --clear x-axis angular rate data
      angular_rate_y <= (OTHERS => '0');  --clear y-axis angular rate data
      angular_rate_z <= (OTHERS => '0');  --clear z-axis angular rate data
      state <= start;                     --restart state machine
    ELSIF(clk'EVENT AND clk = '1') THEN --rising edge of system clock
      CASE state IS                       --state machine

        --give gyro 100ms to power up before communicating
        WHEN start =>
          IF(count < clk_freq*100_000) THEN   --100ms not yet reached
            count := count + 1;                 --increment counter
          ELSE                                --100ms reached
            count := 0;                         --clear universal counter
            state <= configure;                 --advance to configuration
          END IF;

        --performs SPI transactions that write to configuration registers  
        WHEN configure =>
          spi_busy_prev <= spi_busy;                      --capture the value of the previous spi busy signal
          IF(spi_busy_prev = '1' AND spi_busy = '0') THEN --spi busy just went low
            count := count + 1;                             --counts times busy goes from high to low during transaction
          END IF;
          CASE count IS                                   --number of times busy has gone from high to low
            WHEN 0 =>                                       --no busy deassertions
              IF(spi_busy = '0') THEN                         --transaction not started
                spi_cont <= '1';                                --set to continuous mode
                spi_ena <= '1';                                 --enable SPI transaction
                spi_tx_data <= "00100000";                      --send command to write to control register 1
              ELSE                                            --transaction latched in
                spi_tx_data <= data_rate & bandwidth & "1111";  --second information to send (configuration word)
              END IF;
            WHEN 1 =>                                         --first busy deassertion
              spi_cont <= '0';                                  --clear continous mode to end transaction
              spi_ena <= '0';                                   --clear SPI transaction enable
              count := 0;                                       --clear universal counter
              state <= pause;                                   --advance to pause state
            WHEN OTHERS => NULL;
          END CASE;
      
        --pauses 1ms between SPI transactions
        WHEN pause =>
          IF(count < clk_freq*1000) THEN   --less than 1ms
            count := count + 1;              --increment counter
          ELSE                             --1ms has elapsed
            count := 0;                      --clear universal counter
            state <= read_data;              --advance to read data state 
          END IF;

        --performs SPI transactions that read gyro data registers  
        WHEN read_data =>
          spi_busy_prev <= spi_busy;                        --capture the value of the previous spi busy signal
          IF(spi_busy_prev = '1' AND spi_busy = '0') THEN   --spi busy just went low
            count := count + 1;                               --counts the times busy goes from high to low during transaction
          END IF;          
          CASE count IS                                     --number of times busy has gone from high to low
            WHEN 0 =>                                         --no busy deassertions
              IF(spi_busy = '0') THEN                           --transaction not started
                spi_cont <= '1';                                  --set to continuous mode
                spi_ena <= '1';                                   --enable SPI transaction
                spi_tx_data <= "11101000";                        --send read command to OUT_X_L register
              ELSE                                              --transaction latched in
                spi_tx_data <= "00000000";                        --deassert MOSI
              END IF;
            WHEN 2 =>                                         --2nd busy deassertion
              angular_rate_x_int(7 DOWNTO 0) <= spi_rx_data;    --latch in first received angular rate data
            WHEN 3 =>                                         --3rd busy deassertion
              angular_rate_x_int(15 DOWNTO 8) <= spi_rx_data;   --latch in second received angular rate data
            WHEN 4 =>                                         --4th busy deassertion
              angular_rate_y_int(7 DOWNTO 0) <= spi_rx_data;    --latch in third received angular rate data
            WHEN 5 =>                                         --5th busy deassertion
              angular_rate_y_int(15 DOWNTO 8) <= spi_rx_data;   --latch in fourth received angular rate data
            WHEN 6 =>                                         --6th busy deassertion
              spi_cont <= '0';                                  --clear continuous mode to end transaction
              spi_ena <= '0';                                   --clear SPI transaction enable
              angular_rate_z_int(7 DOWNTO 0) <= spi_rx_data;    --latch in fifth received angular rate data
            WHEN 7 =>                                         --7th busy deassertion
              angular_rate_z_int(15 DOWNTO 8) <= spi_rx_data;   --latch in sixth received angular rate data
              count := 0;                                       --clear universal counter
              state <= output_result;                           --proceed to output result state
            WHEN OTHERS => NULL;
          END CASE;
  
        --outputs angular rate data
        WHEN output_result =>
            angular_rate_x <= angular_rate_x_int;  --output x-axis data
            angular_rate_y <= angular_rate_y_int;  --output y-axis data
            angular_rate_z <= angular_rate_z_int;  --output z-axis data
            state <= pause;                        --return to pause state
        
        --default to start state
        WHEN OTHERS => 
          state <= start;

      END CASE;      
    END IF;
  END PROCESS;
END behavior;
