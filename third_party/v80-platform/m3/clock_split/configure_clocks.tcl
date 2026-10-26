# Apply to the M3 BD after restoring stage2 and renaming its instances, or to
# the current stage3 BD. No LPU RTL changes and no timing exceptions.
proc m3_disconnect_pin {path} {
    set pin [get_bd_pins $path]
    foreach net [get_bd_nets -quiet -of_objects $pin] {disconnect_bd_net $net $pin}
}
proc m3_connect_pins {source target} {
    set a [get_bd_nets -quiet -of_objects [get_bd_pins $source]]
    set b [get_bd_nets -quiet -of_objects [get_bd_pins $target]]
    if {[llength $a] && $a eq $b} {return}
    m3_disconnect_pin $target
    connect_bd_net [get_bd_pins $source] [get_bd_pins $target]
}
proc m3_refresh_smbus_metadata {} {
    # The value is read-only. Re-enable automatic propagation after changing
    # the design; never force MAX_BURST_LENGTH itself or normalize the audit.
    set pin [get_bd_intf_pins smbus_hier/smartconnect_0/M00_AXI]
    puts "SMBUS_REFRESH_BEFORE [get_property CONFIG.MAX_BURST_LENGTH $pin] [get_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC $pin]"
    set_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC USER $pin
    set_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC DEFAULT $pin
    validate_bd_design
    puts "SMBUS_REFRESH_AFTER [get_property CONFIG.MAX_BURST_LENGTH $pin] [get_property CONFIG.MAX_BURST_LENGTH.VALUE_SRC $pin]"
}
proc m3_configure_split_clocks {} {
    current_bd_instance /
    if {[llength [get_bd_cells -quiet u_clk_gen]]} {
        # Keep the existing output nets and every consumer attached to them.
        set core_net [get_bd_nets -of_objects [get_bd_pins u_clk_gen/clk_out1]]
        set mem_net [get_bd_nets -of_objects [get_bd_pins u_clk_gen/clk_out2]]
        set_property NAME core_clk $core_net
        set_property NAME mem_axi_clk $mem_net
        delete_bd_objs [get_bd_cells u_clk_gen]
    } elseif {![llength [get_bd_cells -quiet u_core_clk_gen]]} {
        error {Expected the legacy clock generator or the split clock generators}
    }
    foreach {name source input output netname} {
        u_mem_clk_gen cips/pl0_ref_clk 100.000 400.000 mem_axi_clk
        u_core_clk_gen cips/pl1_ref_clk 33.3333333 75.000 core_clk
    } {
        # Use the propagated actual frequency, not the rounded request. CIPS
        # reports PL1 as 33333332 Hz in this device/configuration.
        set input [expr {double([get_property CONFIG.FREQ_HZ [get_bd_pins $source]])/1000000.0}]
        if {![llength [get_bd_cells -quiet $name]]} {
            create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard:1.0 $name
        }
        set_property -dict [list CONFIG.PRIMITIVE_TYPE MMCM CONFIG.PRIM_SOURCE No_buffer \
            CONFIG.PRIM_IN_FREQ $input CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
            CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY "$output,100.000,100.000,100.000,100.000,100.000,100.000" \
            CONFIG.USE_LOCKED true CONFIG.USE_RESET true CONFIG.RESET_TYPE ACTIVE_LOW] [get_bd_cells $name]
        m3_connect_pins $source $name/clk_in1
        if {[get_bd_nets -quiet -of_objects [get_bd_pins $name/clk_out1]] ne [get_bd_nets $netname]} {
            m3_disconnect_pin $name/clk_out1
            connect_bd_net -net $netname [get_bd_pins $name/clk_out1]
        }
        # Reset directly from CIPS: never depend on a reset held by our locked
        # outputs, which would create a circular wait during power-on.
        m3_connect_pins cips/pl0_resetn $name/resetn
    }
    if {![llength [get_bd_cells -quiet u_clocks_locked]]} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 u_clocks_locked
    }
    set_property -dict [list CONFIG.C_SIZE 1 CONFIG.C_OPERATION and] [get_bd_cells u_clocks_locked]
    m3_connect_pins u_mem_clk_gen/locked u_clocks_locked/Op1
    m3_connect_pins u_core_clk_gen/locked u_clocks_locked/Op2
    # PG247 requires overlapping reset of SmartConnect and connected endpoints.
    # Either clock losing lock therefore holds all three communicating domains
    # in reset; each proc_sys_reset releases in its own clock domain.
    foreach name {u_ctrl_reset u_core_reset u_mem_axi_reset} {
        m3_disconnect_pin $name/dcm_locked
        connect_bd_net [get_bd_pins u_clocks_locked/Res] [get_bd_pins $name/dcm_locked]
        # proc_sys_reset aux_reset_in is ACTIVE_LOW in the generated IP.
        # Leave this unused input at its declared default tie-high, exactly as
        # the platform ctrl reset does. Tying it to zero holds reset forever.
        m3_disconnect_pin $name/aux_reset_in
    }
    # Remove only abandoned zero-endpoint scalar nets from the old generator.
    foreach net [get_bd_nets -quiet] {
        if {![llength [get_bd_pins -quiet -of_objects $net]] && ![llength [get_bd_ports -quiet -of_objects $net]]} {
            delete_bd_objs $net
        }
    }
}
