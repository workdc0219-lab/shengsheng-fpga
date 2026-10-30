# Board A (signal acquisition + feature extraction) TD build.
# Small design: mic front end + YIN pitch tracker + UART feature packer on
# the same sys_pll_promax_40 clocking the single board uses, so the audio
# chain timing (and the 217-clk UART bit time) is identical to Board B.
set script_path [file normalize [info script]]
set script_dir [file dirname $script_path]
set board_root [file dirname $script_dir]
set dual_root [file normalize [file join $board_root ..]]
set run_dir_name "td_shengsheng_a_run"
if {[info exists ::env(TD_RUN_DIR)] && $::env(TD_RUN_DIR) ne ""} {
    set run_dir_name $::env(TD_RUN_DIR)
}
set project_root [file normalize [file join $dual_root $run_dir_name]]
if {[file dirname $project_root] ne $dual_root || ![string match "td_shengsheng_*" [file tail $project_root]]} {
    error "Refusing to delete/build outside a named project run directory: $project_root"
}

puts "TD_SCRIPT=$script_path"
puts "TD_PROJECT=$project_root"
puts "DUAL_ROOT=$dual_root"

set place_seed 1
if {[info exists ::env(TD_PLACE_SEED)] && [string is integer -strict $::env(TD_PLACE_SEED)]} {
    set place_seed $::env(TD_PLACE_SEED)
}
puts "PLACE_SEED=$place_seed"

if {[catch {file delete -force $project_root} delete_error]} {
    error "Cannot create clean run directory: $project_root ($delete_error)"
}
file mkdir $project_root

create_project -family EG4 -device EG4S20BG256 shengsheng_board_a $project_root
foreach f {
    agc_tap.v dtw_matcher.v feature_packer.v formant_picker.v
    global_def.v goertzel_sband.v nb_fallback.v
    mic_adc_frontend.v single_mic_control.v pitch_tracker.v reset_sync.v stream_uart.v
    vq_cycle.v
    shengsheng_board_a_top.v ss_exp2_rom.v ss_log2_rom.v
    sys_pll_promax_40.v uart_tx_byte.v
    contour_capture.v result_packet_rx.v uart_rx_byte.v
    v7_link_a.v v7_packet_tx.v v7_packet_rx.v
    teacher_console.v console_text_rom.v video_timing_ctrl.v
    console_scope_v8.v goertzel_8band.v
    training_journal.v w25q64_record_store.v spi_byte_engine.v
    audio_arc_calculate.v hdmi_1_4b_transmitter_core_wrapper.enc.v
    hdmi_phy_warpper.v lane_lvds_10_1.v
} {
    add_files [file join $board_root src $f]
}
add_files [file join $board_root constraints board_a_top.adc]
add_files [file join $board_root constraints board_a_top.sdc]
top_module shengsheng_board_a_top
launch_runs syn_1 -step opt_gate -jobs 1
wait_run syn_1
# SWUG105 (2024.11), sections 4.1.14/4.2: run-scoped parameters
# must be set BEFORE launch. Never patch a running settings.cfg.
set_param -run phy_1 place seed $place_seed
set_param -run phy_1 place effort high
set_param -run phy_1 route effort routability
set_param -run phy_1 route fix_hold on
launch_runs phy_1 -step bitgen -jobs 1
wait_run phy_1
set phy_root [file join $project_root shengsheng_board_a_Runs phy_1]
if {![file exists [file join $phy_root shengsheng_board_a.bit]]} {
    error "No bitstream from the current clean Board A run"
}
open_run phy_1
update_timing
# Keep healthy clock-group statistics in the release gate; enumerate all
# violating endpoints separately, without filtering away a clean design.
report_timing_summary -file [file join $phy_root final_timing.rpt] -ep_num 10 -path_num 1
report_timing_summary -file [file join $phy_root final_timing_violations.rpt] -ep_num 65536 -path_num 1 -viol_only
report_timing_exception -file [file join $phy_root shengsheng_board_a_exception.timing]
report_area -io_info -file [file join $phy_root shengsheng_board_a_phy.area]
puts "TD_SHENGSHENG_A_BUILD_COMPLETE=1"
close_project
exit
