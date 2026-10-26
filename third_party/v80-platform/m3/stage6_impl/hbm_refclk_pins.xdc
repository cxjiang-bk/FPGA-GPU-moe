# XCV80 LSVA4737 dedicated HBM reference clock pads.
# PG313 Clocking: C4CCIO_PAD0 is P, C4CCIO_PAD1 is N.
# Device/package mapping and the generated HBM IP both use this ordering.
# Corrects the opposite P/N assignments in the supplied AMR impl.pins.xdc.
set_property PACKAGE_PIN N19 [get_ports {hbm_ref_clk_0_clk_p[0]}]
set_property PACKAGE_PIN N18 [get_ports {hbm_ref_clk_0_clk_n[0]}]
set_property PACKAGE_PIN N37 [get_ports {hbm_ref_clk_1_clk_p[0]}]
set_property PACKAGE_PIN N38 [get_ports {hbm_ref_clk_1_clk_n[0]}]
