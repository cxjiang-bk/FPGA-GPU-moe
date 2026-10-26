# Offline AMR segmented image export from the completed M3 implementation.
# This creates build artifacts only. It does not program or access a board.
lassign $argv run_dir pin_xdc
if {[catch {
    set output_dir $run_dir/artifacts
    file mkdir $output_dir
    open_project $run_dir/project/m3_impl.xpr
    if {[get_property STATUS [get_runs impl_1]] ne "route_design Complete!"} {
        error "Completed route_design is required"
    }
    if {![get_property SEGMENTED_CONFIGURATION [current_project]]} {
        error "Expected AMR segmented configuration"
    }
    set_param general.maxThreads 8
    open_run impl_1
    # These assignments align the original XDC with the fixed HBM pin mapping.
    # Assert they do not move any routed pin before generating the image.
    foreach {p expected} {
        {hbm_ref_clk_0_clk_p[0]} N19 {hbm_ref_clk_0_clk_n[0]} N18
        {hbm_ref_clk_1_clk_p[0]} N37 {hbm_ref_clk_1_clk_n[0]} N38
    } {
        if {[get_property PACKAGE_PIN [get_ports $p]] ne $expected} {
            error "Unexpected HBM physical mapping at $p"
        }
    }
    read_xdc $pin_xdc
    set_property SEGMENTED_CONFIGURATION true [current_design]
    set_property XPM_LIBRARIES {XPM_CDC XPM_FIFO XPM_MEMORY} [current_project]
    cd $output_dir
    write_device_image -force $output_dir/M3.pdi
    foreach kind {boot pld} {
        if {![file exists $output_dir/M3_${kind}.pdi]} {error "Missing $kind PDI"}
    }
    write_hw_platform -fixed -include_bit -force $output_dir/M3.xsa
    validate_hw_platform -verbose $output_dir/M3.xsa
    set f [open $run_dir/IMAGE_EXPORT_COMPLETE w]
    puts $f {Offline artifacts generated; see signoff.json before deployment.}
    close $f
    close_project
} message options]} {
    puts stderr "M3_IMAGE_EXPORT_FAILED: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
