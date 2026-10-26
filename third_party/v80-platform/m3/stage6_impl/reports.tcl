report_route_status -file $report_dir/route_status.rpt
report_timing_summary -delay_type min_max -report_unconstrained -max_paths 30 -file $report_dir/routed_timing_summary.rpt
report_timing -delay_type max -max_paths 50 -nworst 3 -input_pins -file $report_dir/setup_paths.rpt
report_timing -delay_type min -max_paths 30 -nworst 3 -input_pins -file $report_dir/hold_paths.rpt
check_timing -verbose -file $report_dir/check_timing.rpt
report_utilization -hierarchical -file $report_dir/routed_utilization.rpt
report_drc -file $report_dir/drc.rpt
report_methodology -file $report_dir/methodology.rpt
report_cdc -details -file $report_dir/cdc.rpt
report_clocks -file $report_dir/clocks.rpt
report_clock_interaction -file $report_dir/clock_interaction.rpt
report_exceptions -coverage -file $report_dir/exceptions_coverage.rpt
report_exceptions -ignored -file $report_dir/exceptions_ignored.rpt
set f [open $report_dir/domain_clocks.tsv w]
foreach {domain filter expected} {
    ctrl {NAME =~ */u_lpu_ctrl_sc/aclk} 10.000
    core {NAME =~ */u_core_clk_gen/clk_out1} 13.333
    mem_axi {NAME =~ */u_mem_clk_gen/clk_out1} 2.500
} {
    set pins [get_pins -hier -filter $filter]
    set clocks [get_clocks -of_objects $pins]
    puts $f "$domain\tEXPECTED=$expected\tPINS=$pins\tCLOCKS=$clocks"
    foreach c $clocks {
        puts $f "$domain\t$c\tPERIOD=[get_property PERIOD $c]"
        report_timing -from $c -to $c -delay_type max -max_paths 20 -input_pins -file $report_dir/${domain}_setup.rpt
        report_timing -from $c -to $c -delay_type min -max_paths 20 -input_pins -file $report_dir/${domain}_hold.rpt
    }
}
close $f
set f [open $report_dir/run_status.txt w]
foreach r [get_runs] {puts $f "$r: [get_property STATUS $r]"}
close $f
