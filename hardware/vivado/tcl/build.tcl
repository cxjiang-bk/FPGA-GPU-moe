# All output paths belong to the new project; no hardware or driver operations.
lassign $argv project_root run_dir mode jobs
set report_dir $run_dir/reports
set reference $project_root/third_party/v80-platform
source $run_dir/inputs/sources.tcl
proc main {} {
  global project_root run_dir report_dir reference v80_sources mode jobs
  if {[version -short] ne "2026.1"} {error "Vivado 2026.1 required"}
  set_param general.maxThreads $jobs
  if {$mode eq "ooc"} {
    create_project v80_ooc $run_dir/project -part xcv80-lsva4737-2MHP-e-S
    add_files $v80_sources
    set_property top v80_opentpu_wrapper [current_fileset]
    update_compile_order -fileset sources_1
    synth_design -top v80_opentpu_wrapper -part xcv80-lsva4737-2MHP-e-S -mode out_of_context
    create_clock -name core_clk -period 13.333333 [get_ports core_clk]
    write_checkpoint $run_dir/v80_opentpu_ooc.dcp
    report_utilization -hierarchical -file $report_dir/utilization.rpt
    report_timing_summary -report_unconstrained -file $report_dir/timing.rpt
    check_timing -verbose -file $report_dir/check_timing.rpt
    set f [open $run_dir/OOC_COMPLETE w]; puts $f {OOC synthesis only; platform route and board validation pending.}; close $f
    close_project
    return
  }
  source $run_dir/inputs/package_opentpu.tcl
  create_project v80_opentpu $run_dir/project -part xcv80-lsva4737-2MHP-e-S
  set_property board_part xilinx.com:v80:part0:2.0 [current_project]
  set_property target_language Verilog [current_project]
  set_property segmented_configuration true [current_project]
  set_property ip_repo_paths [list $reference/amr/v80_base/ip $run_dir/ip_repo] [current_project]
  update_ip_catalog
  add_files $reference/m3/stage3/lpu_completion_status.sv
  # Apply the reference's explicit four HBM P/N corrections in this build only.
  exec $project_root/.venv/bin/python $reference/m3/stage6_impl/prepare_pins.py \
    $reference/amr/v80_base/xdc/impl.pins.xdc $run_dir/inputs/impl.pins.v80.xdc
  add_files -fileset constrs_1 $run_dir/inputs/impl.pins.v80.xdc
  set_property used_in_synthesis false [get_files $run_dir/inputs/impl.pins.v80.xdc]
  source $run_dir/inputs/v80_opentpu_bd.tcl
  set bd [get_files */bd/v80_platform/v80_platform.bd]
  if {[llength $bd] != 1} {error "platform BD was not created"}
  open_bd_design $bd
  set pin [get_bd_intf_pins smbus_hier/smartconnect_0/M00_AXI]
  set_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC USER $pin
  set_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC DEFAULT $pin
  source $reference/m3/stage6_impl/configure_bar2.tcl
  validate_bd_design
  foreach channel {AW W B AR R} {set_property CONFIG.REG_$channel 1 [get_bd_cells u_lpu_mem_regslice]}
  validate_bd_design
  set work $report_dir
  source $reference/m3/stage3/audit_bd.tcl
  # Add the new compute identity to the legacy platform shape checks.
  if {[get_property VLNV [get_bd_cells u_lpu_addremap]] ne "user.org:user:v80_opentpu_wrapper:1.0"} {
    error "wrong compute IP: expected openTPU wrapper"
  }
  set f [open $report_dir/compute_identity.txt w]
  puts $f {openTPU compute; legacy RV ports/IRQ pins idle; task ABI at BAR2+0x10000.}
  close $f
  save_bd_design
  generate_target all $bd
  add_files [make_wrapper -files $bd -top]
  set_property top v80_platform_wrapper [current_fileset]
  update_compile_order -fileset sources_1
  report_ip_status -file $report_dir/ip_status.rpt
  m3_verify_bar2_attributes
  if {$mode eq "check"} {
    set f [open $run_dir/CHECK_COMPLETE w]; puts $f {IP/BD validation and generated products only; no synthesis or board run.}; close $f
    close_project
    return
  }
  launch_runs synth_1 -jobs $jobs
  wait_on_run synth_1
  if {![string match "synth_design Complete*" [get_property STATUS [get_runs synth_1]]]} {error "platform synthesis failed"}
  if {[string match {Vivado Advanced Implementation*} [get_property FLOW [get_runs impl_1]]]} {
    set_property strategy {Vivado Advanced Implementation Defaults} [get_runs impl_1]
  }
  launch_runs impl_1 -to_step route_design -jobs $jobs
  wait_on_run impl_1
  if {![string match "route_design Complete*" [get_property STATUS [get_runs impl_1]]]} {error "platform route failed"}
  open_run impl_1
  write_checkpoint $run_dir/v80_platform_routed.dcp
  report_timing_summary -report_unconstrained -file $report_dir/timing.rpt
  report_utilization -hierarchical -file $report_dir/utilization.rpt
  report_cdc -details -file $report_dir/cdc.rpt
  report_drc -file $report_dir/drc.rpt
  report_bus_skew -file $report_dir/bus_skew.rpt
  check_timing -verbose -file $report_dir/check_timing.rpt
  set f [open $run_dir/ROUTE_COMPLETE w]; puts $f {Route completed; report review required before image packaging.}; close $f
  close_project
}
if {[catch {main} message options]} {
  set f [open $run_dir/failure.txt w]; puts $f $message; puts $f [dict get $options -errorinfo]; close $f
  puts stderr "V80_BUILD_FAILED: $message"
  exit 1
}
exit 0
