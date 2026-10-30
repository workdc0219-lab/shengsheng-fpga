# Read-only STA of the admitted A79315D9 DB. No route/fix_hold/export_db/bitgen.
set controls_sta_tools_dir [file dirname [file normalize [info script]]]
set controls_sta_candidate_root [file dirname $controls_sta_tools_dir]
set controls_sta_db [file join $controls_sta_candidate_root evidence student_seed1_route_only student_route_only_pr.db]
set controls_sta_pnl [file join $controls_sta_candidate_root evidence student_seed1_route_only after.pnl]
set controls_sta_outdir [file join $controls_sta_candidate_root evidence student_affected_reset_sta_v3]
if {[info exists ::env(AFFECTED_STA_OUT)]} {set controls_sta_outdir $::env(AFFECTED_STA_OUT)}
puts [exec python -X utf8 [file join $controls_sta_tools_dir check_affected_reset_sta.py] --prepare --db $controls_sta_db --pnl $controls_sta_pnl --outdir $controls_sta_outdir]
source [file join $controls_sta_outdir affected_plan.tcl]
cd $controls_sta_outdir
import_device eagle_s20.db -package EG4S20BG256
import_db $controls_sta_source_db
update_timing -mode final
puts [list CONTROLS_STA_PATH_DIAGNOSTIC pwd [pwd] outdir $controls_sta_outdir joined [file join $controls_sta_outdir sta_snapshot.pnl]]
cd $controls_sta_outdir
write_pnl sta_snapshot.pnl
foreach controls_sta_item $controls_sta_driver_plan {
    set controls_sta_label [lindex $controls_sta_item 0]
    set controls_sta_driver_name [lindex $controls_sta_item 1]
    set controls_sta_driver_pattern [lindex $controls_sta_item 2]
    set controls_sta_drv {}
    # Native releases differ in whether a bracketed name is treated literally.
    # Try the exact name, then glob-escaped spelling; accept only the same full
    # physical cell name, never a merely unique wildcard match to another cell.
    foreach controls_sta_query [lsort -unique [list $controls_sta_driver_name $controls_sta_driver_pattern]] {
        set controls_sta_found [get_cells -hier $controls_sta_query]
        puts "AFFECTED_DRIVER_QUERY $controls_sta_label query=$controls_sta_query count=[llength $controls_sta_found] value=$controls_sta_found"
        if {[llength $controls_sta_found] == 1 && [lindex $controls_sta_found 0] eq $controls_sta_driver_name} {
            set controls_sta_drv $controls_sta_found
            break
        }
    }
    if {[llength $controls_sta_drv] != 1} {error "Missing/ambiguous exact affected driver: $controls_sta_label"}
    puts "AFFECTED_DRIVER $controls_sta_label count=1 value=$controls_sta_drv"
    report_timing_path -from $controls_sta_drv -ep_num 65536 -path_num 1 -file affected_${controls_sta_label}.rpt
}
# Preserve all production clock groups and both corners, independently of the
# reset-only reports. The violation filter remains complete, not 10 endpoints.
report_timing_summary -file final_timing.rpt -ep_num 10 -path_num 1
report_timing_summary -file final_timing_violations.rpt -ep_num 65536 -path_num 1 -viol_only
report_timing_exception -file shengsheng_board_b_exception.timing
report_area -io_info -file shengsheng_board_b_phy.area
report_timing_status -file final_timing.ts
set controls_sta_done [open completed.txt w]
puts $controls_sta_done "AFFECTED_RESET_STA_COMPLETE=1"
puts $controls_sta_done "DB_SHA256=$controls_sta_expected_db_sha256"
close $controls_sta_done
puts "AFFECTED_RESET_STA_COMPLETE=1"
exit
