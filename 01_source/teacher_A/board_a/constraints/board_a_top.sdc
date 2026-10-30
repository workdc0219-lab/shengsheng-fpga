# Board A SDC timing constraints (signal acquisition + feature extraction).
# Clocking: 50 MHz crystal -> sys_pll_promax_40 -> video_clk = 25 MHz
# (clk3_out, the same clock domain the single board's audio chain ran in);
# the mic front end divides video_clk by two in fabric to drive the on-chip
# ADC (12.5 MHz, inside the 16 MHz limit of TN304).
create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
# TD does NOT reliably auto-derive PLL output clocks on this flow (first A
# build: Clock Summary listed only sys_clk, coverage 97.95%). Declare the
# 25 MHz video clock exactly like the single-board SDC declares pixel_clk,
# then the fabric ADC divider on top of it.
create_generated_clock -name video_clk -source [get_ports {sys_clk}]     -master_clock sys_clk -divide_by 2 [get_nets {video_clk}]
create_generated_clock -name pixel_clk_5x -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 2.5 [get_nets {pixel_clk_5x}]
create_generated_clock -name adc_clk -source [get_nets {video_clk}] \
    -master_clock {video_clk} -divide_by 2 [get_nets {u_mic/adc_clk}]

# done_toggle reaches the video domain through a three-stage synchronizer and
# held_code is stable for many ADC clocks before that strobe arrives, so this
# is a declared CDC rather than a data path that has to meet a period.
set_false_path -from [get_clocks {adc_clk}] -to [get_clocks {video_clk}]
set_false_path -from [get_clocks {video_clk}] -to [get_clocks {adc_clk}]

# Tool-default hold uncertainty (0.100 ns) exceeds the real PLL jitter + tree
# skew budget at 12.5-50 MHz and flags register -> async-RAM read-address
# partial paths in the +/-15 ps band (R64 finding on the single board; the
# pitch tracker's sample ring is Board A's async-read RAM). 0.050 ns keeps a
# real guardband without the guardband artifact.
set_clock_uncertainty -hold 0.050 [get_clocks {sys_clk video_clk adc_clk pixel_clk_5x}]

# Teacher console TMDS: bound each ODDR-to-pad path exactly as Board B does
set_max_delay -from [get_clocks {pixel_clk_5x}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only

# reset and the B->A link input are asynchronous (uart_rx_byte has its own 2FF)
set_false_path -from [get_ports {sys_rst_n}]
set_false_path -from [get_ports {uart_rx}]

# sync_2ff first stages: asynchronous inputs by construction
set_false_path -to [get_regs -hier {*/s1}]
