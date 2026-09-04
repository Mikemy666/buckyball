# Pebble tapeout contract

Layout:
- `config.toml` — chip contract (scripts, libs, power window)
- `area/` — DC (`dc.tcl`, `constraints.sdc`)
- `power/` — PTPX + gate sim (`power.tcl`, `power_sim.sh`)
- `ip/` — SRAM MDF

`bbdev dc` resolves paths from `config.toml` and injects `RUN_*`. Timing truth is
`area/constraints.sdc`. Pebble main clock is 100 MHz (`10 ns`).

## PIVOT power validation

Run from the repository root after entering a host environment containing
licensed `dc_shell`, `vcs`, and `pt_shell` executables. The one-time compiler
build is required because the workload CMake configuration consumes the
chip-specific Buddy CMake cache, including for C-only tests:

```bash
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost"
export no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost"
./bbdev/bbdev config --install
./bbdev/bbdev compiler --build '--chip pebble'
./bbdev/bbdev workload --build '--chip pebble --ctest'
./bbdev/bbdev dc --power '--chip pebble'
```

The proprietary SMIC180 SRAM compiler is not distributed with this repository.
Its directory must contain `S018SP.jar` and the accompanying CDK files. The
wrapper automatically uses this host's installation at
`/data2/smic180/SRAM/S018SP_v0p1pc_CDK`, or accepts another installation path:

```bash
./examples/chips/pebble/tapeout/power/run_pivot_power.sh \
  --sram-cdk /path/to/S018SP_v0p1pc_CDK
```

Equivalently, export `S018SP_CDK`; `SMIC180_ROOT` is also supported when the CDK
is installed at `$SMIC180_ROOT/SRAM/S018SP_v0p1pc_CDK`.

The flow uses R-2020.09-SP5 Library Compiler for SRAM Liberty-to-DB conversion
and W-2024.09-SP1 Design Compiler for synthesis. The active Synopsys license
service is `26000@amax`; the wrapper supplies it when
running the flow. Set `PIVOT_SNPS_LICENSE` only when using another server.

The default activity workload is
`pebble-pebble-ctest-mega_conv_pipeline_test-baremetal`. It exercises the PIVOT
adaptive prefetch path and uses the configured 1--5 ms VCD activity window.
Override it or shorten the smoke-test window when needed:

```bash
./bbdev/bbdev dc --power '--chip pebble --workload <built-ELF-name> --start-ns 100000 --end-ns 300000'
```

Reports are written below the newest
`log/<timestamp>/pebble/tapeout/<date>/dc/power/` directory. The primary result
is `power-reports/power_total.rpt`; use `power_hierarchy_sorted.rpt` to locate
the largest dynamic-power contributors. SRAM activity is linked with the SRAM
Liberty databases produced by the preceding DC stage. DRAM power remains a
separate DRAMSim3 result and is not included in the PrimeTime cell-power total.

The same sequence, including prerequisite and proxy checks, is available as:

```bash
./examples/chips/pebble/tapeout/power/run_pivot_power.sh
```
