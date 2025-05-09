## System Clock (125 MHz)
set_property PACKAGE_PIN K17 [get_ports {sys_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {sys_clk}]
create_clock -name sys_clk_pin -period 8.000 [get_ports {sys_clk}]

## PMOD JC SPI Interface for L3G4200D
# JC1 (Pmod pin 1) → SCLK
set_property PACKAGE_PIN V15 [get_ports {jc_ss_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {jc_ss_n}]
# JC2 (Pmod pin 2) → MOSI
set_property PACKAGE_PIN W15 [get_ports {jc_mosi}]
set_property IOSTANDARD LVCMOS33 [get_ports {jc_mosi}]
# JC3 (Pmod pin 3) → MISO
set_property PACKAGE_PIN T11 [get_ports {jc_miso}]
set_property IOSTANDARD LVCMOS33 [get_ports {jc_miso}]
# JC4 (Pmod pin 4) → SS_N (chip-select, active low)
set_property PACKAGE_PIN T10 [get_ports {jc_sclk}]
set_property IOSTANDARD LVCMOS33 [get_ports {jc_sclk}]

## LEDs
# LD0 → led_x
set_property PACKAGE_PIN M14 [get_ports {led_x}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_x}]
# LD1 → led_y
set_property PACKAGE_PIN M15 [get_ports {led_y}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_y}]
# LD2 → led_z
set_property PACKAGE_PIN G14 [get_ports {led_z}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_z}]
# LD3 → led_hb (heartbeat)
set_property PACKAGE_PIN D18 [get_ports {led_hb}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_hb}]



