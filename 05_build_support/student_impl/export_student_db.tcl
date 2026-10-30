# Portable same-A793-DB export only. This script has NOT been TD-executed.
# No synthesis, placement, routing, parameter changes, or programmer access.
set controls_pkg_dir [file dirname [file normalize [info script]]]
puts [exec python -X utf8 [file join $controls_pkg_dir prepare_impl.py] --verify-extracted]
set controls_pkg_db [file join $controls_pkg_dir work route_only student_route_only_pr.db]
set controls_pkg_output [file join $controls_pkg_dir work export]
if {![file isfile $controls_pkg_db]} {error "Missing verified A793 database; run prepare_impl.py --extract"}
if {[file exists $controls_pkg_output]} {error "Refusing to overwrite work/export"}
file mkdir $controls_pkg_output
cd $controls_pkg_output
import_device eagle_s20.db -package EG4S20BG256
import_db $controls_pkg_db
set controls_pkg_rc [catch {get_param route disable_lut_bridge} controls_pkg_value]
if {$controls_pkg_rc == 0 && $controls_pkg_value == "on"} {error "Unexpected experimental routing parameter"}
write_pnl before_bitgen.pnl
bitgen -bit shengsheng_board_b.bit -fuse student.fuse -info -log_file bitgen.log
write_pnl after_bitgen.pnl
puts [exec python -X utf8 [file join $controls_pkg_dir prepare_impl.py] --verify-extracted]
puts "CONTROLS_STUDENT_PORTABLE_EXPORT_COMPLETE=1"
exit
