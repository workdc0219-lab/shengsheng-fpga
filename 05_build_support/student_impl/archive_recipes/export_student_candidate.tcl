# Final same-DB export. External gate admission is required before this runs.
# No synthesis, placement, routing, parameter changes or hardware access.
set root [file dirname [file dirname [file normalize [info script]]]]
set output [file join $root evidence student_final_export]
if {[file exists $output]} {error "Refusing to overwrite final candidate export"}
file mkdir $output
cd $output
import_device eagle_s20.db -package EG4S20BG256
import_db [file join $root evidence student_seed1_route_only student_route_only_pr.db]
# The parameter experiments are not the chosen candidate input.
set rc [catch {get_param route disable_lut_bridge} value]
if {$rc == 0 && $value == "on"} {error "Unexpected experimental routing parameter"}
write_pnl before_bitgen.pnl
bitgen -bit shengsheng_board_b.bit -fuse student.fuse -info -log_file bitgen.log
write_pnl after_bitgen.pnl
puts "CONTROLS_STUDENT_FINAL_EXPORT_COMPLETE=1"
exit
