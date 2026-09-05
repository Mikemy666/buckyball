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

# Keep the PIVOT-compatible PTPX sequence chip-owned.  PrimeTime R-2020.09
# requires power analysis to be enabled before read_vcd and accepts unitless
# values (the SDC establishes ns) for the activity interval.
source [file normalize $RUN_CONFIG]
set report_dir [file normalize $RUN_REPORT_DIR]
file mkdir $report_dir
set target_library [list $RUN_TARGET_LIBRARY]
set link_library [concat [list *] $target_library $RUN_SYNTHETIC_LIBRARY $RUN_LINK_LIBRARY]
read_verilog [file normalize $RUN_NETLIST]
current_design $RUN_TOP
link
read_sdc [file normalize $RUN_SDC]
set power_enable_analysis true
set opts [list]
if {$RUN_START_NS ne "" || $RUN_END_NS ne ""} {
  lappend opts -time [list $RUN_START_NS $RUN_END_NS]
}
set format [string tolower $RUN_ACTIVITY_FORMAT]
if {$format eq "fsdb"} {
  if {$RUN_STRIP_PATH ne ""} { read_fsdb {*}$opts -strip_path $RUN_STRIP_PATH [file normalize $RUN_ACTIVITY] } else { read_fsdb {*}$opts [file normalize $RUN_ACTIVITY] }
} elseif {$format eq "vcd"} {
  if {$RUN_STRIP_PATH ne ""} { read_vcd {*}$opts -strip_path $RUN_STRIP_PATH [file normalize $RUN_ACTIVITY] } else { read_vcd {*}$opts [file normalize $RUN_ACTIVITY] }
} elseif {$format eq "saif"} {
  read_saif {*}$opts [file normalize $RUN_ACTIVITY]
} else { error "unsupported activity format: $format" }
set power_model_preference nlpm
update_power
report_power -hierarchy -levels 3 > [file join $report_dir power_hierarchy.rpt]
report_power -verbose > [file join $report_dir power_total.rpt]
report_power -hierarchy -levels 2 -sort_by total_power > [file join $report_dir power_hierarchy_sorted.rpt]
exit
