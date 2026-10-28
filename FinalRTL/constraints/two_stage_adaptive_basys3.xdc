# Both steady-state clock modes on the same physical BUFG. Source remains
# timed at 100 MHz; do not hide all source/processing paths with clock groups.
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -period 10.000 -name clk_100mhz [get_ports clk]
set clock_pin [get_pins system_core/low_power_clock/clock_buffer/O]
create_generated_clock -name processing_fast -source [get_ports clk] \
    -divide_by 1000 $clock_pin
create_generated_clock -name processing_slow -source [get_ports clk] \
    -master_clock clk_100mhz -divide_by 200000 -add $clock_pin
set_clock_groups -physically_exclusive -group [get_clocks processing_fast] \
    -group [get_clocks processing_slow]
# This common XDC checks both rates for both cost-comparison builds. The
# ADAPTIVE_CLOCK=0 hardware actually uses only processing_fast.
# Only first synchronization stages are exempted, not entire domains.
set first_sync [get_cells -hier -regexp {.*(request_sync|ack_sync|source_ready|button_sync|mode_sync)_reg\[0\]}]
set_false_path -to [get_pins -of_objects $first_sync -filter {REF_PIN_NAME == D}]
# Mailbox data is held from request through acknowledge. Bound its physical
# propagation to half the fastest processing period; request has 2 FF stages.
set held [get_cells -hier -filter {NAME =~ *held_data_reg*}]
set received [get_cells -hier -filter {NAME =~ *processing_data_reg*}]
set_max_delay -datapath_only 5000 -from $held -to $received
set_false_path -hold -from $held -to $received
set_false_path -from [get_ports {sw[15]}]
set_property PACKAGE_PIN U18 [get_ports btnC]
set_property IOSTANDARD LVCMOS33 [get_ports btnC]
set_property PACKAGE_PIN V17 [get_ports {sw[0]}]
set_property PACKAGE_PIN V16 [get_ports {sw[1]}]
set_property PACKAGE_PIN W16 [get_ports {sw[2]}]
set_property PACKAGE_PIN W17 [get_ports {sw[3]}]
set_property PACKAGE_PIN W15 [get_ports {sw[4]}]
set_property PACKAGE_PIN V15 [get_ports {sw[5]}]
set_property PACKAGE_PIN W14 [get_ports {sw[6]}]
set_property PACKAGE_PIN W13 [get_ports {sw[7]}]
set_property PACKAGE_PIN V2 [get_ports {sw[8]}]
set_property PACKAGE_PIN T3 [get_ports {sw[9]}]
set_property PACKAGE_PIN T2 [get_ports {sw[10]}]
set_property PACKAGE_PIN R3 [get_ports {sw[11]}]
set_property PACKAGE_PIN W2 [get_ports {sw[12]}]
set_property PACKAGE_PIN U1 [get_ports {sw[13]}]
set_property PACKAGE_PIN T1 [get_ports {sw[14]}]
set_property PACKAGE_PIN R2 [get_ports {sw[15]}]
set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property PACKAGE_PIN W18 [get_ports {led[4]}]
set_property PACKAGE_PIN U15 [get_ports {led[5]}]
set_property PACKAGE_PIN U14 [get_ports {led[6]}]
set_property PACKAGE_PIN V14 [get_ports {led[7]}]
set_property PACKAGE_PIN V13 [get_ports {led[8]}]
set_property PACKAGE_PIN V3 [get_ports {led[9]}]
set_property PACKAGE_PIN W3 [get_ports {led[10]}]
set_property PACKAGE_PIN U3 [get_ports {led[11]}]
set_property PACKAGE_PIN P3 [get_ports {led[12]}]
set_property PACKAGE_PIN N3 [get_ports {led[13]}]
set_property PACKAGE_PIN P1 [get_ports {led[14]}]
set_property PACKAGE_PIN L1 [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw[*] led[*]}]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
# LEDs are static indicators, not a timed off-chip data interface.
set_false_path -to [get_ports {led[*]}]
# Switch data is a manually held demonstration value, not a synchronous ADC.
set_false_path -from [get_ports {sw[0] sw[1] sw[2] sw[3] sw[4] sw[5] sw[6] sw[7] sw[8] sw[9] sw[10] sw[11]}]
