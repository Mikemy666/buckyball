# Pebble-owned PTPX entry point. DDR is measured by DRAMSim3; this wrapper
# delegates standard-cell dynamic power to the shared bbdev implementation.
#
# The DC run adds generated SRAM Liberty databases to its run.tcl. Preserve
# that link library for PTPX as well; otherwise the synthesized chipyard_sram_*
# instances remain unresolved when PrimeTime links DigitalTop.
if {![info exists RUN_CONFIG] || $RUN_CONFIG eq ""} {
  error "bbdev must pass -x {set RUN_CONFIG <power-run.tcl>}"
}
set power_run_config [file normalize $RUN_CONFIG]
set area_run_config [file join [file dirname $power_run_config] run.tcl]
if {![file isfile $area_run_config]} {
  error "missing DC run configuration with SRAM link libraries: $area_run_config"
}

source $power_run_config
set power_link_library $RUN_LINK_LIBRARY
source $area_run_config
set dc_link_library $RUN_LINK_LIBRARY
source $power_run_config
set combined_link_library [concat $power_link_library $dc_link_library]

set merged_run_config [file join [file dirname $power_run_config] power-run-with-srams.tcl]
set merged_fh [open $merged_run_config w]
puts $merged_fh [list source $power_run_config]
puts $merged_fh [list set RUN_LINK_LIBRARY $combined_link_library]
close $merged_fh
set RUN_CONFIG $merged_run_config

set bbdev_ptpx_script [file normalize [file join [file dirname [info script]] .. .. .. .. .. bbdev api steps dc scripts ptpx.tcl]]
source $bbdev_ptpx_script
