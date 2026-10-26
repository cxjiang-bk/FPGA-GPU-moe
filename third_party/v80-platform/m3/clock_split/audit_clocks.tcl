proc m3_audit_split_clocks {fh} {
    m3_expect [llength [get_bd_cells -quiet u_clk_gen]] 0 {legacy generator removed}
    m3_expect [llength [get_bd_cells -hier -filter {VLNV =~ xilinx.com:ip:clk_wizard:*}]] 2 {two Clocking Wizards}
    m3_same_net cips/pl0_ref_clk u_mem_clk_gen/clk_in1
    m3_same_net cips/pl1_ref_clk u_core_clk_gen/clk_in1
    m3_same_net cips/pl0_ref_clk u_ctrl_reset/slowest_sync_clk
    m3_same_net u_mem_clk_gen/clk_out1 u_mem_axi_reset/slowest_sync_clk
    m3_same_net u_core_clk_gen/clk_out1 u_core_reset/slowest_sync_clk
    m3_same_net u_core_clk_gen/clk_out1 u_lpu_addremap/core_clk
    m3_same_net u_core_reset/peripheral_aresetn u_lpu_addremap/core_resetn
    foreach {name freq} {u_mem_clk_gen 400000000 u_core_clk_gen 75000000} {
        m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_pins $name/clk_out1]] $freq "$name output frequency"
        m3_expect [get_property CONFIG.RESET_TYPE [get_bd_cells $name]] ACTIVE_LOW "$name reset polarity"
        m3_same_net cips/pl0_resetn $name/resetn
    }
    m3_expect [get_property CONFIG.FREQ_HZ [get_bd_pins cips/pl0_ref_clk]] 100000000 {direct ctrl frequency}
    set f1 [get_property CONFIG.FREQ_HZ [get_bd_pins u_core_clk_gen/clk_in1]]
    if {abs($f1-33333333)>2} {error "Unexpected PL1 reference frequency: $f1"}
    foreach reset {u_ctrl_reset u_core_reset u_mem_axi_reset} {
        m3_same_net cips/pl0_resetn $reset/ext_reset_in
        m3_same_net u_clocks_locked/Res $reset/dcm_locked
        m3_expect [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells $reset]] 0 "$reset polarity"
        m3_expect [get_property CONFIG.C_AUX_RESET_HIGH [get_bd_cells $reset]] 0 "$reset auxiliary reset polarity"
        m3_expect [llength [get_bd_nets -quiet -of_objects [get_bd_pins $reset/aux_reset_in]]] 0 "$reset unused auxiliary reset uses inactive default"
    }
    m3_same_net u_mem_clk_gen/locked u_clocks_locked/Op1
    m3_same_net u_core_clk_gen/locked u_clocks_locked/Op2
    m3_expect [get_property CONFIG.C_OPERATION [get_bd_cells u_clocks_locked]] and {combined lock AND}
    m3_expect [get_property CONFIG.C_SIZE [get_bd_cells u_clocks_locked]] 1 {combined lock width}
    foreach cell {u_lpu_mem_bridge u_rvi_axi_cdc u_rvd_axi_cdc u_rvu_axi_cdc u_lpu_ctrl_sc} {
        set d0 [get_property CONFIG.CLK_DOMAIN [get_bd_pins $cell/aclk]]
        set d1 [get_property CONFIG.CLK_DOMAIN [get_bd_pins $cell/aclk1]]
        if {$d0 eq $d1 || $d0 eq "" || $d1 eq ""} {error "$cell must have distinct clock domains: $d0 $d1"}
        puts $fh "CLOCK_DOMAINS $cell $d0 -> $d1 (generated CDC checked separately)"
    }
    puts $fh {CLOCK_SPLIT: ctrl=PL0 100MHz direct; mem=PL0 -> u_mem_clk_gen 400MHz; core=PL1 -> u_core_clk_gen 75MHz.}
    puts $fh {RESET: both Wizards reset directly from CIPS; both locked signals ANDed into all three proc_sys_reset blocks; no lock/reset dependency cycle.}
}
