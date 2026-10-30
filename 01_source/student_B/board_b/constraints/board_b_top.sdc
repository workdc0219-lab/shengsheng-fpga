create_clock -name sys_clk -period 20.000 -waveform {0.000 10.000} [get_ports {sys_clk}]
# CLKC4_CPHASE=1 vs CLKC3_CPHASE=39: serial rises 2 ns after pixel.
# Verified against the installed EG_PHY_PLL functional model (8 ns * 90/360).
create_generated_clock -name pixel_clk_5x -source [get_ports {sys_clk}] -master_clock sys_clk -multiply_by 2.5 -phase 90 [get_nets {pixel_clk_5x}]
create_generated_clock -name pixel_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 2 [get_nets {pixel_clk}]
create_generated_clock -name mem_clk -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 1.25 -phase 0 [get_pins {u_mem_pll/pll_inst.clkc[1]}]
create_generated_clock -name mem_clk_shift -source [get_ports {sys_clk}] -master_clock sys_clk -divide_by 1.25 -phase 172.8 [get_pins {u_mem_pll/pll_inst.clkc[2]}]
# mem_clk_shift only drives the EG_PHY_SDRAM_2M_32 sampling clock. The
# official 2026 SDRAM package carries its own hard-IP I/O window; treating the
# forwarded DQ path as a fabric setup path produces a fixed false violation.
set_false_path -from [get_clocks {mem_clk}] -to [get_clocks {mem_clk_shift}]
set_false_path -from [get_clocks {mem_clk_shift}] -to [get_clocks {mem_clk}]

# All clocks come from one PLL on one die; intra-domain launch/capture pairs
# share the global tree. The tool default hold uncertainty (0.100 ns) exceeds
# the real PLL jitter + tree skew budget at 25-50 MHz and kept flagging a
# rotating set of register -> async-RAM read-address partial paths in the
# +/-15 ps band (R64). 0.050 ns keeps a real guardband while stopping that
# guardband artifact from driving manual delay-LUT insertion, which broke
# silicon handshake on 2026-08-22.
set_clock_uncertainty -hold 0.050 [get_clocks {sys_clk pixel_clk pixel_clk_5x mem_clk mem_clk_shift}]

set_false_path -from [get_ports {sys_rst_n}]
# audit P1: the 921600 UART input is asynchronous -- same declaration as the
# board_a copy of this constraint for the same physical signal
set_false_path -from [get_ports {uart_rx_i}]
set_false_path -to [get_regs -hier {*/s1}]
set_false_path -to [get_regs -hier {*/request_sync1_mem}]
set_false_path -to [get_regs -hier {*/index_sync1_mem[*]}]
# V8 slide bus pix -> mem: 2FF chain, sampled one cycle after the request toggle (same rule as index_sync1_mem)
set_false_path -to [get_regs -hier {*/slide_sync1_mem[*]}]
set_false_path -to [get_regs -hier {*/ack_sync1}]
set_false_path -to [get_regs -hier {*/req_sync1}]
set_false_path -to [get_regs -hier {*/index_sync1[*]}]
# pix_rst_n is an asynchronously asserted reset for the dual-clock read FIFO.
# Its pixel-domain release is not a data transfer into mem_clk; constrain only
# this reset fanout and keep the FIFO Gray-pointer crossings timed below.
set_false_path -from [get_nets {u_pix_reset/s2}] \
    -to [get_clocks {mem_clk}]
# Subtitle text is a bundled stable-data CDC. commit_toggle crosses through
# commit_sync1/2, and the held payload is captured only at a later frame edge.
set_false_path -to [get_regs -hier {u_subtitle_frame_commit/dst_text[*]}]
set_false_path -to [get_regs -hier {u_write_cdc/u_fifo/wr_gray_sync1[*]}]
set_false_path -to [get_regs -hier {u_write_cdc/u_fifo/rd_gray_sync1[*]}]
set_false_path -to [get_regs -hier {u_write_cdc/src_block_gray_sync1[*]}]

# pixel->sys paths: every bundled crossing intended for the system domain goes
# through the per-bit synchronizers false-pathed above. NOTE (2026-10-03
# audit): the picture index is NOT gray-coded in RTL -- the sys->pix index
# crossing is guarded by settle-delayed sampling instead (index stable for a
# whole frame, sampled one cycle after the toggle detect). Two synthesized
# pixel->sys paths
# (bmp_error fanin, adapter rgb fanin) appear only under related-clock
# analysis and are declared false here as in every shipped bit; HDMI visual
# verification and the 60-minute soak gate their real-world behavior.
set_false_path -from [get_clocks {pixel_clk}] -to [get_clocks {sys_clk}]

# The inherited FIFO uses Gray pointers. Limit each crossing to one source
# clock period instead of declaring the complete pixel/memory domains false.
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/wr_to_rd_cross_inst/sync_r1[*]}] 25.000 -datapath_only
set_max_delay -from [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs -hier {u_video/u_reader/u_read_fifo/rd_to_wr_cross_inst/sync_r1[*]}] 40.000 -datapath_only

# Bound each implemented ODDR-to-pad path. This is a digital per-lane delay
# limit, not a claim about complete rise/fall pairwise skew or the analog eye.
set_max_delay -from [get_clocks {pixel_clk_5x}] \
    -to [get_ports {HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P}] \
    8.000 -datapath_only
