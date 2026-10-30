# Stage 1: canonical fixed-seed synthesis/route and final STA; no bitgen.
# Board B (training screen) TD build. Mirrors the single-board
# board/player_shengsheng/scripts/run_td.tcl flow; all RTL lives flat in
# board_b/src, so the only staging is (a) the sdram.v -> enc_file include
# layout TD's include search expects, and (b) classifier_lut.hex, which the
# synthesis-time $readmemh in lookup_classifier resolves against the tool's
# working directory -- copies are scattered over every plausible CWD so the
# build cannot fail on path resolution.
set script_path [file normalize [info script]]
set script_dir [file normalize [file join [file dirname $script_path] .. student_B board_b scripts]]
set board_root [file dirname $script_dir]
set dual_root [file normalize [file join $board_root ..]]
set run_dir_name "td_shengsheng_b_run"
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
file mkdir [file join $project_root src sdram enc_file]

# sdram.v includes "enc_file/global_def.v" relative to its own directory
file copy -force [file join $board_root src sdram.v] \
    [file join $project_root src sdram sdram.v]
file copy -force [file join $board_root src enc_file global_def.v] \
    [file join $project_root src sdram enc_file global_def.v]

# the trained classifier table. TD resolves $readmemh against the SOURCE
# file directory first (HDL-5105 names it; the first build failed to find
# the hex in the project/syn directories and synthesized an undriven BRAM),
# so the canonical copy must sit in board_b/src next to lookup_classifier.v.
file copy -force [file join $dual_root tools classifier_lut.hex] \
    [file join $board_root src classifier_lut.hex]

create_project -family EG4 -device EG4S20BG256 shengsheng_board_b $project_root
foreach f {
    afifo_32_16_256.v audio_arc_calculate.v audio_probe_d4.v audio_reference_d3.v badge_journal.v bmp24_decoder.v
    button_event.v
    config_flash_journal.v config_journal.v dual_key_chord_router.v
    dual_key_long_hold_guard.v fat32_file_streamer.v fat32_volume_scanner.v
    fifo_prefetch_2.v global_def.v hdmi_1_4b_transmitter_core_wrapper.enc.v
    hdmi_phy_warpper.v lane_lvds_10_1.v lookup_classifier.v
    media_frame_loader.v media_frame_reader.v media_ingest_frontend.v
    media_ingest_pipeline.v media_player_control.v media_sdram_write_cdc.v
    media_storage_ingest_top.v media_video_pipeline.v osd_overlay_24.v
    param_menu_controller.v pcm_media_music_v8.v player_config_persistence.v
    spectrum_analyzer_v8.v osd_spectrum_v8.v
    promax_audio_waveform.v promax_text_overlay.v reset_sync.v
    rgb_video_adapter.v sd_media_service.v sd_sector_replay_buffer.v
    sd_spi_byte_engine.v sd_spi_command.v sd_spi_init.v sd_spi_sector_reader.v
    sdr_as_ram.enc.v sdr_init_ref.enc.v sdr_wrrd.enc.v
    shengsheng_board_b_top.v shengsheng_game.v shengsheng_overlay.v
    spi_byte_engine.v ss_badge_rom.v ss_exp2_rom.v ss_log2_rom.v ss_phrase_rom.v
    ss_score_reporter.v ss_score_reporter_b.v ss_sine_rom.v startup_pulse.v
    status_osd_overlay.v subtitle_frame_commit.v sync_2ff.v
    osd_param_panel_v8.v osd_panel_rom_v8.v osd_caption_layer_v8.v osd_caption_rom_v8.v
    sys_pll_promax_40.v tone_scorer.v
    uart_rx_byte.v uart_rx_feature.v uart_tx_byte.v video_fade_transition.v
    video_rgb_to_axis_640x480.v video_timing_ctrl.v voice_model_synth.v
    w25q64_preflight_reader.v w25q64_record_store.v
    seven_seg_display.v buzzer_feedback.v
    result_packet_tx.v v7_link_b.v v7_packet_tx.v v7_packet_rx.v
} {
    add_files [file join $board_root src $f]
}
add_files [file join $project_root src sdram sdram.v]
add_files [file join $board_root constraints board_b_top.adc]
add_files [file join $board_root constraints board_b_top.sdc]
top_module shengsheng_board_b_top
# B board is near the mslice place limit (PHY-9009 at 5071 vs 4900 with the
# F1/F3 additions): bias the gate mapper to area. The params MUST be set
# before launch_runs syn_1 -- set after, they never reached the mapper
# (three builds produced byte-identical 5132/5071 counts). The build gate
# still checks post-route timing, so a timing regression cannot slip
# through.
set_param -run syn_1 gate opt_area high
set_param -run syn_1 gate map_seed 2
launch_runs syn_1 -step opt_gate -jobs 1
wait_run syn_1
# SWUG105 sections 4.1.14/4.2. No post-launch settings.cfg race.
# Prefer packing LUT pairs to recover room for the tool's hold repair.
# This changes implementation strategy, not HDL behavior or SDC timing.
set_param -run phy_1 place seed $place_seed
set_param -run phy_1 place effort high
set_param -run phy_1 place pack_mode more_lut_pair
set_param -run phy_1 route effort routability
set_param -run phy_1 route fix_hold on
launch_runs phy_1 -step opt_route -jobs 1
wait_run phy_1
set phy_root [file join $project_root shengsheng_board_b_Runs phy_1]
if {![file exists [file join $phy_root shengsheng_board_b_pr.db]]} {
    error "No routed database from the current clean Board B run"
}
open_run phy_1
# SWUG105 section 4.6.2 and the bundled DefaultFlow.tcl expose standalone
# fix_hold for routed designs. The router's built-in attempt can stop with
# "Too much hold violation" while this deterministic post-route pass repairs
# the remaining paths. No constraint or uncertainty is changed. This pass is
# always run BEFORE bitgen, so reports and bits describe the same repaired DB.
update_timing -mode final
report_timing_summary -file [file join $phy_root before_fix_hold.rpt] -ep_num 10 -path_num 1
fix_hold
update_timing -mode final
export_db [file join $phy_root shengsheng_board_b_pr.db]
write_pnl [file join $phy_root controls_student.pnl]
write_verilog [file join $phy_root controls_student_out.v]
# Full statistics must retain healthy clock groups, even when all paths pass.
report_timing_summary -file [file join $phy_root final_timing.rpt] -ep_num 10 -path_num 1
report_timing_summary -file [file join $phy_root final_timing_violations.rpt] -ep_num 65536 -path_num 1 -viol_only
report_timing_exception -file [file join $phy_root shengsheng_board_b_exception.timing]
report_area -io_info -file [file join $phy_root shengsheng_board_b_phy.area]
puts "CONTROLS_STUDENT_STAGE1_COMPLETE=1"
close_project
exit
