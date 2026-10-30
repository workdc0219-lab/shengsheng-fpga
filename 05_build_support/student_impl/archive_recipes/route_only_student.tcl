# P1-04/P1-05: remove the two current-DB functional reset bridges only.
# No synthesis, placement, logic edit, fix_hold, bitgen or board access.
set candidate_root [file dirname [file dirname [file normalize [info script]]]]
set input_db [file join $candidate_root student_B td_shengsheng_b_run shengsheng_board_b_Runs phy_1 shengsheng_board_b_pr.db]
set output_dir [file join $candidate_root evidence student_seed1_route_only]
if {![file isfile $input_db]} {error "Missing SHA-pinned Stage1 database"}
if {[file exists $output_dir]} {error "Refusing to overwrite route-only evidence"}
file mkdir $output_dir
cd $output_dir
import_device eagle_s20.db -package EG4S20BG256
import_db $input_db
set targets {
    u_hdmi14_core/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_receiver_controller/I_rst_dup_13
    u_hdmi14_core/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_receiver_controller/I_rst_dup_27
}
proc snapshot_net {tag net} {
    set found [get_nets $net]
    if {[llength $found] != 1} {error "Ambiguous/missing target net: $net"}
    puts "RESET_NET_BEGIN_${tag}_$net"
    report_nets $found -connection -pin_display_limit 1000 -dr
    puts "RESET_NET_END_${tag}_$net"
}
write_pnl before.pnl
foreach target $targets {snapshot_net BEFORE $target}
mpnr_unroute_net -net $targets
mpnr_route_net -net $targets
mpnr_save_revert -save
foreach target $targets {snapshot_net AFTER $target}
write_pnl after.pnl
write_verilog after.v
export_db student_route_only_pr.db
drc_check -route -verbose
update_timing -mode final
report_timing_summary -file final_timing.rpt -ep_num 10 -path_num 1
report_timing_summary -file final_timing_violations.rpt -ep_num 65536 -path_num 1 -viol_only
report_timing_exception -file shengsheng_board_b_exception.timing
report_area -io_info -file shengsheng_board_b_phy.area
puts "CONTROLS_STUDENT_ROUTE_ONLY_COMPLETE=1"
exit
