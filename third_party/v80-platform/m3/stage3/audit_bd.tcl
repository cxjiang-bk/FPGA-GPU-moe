# Run in the validated M3 BD. Assertions inspect the resulting design.
proc m3_expect_hz {actual expected context} {
    if {abs($actual-$expected)>10} {error "$context: expected $expected +/-10 Hz, got $actual"}
}
proc m3_expect {actual expected context} {
    if {$actual ne $expected} {error "$context: expected '$expected', got '$actual'"}
}
proc m3_same_net {a b} {
    m3_expect [get_bd_nets -of_objects [get_bd_pins $a]] [get_bd_nets -of_objects [get_bd_pins $b]] "clock/reset net $a $b"
}
proc m3_same_bus {a b} {
    m3_expect [get_bd_intf_nets -of_objects [get_bd_intf_pins $a]] [get_bd_intf_nets -of_objects [get_bd_intf_pins $b]] "AXI net $a $b"
}
set fh [open $work/bd_audit.txt w]
puts $fh "M3 phase3 configuration audit; no implementation timing or board claim."
puts $fh "PART [get_property PART [current_project]]"
m3_expect [get_property CONFIG.NUM_SI [get_bd_cells axi_noc_cips]] 12 {NoC input count}
m3_expect [get_property CONFIG.NUM_HBM_BLI [get_bd_cells axi_noc_cips]] 0 {HBM_NMU disabled}
m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_pins u_core_clk_gen/clk_out1]] 75000000 {core clock}
m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_pins u_mem_clk_gen/clk_out1]] 400000000 {memory clock}
foreach {bus bridge si srcwidth dstwidth} {M_AXI u_lpu_mem_bridge S08_AXI 1024 512 RV_I_AXI u_rvi_axi_cdc S09_AXI 512 512 RV_D_AXI u_rvd_axi_cdc S10_AXI 512 512 RV_U_AXI u_rvu_axi_cdc S11_AXI 32 32} {
    set cell [get_bd_cells $bridge]
    m3_expect [get_property CONFIG.NUM_SI $cell] 1 "$bridge inputs"
    m3_expect [get_property CONFIG.NUM_MI $cell] 1 "$bridge outputs"
    m3_expect [get_property CONFIG.NUM_CLKS $cell] 2 "$bridge clocks"
    m3_same_bus u_lpu_addremap/$bus $bridge/S00_AXI
    m3_same_net u_core_clk_gen/clk_out1 $bridge/aclk
    m3_same_net u_mem_clk_gen/clk_out1 $bridge/aclk1
    m3_same_net u_core_reset/interconnect_aresetn $bridge/aresetn
    m3_expect [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins $bridge/S00_AXI]] $srcwidth "$bridge source width"
    m3_expect [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins $bridge/M00_AXI]] $dstwidth "$bridge output width"
    m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_intf_pins $bridge/S00_AXI]] 75000000 "$bridge SI frequency"
    m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_intf_pins $bridge/M00_AXI]] 400000000 "$bridge MI frequency"
    m3_expect [get_property CONFIG.CATEGORY [get_bd_intf_pins axi_noc_cips/$si]] pl "$si ordinary NMU"
    if {$bus eq "M_AXI"} {
        m3_same_bus $bridge/M00_AXI u_lpu_mem_regslice/S_AXI
        m3_same_bus u_lpu_mem_regslice/M_AXI axi_noc_cips/$si
    } else {m3_same_bus $bridge/M00_AXI axi_noc_cips/$si}
    set segs [get_bd_addr_segs -of_objects [get_bd_addr_spaces u_lpu_addremap/$bus]]
    m3_expect [llength $segs] 4 "$bus segment count"
    set intervals {}
    foreach seg $segs {
        set offset [get_property OFFSET $seg]
        set range [get_property RANGE $seg]
        lappend intervals [list [expr {$offset}] [expr {$range}]]
        puts $fh "$bus $seg OFFSET=$offset RANGE=$range"
    }
    set expect 0x4000000000
    foreach interval [lsort -integer -index 0 $intervals] {
        m3_expect [lindex $interval 0] [expr {$expect}] "$bus contiguous mapping"
        m3_expect [lindex $interval 1] 1073741824 "$bus segment size"
        set expect [expr {$expect+1073741824}]
    }
    m3_expect $expect [expr {0x4100000000}] "$bus exactly 4 GiB"
    puts $fh "$bus -> $bridge -> $si : ${srcwidth}bit/75MHz -> ${dstwidth}bit/400MHz PASS"
}
foreach channel {AW W B AR R} {
    m3_expect [get_property CONFIG.REG_$channel [get_bd_cells u_lpu_mem_regslice]] 1 "Register Slice $channel Full"
}
m3_same_net u_mem_clk_gen/clk_out1 axi_noc_cips/aclk9
m3_same_net u_mem_clk_gen/clk_out1 u_lpu_mem_regslice/aclk
m3_same_net u_mem_axi_reset/peripheral_aresetn u_lpu_mem_regslice/aresetn
m3_same_net cips/pl0_ref_clk u_lpu_ctrl_sc/aclk
m3_same_net u_core_clk_gen/clk_out1 u_lpu_ctrl_sc/aclk1
foreach pattern {*axi_traffic_gen* *axi_tg* *perf_axi_tg*} {
    m3_expect [llength [get_bd_cells -quiet -hier -filter "VLNV =~ $pattern"]] 0 {M2 ATG absent}
}
m3_expect [get_property CONFIG.NUM_SI [get_bd_cells u_lpu_ctrl_sc]] 1 {control SI count}
m3_expect [get_property CONFIG.NUM_MI [get_bd_cells u_lpu_ctrl_sc]] 2 {control MI count}
m3_expect [get_property CONFIG.NUM_CLKS [get_bd_cells u_lpu_ctrl_sc]] 2 {control clock count}
m3_same_bus pf1_bar2_ctrl/M01_AXI u_lpu_ctrl_sc/S00_AXI
m3_same_bus u_lpu_ctrl_sc/M00_AXI u_lpu_addremap/S_AXI
m3_same_bus u_lpu_ctrl_sc/M01_AXI u_lpu_completion_status/S_AXI
m3_same_net u_core_clk_gen/clk_out1 u_lpu_completion_status/core_clk
m3_same_net u_core_reset/peripheral_aresetn u_lpu_completion_status/core_resetn
m3_same_net u_core_reset/interconnect_aresetn u_lpu_ctrl_sc/aresetn
foreach event {rvcore_irq lpu_done_irq} {
    m3_same_net u_lpu_addremap/$event u_lpu_completion_status/$event
}
m3_expect [get_property CONFIG.PROTOCOL [get_bd_intf_pins u_lpu_completion_status/S_AXI]] AXI4LITE {completion protocol}
m3_expect [get_property CONFIG.DATA_WIDTH [get_bd_intf_pins u_lpu_completion_status/S_AXI]] 32 {completion data width}
m3_expect_hz [get_property CONFIG.FREQ_HZ [get_bd_intf_pins u_lpu_completion_status/S_AXI]] 75000000 {completion frequency}
m3_expect [llength [get_bd_intf_ports -quiet M3_COMPLETION]] 0 {temporary completion port removed}
foreach port {m3_core_clk m3_core_resetn rvcore_irq lpu_done_irq} {
    m3_expect [llength [get_bd_ports -quiet $port]] 0 "temporary port $port removed"
}
foreach {offset fragment} {0x020200010000 u_lpu_addremap 0x020200020000 axi_gpio_test_pf1 0x020200030000 u_lpu_completion_status} {
    set matched 0
    foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces cips/CPM_PCIE_NOC_1]] {
        if {[get_property OFFSET $seg] == $offset} {
            m3_expect [expr {[get_property RANGE $seg]}] 4096 "$fragment control window size"
            if {![string match *$fragment* $seg]} {error "Unexpected target at $offset: $seg"}
            incr matched
            puts $fh "HOST $seg OFFSET=[get_property OFFSET $seg] RANGE=[get_property RANGE $seg]"
        }
    }
    m3_expect $matched 1 "$fragment mapped once"
}
puts $fh "CTRL SmartConnect 1 SI / 2 MI; 100MHz -> 75MHz; RUN_CTRL and completion are independent destinations."
puts $fh "END and DONE wired from real LPU outputs to status in core_clk; global reset only."
puts $fh "STATUS +0x0 W1C; IRQ_ENABLE +0x4 RW; IRQ_PENDING +0x8 RO. Internal M4 hook, no MSI-X."
puts $fh "Four independent memory paths and 4 GiB mapping retained; mem_axi_clk target 400MHz."
foreach pin {smbus_hier/smartconnect_0/M00_AXI smbus_hier/smbus_0/s_axi} {
    m3_expect [get_property CONFIG.PROTOCOL [get_bd_intf_pins $pin]] AXI4LITE "$pin protocol"
    m3_expect [get_property CONFIG.MAX_BURST_LENGTH [get_bd_intf_pins $pin]] 1 "$pin raw burst metadata"
}
puts $fh "SMBus AXI4-Lite: both endpoint MAX_BURST_LENGTH values are exactly 1."
source [file join [file dirname [file normalize [info script]]] ../clock_split/audit_clocks.tcl]
m3_audit_split_clocks $fh
puts $fh "PASS"
close $fh
puts M3_PHASE3_AUDIT_PASS
