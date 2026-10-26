# Apply the control-register transaction attribute in the build COPY.
# Keep the original stage3 project and existing deployed images unchanged.
proc m3_verify_bar2_attributes {} {
    set cell [get_bd_cells cips]
    set actual [get_property CONFIG.CPM_CONFIG_INTERNAL $cell]
    foreach {key expected} {
        CPM_PCIE1_PF1_BAR2_QDMA_AXCACHE 0
        CPM_PCIE1_PF1_BAR2_QDMA_ENABLED 1
        CPM_PCIE1_PF1_BAR2_QDMA_TYPE AXI_Bridge_Master
        CPM_PCIE1_PF1_BAR2_QDMA_STEERING CPM_PCIE_NOC_1
        CPM_PCIE1_PF1_PCIEBAR2AXIBAR_QDMA_2 0x0000020200000000
    } {
        if {![dict exists $actual $key] || [dict get $actual $key] ne $expected} {
            error "M3 BAR2 attribute mismatch: $key expected $expected"
        }
    }
    puts M3_BAR2_ATTRIBUTES_PASS
}
set m3_cips [get_bd_cells cips]
set m3_bar2_key CPM_PCIE1_PF1_BAR2_QDMA_AXCACHE
set m3_bar2_before [get_property CONFIG.CPM_CONFIG_INTERNAL $m3_cips]
set m3_bar2_config [get_property CONFIG.CPM_CONFIG $m3_cips]
dict set m3_bar2_config $m3_bar2_key 0
set_property CONFIG.CPM_CONFIG $m3_bar2_config $m3_cips
set m3_bar2_after [get_property CONFIG.CPM_CONFIG_INTERNAL $m3_cips]
set m3_bar2_changes {}
dict for {key value} $m3_bar2_before {
    if {![dict exists $m3_bar2_after $key] || [dict get $m3_bar2_after $key] ne $value} {
        lappend m3_bar2_changes $key
        if {$key ne $m3_bar2_key} {error "Unexpected CPM attribute change: $key"}
    }
}
dict for {key value} $m3_bar2_after {
    if {![dict exists $m3_bar2_before $key]} {error "Unexpected new CPM attribute: $key"}
}
m3_verify_bar2_attributes
set m3_bar2_log [open $report_dir/bar2_attributes.txt w]
puts $m3_bar2_log "BEFORE=[dict get $m3_bar2_before $m3_bar2_key]"
puts $m3_bar2_log "AFTER=[dict get $m3_bar2_after $m3_bar2_key]"
puts $m3_bar2_log "CHANGED_KEYS=$m3_bar2_changes"
puts $m3_bar2_log {PASS: PF1 BAR2 is non-modifiable; no other CPM attributes changed.}
close $m3_bar2_log
