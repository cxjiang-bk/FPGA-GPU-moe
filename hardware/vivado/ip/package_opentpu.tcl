# Invoked from build.tcl. Package an interface stub, then attach the exact real RTL snapshot.
set ip_root $run_dir/ip_repo/v80_opentpu_wrapper_1_0
file mkdir $ip_root
set top_file $run_dir/inputs/rtl/v80_opentpu_wrapper.sv
set fh [open $top_file r]; set text [read $fh]; close $fh
set boundary [string first "\n);" $text]
if {$boundary < 0} {error "wrapper port boundary missing"}
set stub $run_dir/inputs/v80_interface.v
set fh [open $stub w]
puts $fh "[string range $text 0 [expr {$boundary+3}]]\nendmodule"
close $fh
create_project v80_ip $run_dir/ip_pack -part xcv80-lsva4737-2MHP-e-S
set_property target_language Verilog [current_project]
add_files $stub
set_property top v80_opentpu_wrapper [current_fileset]
ipx::package_project -root_dir $ip_root -vendor user.org -library user -taxonomy /UserIP -import_files
set core [ipx::current_core]
set_property name v80_opentpu_wrapper $core
set_property version 1.0 $core
set_property display_name {V80 single-slice openTPU} $core
set_property description {openTPU control, native-word-address AXI bridge and fixed 4 GiB HBM remap; legacy RV masters idle.} $core
set_property supported_families {versal Production} $core
foreach group [ipx::get_file_groups -of_objects $core] {
  if {![string match *gui* [get_property NAME $group]]} {ipx::remove_file_group [get_property NAME $group] $core}
}
foreach kind {synthesis simulation} {ipx::add_file_group -type $kind {} $core}
set groups [list [ipx::get_file_groups xilinx_anylanguagesynthesis -of_objects $core] [ipx::get_file_groups xilinx_anylanguagebehavioralsimulation -of_objects $core]]
foreach group $groups {set_property model_name v80_opentpu_wrapper $group}
file mkdir $ip_root/hdl
foreach source $v80_sources {
  set relative hdl/[file tail $source]
  file copy $source $ip_root/$relative
  foreach group $groups {
    set f [ipx::add_file $relative $group]
    set_property type systemVerilogSource $f
    set_property library_name xil_defaultlib $f
  }
}
foreach kind {xilinx.com:interface:aximm_rtl:1.0 xilinx.com:signal:clock_rtl:1.0 xilinx.com:signal:reset_rtl:1.0} {
  ipx::infer_bus_interfaces $kind $core
}
# Clock frequency is propagated from the platform generator (74,999,997 Hz in M3).
# Keep this IP reusable in that exact domain; do not hard-code a rounded 75 MHz.
set mm [ipx::get_memory_maps S_AXI -of_objects $core]
if {[llength $mm] == 0} {set mm [ipx::add_memory_map S_AXI $core]}
set block [ipx::get_address_blocks reg0 -of_objects $mm]
if {[llength $block] == 0} {set block [ipx::add_address_block reg0 $mm]}
source $run_dir/inputs/generated/registers.tcl
# This NoC path preserves the low AXI address bits. Declare the actual BAR2+0x10000
# aperture; the compute core decodes register offsets from the low 12 bits.
set_property base_address $v80_control_offset $block
set_property range $v80_control_bytes $block
set_property width 32 $block
set_property usage register $block
set_property slave_memory_map_ref S_AXI [ipx::get_bus_interfaces S_AXI -of_objects $core]
ipx::check_integrity $core
ipx::update_checksums $core
ipx::save_core $core
close_project
