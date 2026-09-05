#!/usr/bin/env bash
set -Eeuo pipefail

power_sim_error() {
  local status=$?
  echo "[power sim] failed at line $1 while running: $2 (exit $status)" >&2
  exit "$status"
}
trap 'power_sim_error "$LINENO" "$BASH_COMMAND"' ERR

if [[ $# != 1 ]]; then echo "usage: $0 <run.env>" >&2; exit 2; fi
source "$1"
: "${ACTIVITY_FILE:?run.env missing ACTIVITY_FILE}"
: "${ACTIVITY_FORMAT:?run.env missing ACTIVITY_FORMAT}"
: "${NETLIST:?run.env missing NETLIST}"
: "${OUTPUT_DIR:?run.env missing OUTPUT_DIR}"
: "${WORKLOAD:?run.env missing WORKLOAD; pass --workload or set tapeout.power_workload}"

if [[ "$ACTIVITY_FORMAT" != "vcd" ]]; then
  echo "Pebble gate power simulation currently emits VCD, got $ACTIVITY_FORMAT" >&2
  exit 2
fi
ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
if [[ -z "${MEM_CONF:-}" ]]; then
  shopt -s nullglob
  mem_candidates=("$ROOT/arch/build/${CONFIG}"/sims.tapeout.*/mems.conf)
  shopt -u nullglob
  if (( ${#mem_candidates[@]} == 0 )); then
    echo "missing FIRRTL memory manifest under $ROOT/arch/build/${CONFIG}/sims.tapeout.*" >&2
    exit 2
  fi
  MEM_CONF=${mem_candidates[0]}
  for candidate in "${mem_candidates[@]:1}"; do
    if [[ "$candidate" -nt "$MEM_CONF" ]]; then MEM_CONF=$candidate; fi
  done
fi
RTL_DIR="${RTL_DIR:-$(dirname "$MEM_CONF")}"
if [[ -z "${BBSIM_DRAM_MODEL:-}" ]]; then
  shopt -s nullglob
  dram_candidates=("$ROOT/arch/build/${CONFIG}"/sims.verilator.*/BBSimDRAM.v)
  shopt -u nullglob
  if (( ${#dram_candidates[@]} == 0 )); then
    echo "missing BBSimDRAM.v under $ROOT/arch/build/${CONFIG}/sims.verilator.*" >&2
    exit 2
  fi
  BBSIM_DRAM_MODEL=${dram_candidates[0]}
  for candidate in "${dram_candidates[@]:1}"; do
    if [[ "$candidate" -nt "$BBSIM_DRAM_MODEL" ]]; then BBSIM_DRAM_MODEL=$candidate; fi
  done
fi
BUILD="$OUTPUT_DIR/gate-vcs"
mkdir -p "$BUILD"
if [[ ! -f "$MEM_CONF" ]]; then echo "missing FIRRTL memory manifest: $MEM_CONF" >&2; exit 2; fi

# Older bbdev releases do not export TARGET_LIBRARY to the simulation
# environment. Resolve it from the chip-owned contract so this script works
# both through `bbdev dc --power` and when invoked directly for debugging.
if [[ -z "${TARGET_LIBRARY:-}" ]]; then
  TARGET_LIBRARY=$(python3 - "$ROOT/examples/chips/pebble/tapeout/config.toml" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = handle.read()
section = re.search(r"(?ms)^\[tapeout\]\s*(.*?)(?=^\[|\Z)", config)
match = section and re.search(r'(?m)^target_library\s*=\s*["\x27]([^"\x27]+)', section.group(1))
if not match:
    raise SystemExit("target_library is missing from tapeout config")
print(match.group(1))
PY
  )
fi
if [[ ! -f "$TARGET_LIBRARY" ]]; then
  echo "missing target Liberty database: $TARGET_LIBRARY" >&2
  exit 2
fi
python3 "$ROOT/bbdev/api/steps/dc/scripts/emit_seq_mem_models.py" --mem-conf "$MEM_CONF" --output "$BUILD/seq_mem_models.sv"

# DC prunes ports from modules inside the synthesized hierarchy.  FastRAM has
# some module names in common with that hierarchy, so put all simulation-side
# RTL in a separate namespace before VCS library resolution.
HARNESS_LIB="$BUILD/harness-lib"
mkdir -p "$HARNESS_LIB"
python3 - "$RTL_DIR" "$HARNESS_LIB" <<'PY'
from pathlib import Path
import re
import sys

source_dir = Path(sys.argv[1])
output_dir = Path(sys.argv[2])
sources = sorted((*source_dir.glob("*.sv"), *source_dir.glob("*.v")))
module_re = re.compile(r"(?m)^\s*module\s+(?:automatic\s+)?([A-Za-z_]\w*)")
modules = {
    name
    for source in sources
    for name in module_re.findall(source.read_text(errors="ignore"))
}
token_re = re.compile(r"\b(" + "|".join(sorted(map(re.escape, modules), key=len, reverse=True)) + r")\b")
for source in sources:
    text = source.read_text(errors="ignore")
    names = module_re.findall(text)
    if not names:
        continue
    prefixed = token_re.sub(lambda match: "Harness_" + match.group(1), text)
    (output_dir / f"Harness_{names[0]}{source.suffix}").write_text(prefixed)
PY
# The generated SimDRAM interface and Buckyball's maintained BBSimDRAM
# interface are identical.  Use the maintained DRAMSim3 backend in place of
# the obsolete generated DRAMSim2 backend.
sed 's/module BBSimDRAM/module Harness_SimDRAM/' "$BBSIM_DRAM_MODEL" > "$HARNESS_LIB/Harness_SimDRAM.v"

GENERATE_MANIFEST="$RTL_DIR/ip-generate/generate_manifest.json"
if [[ ! -f "$GENERATE_MANIFEST" ]]; then
  echo "missing SRAM generation manifest: $GENERATE_MANIFEST" >&2
  exit 2
fi
mapfile -t SRAM_MODELS < <(python3 - "$GENERATE_MANIFEST" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
for leaf in sorted(manifest.get("leaf_paths", {}).values(), key=lambda row: row["v"]):
    print(leaf["v"])
PY
)
if (( ${#SRAM_MODELS[@]} == 0 )); then
  echo "no SRAM Verilog models in $GENERATE_MANIFEST" >&2
  exit 2
fi
for model in "${SRAM_MODELS[@]}"; do
  if [[ ! -f "$model" ]]; then echo "missing SRAM Verilog model: $model" >&2; exit 2; fi
done

cat > "$BUILD/GatePowerHarness.sv" <<'SV'
`timescale 1ns/1ps
module GatePowerHarness;
  reg clock = 1'b0;
  reg reset = 1'b1;
  wire dut_serial_in_ready;
  wire dut_serial_out_valid;
  wire [3:0] dut_serial_out_bits;
  wire ram_serial_in_ready;
  wire ram_serial_out_valid;
  wire [3:0] ram_serial_out_bits;
  wire ram_tsi_in_ready;
  wire ram_tsi_out_valid;
  wire [31:0] ram_tsi_out_bits;
  wire tsi_in_valid;
  wire [31:0] tsi_in_bits;
  wire tsi_out_ready;
  wire [31:0] sim_exit;
  wire debug_dmactive;

  DigitalTop dut(
    .auto_chipyard_prcictrl_domain_reset_setter_clock_in_member_allClocks_uncore_clock(clock),
    .auto_chipyard_prcictrl_domain_reset_setter_clock_in_member_allClocks_uncore_reset(reset),
    .auto_cbus_fixedClockNode_anon_out_clock(),
    .auto_cbus_fixedClockNode_anon_out_reset(),
    .resetctrl_hartIsInReset_0(reset),
    .debug_clock(clock), .debug_reset(reset),
    .debug_systemjtag_jtag_TCK(1'b0), .debug_systemjtag_jtag_TMS(1'b0),
    .debug_systemjtag_jtag_TDI(1'b0), .debug_systemjtag_jtag_TDO_data(),
    .debug_systemjtag_reset(reset), .debug_dmactive(debug_dmactive),
    .debug_dmactiveAck(debug_dmactive), .custom_boot(1'b0),
    .serial_tl_0_in_ready(dut_serial_in_ready),
    .serial_tl_0_in_valid(ram_serial_out_valid),
    .serial_tl_0_in_bits_phit(ram_serial_out_bits),
    .serial_tl_0_out_ready(ram_serial_in_ready),
    .serial_tl_0_out_valid(dut_serial_out_valid),
    .serial_tl_0_out_bits_phit(dut_serial_out_bits),
    .serial_tl_0_clock_in(clock),
    .i2c_0_scl_in(1'b1), .i2c_0_scl_oe(),
    .i2c_0_sda_in(1'b1), .i2c_0_sda_oe(),
    .uart_0_txd(), .uart_0_rxd(1'b1),
    .gpio_0_pins_0_i_ival(1'b0), .gpio_0_pins_1_i_ival(1'b0),
    .gpio_0_pins_2_i_ival(1'b0), .gpio_0_pins_3_i_ival(1'b0),
    .gpio_0_pins_4_i_ival(1'b0), .gpio_0_pins_5_i_ival(1'b0),
    .gpio_0_pins_6_i_ival(1'b0), .gpio_0_pins_7_i_ival(1'b0),
    .spi_0_dq_0_i(1'b0), .spi_0_dq_1_i(1'b0),
    .spi_0_dq_2_i(1'b0), .spi_0_dq_3_i(1'b0));

  Harness_FastRAM ram(
    .clock(clock), .reset(reset),
    .io_ser_in_ready(ram_serial_in_ready),
    .io_ser_in_valid(dut_serial_out_valid),
    .io_ser_in_bits_phit(dut_serial_out_bits),
    .io_ser_out_ready(dut_serial_in_ready),
    .io_ser_out_valid(ram_serial_out_valid),
    .io_ser_out_bits_phit(ram_serial_out_bits),
    .io_tsi_in_ready(ram_tsi_in_ready), .io_tsi_in_valid(tsi_in_valid),
    .io_tsi_in_bits(tsi_in_bits), .io_tsi_out_ready(tsi_out_ready),
    .io_tsi_out_valid(ram_tsi_out_valid), .io_tsi_out_bits(ram_tsi_out_bits));

  Harness_SimTSI #(.CHIPID(0)) sim_tsi(
    .clock(clock), .reset(reset),
    .tsi_in_ready(ram_tsi_in_ready), .tsi_in_valid(tsi_in_valid),
    .tsi_in_bits(tsi_in_bits), .tsi_out_ready(tsi_out_ready),
    .tsi_out_valid(ram_tsi_out_valid), .tsi_out_bits(ram_tsi_out_bits),
    .exit(sim_exit));

  always #5 clock = ~clock;
  initial begin
    repeat (10) @(posedge clock);
    reset = 0;
  end
  initial begin
    longint start_ns;
    longint end_ns;
    if (!$value$plusargs("start-ns=%d", start_ns)) start_ns = 0;
    if (!$value$plusargs("timeout-ns=%d", end_ns)) end_ns = 100000000;
    if (end_ns <= start_ns) begin
      $fatal(1, "invalid power activity window %0d..%0d ns", start_ns, end_ns);
    end
    // Delay VCD registration until the requested power window.  Registering
    // the million-gate DUT at time zero produced gigabytes of irrelevant boot
    // activity before PrimeTime's configured analysis interval.
    #(start_ns);
    $dumpfile("activity.vcd");
    $dumpvars(0, dut);
    #(end_ns - start_ns);
    $dumpoff;
    $finish;
  end
endmodule
SV

CELL_MODEL="$(dirname "$(dirname "$(dirname "$TARGET_LIBRARY")")")/verilog/scc018ug_uhd_rvt.v"
if [[ ! -f "$CELL_MODEL" ]]; then echo "missing standard-cell Verilog model: $CELL_MODEL" >&2; exit 2; fi

VCS_CMD=(vcs -full64 -sverilog +define+functional -cc "$ROOT/examples/chips/pebble/tapeout/power/vcs_cc_compat.sh" -cpp "$ROOT/examples/chips/pebble/tapeout/power/vcs_cpp_compat.sh" -ld "$ROOT/examples/chips/pebble/tapeout/power/vcs_cpp_compat.sh" -timescale=1ns/1ps -top GatePowerHarness -debug_access+all -hsopt=off -Mdir="$BUILD/csrc" -o "$BUILD/simv" -l "$BUILD/compile.log" -y "$HARNESS_LIB" +libext+.sv+.v -CFLAGS "-std=c++17 -I$ROOT/result/include -I$RTL_DIR -I$ROOT/arch/src/csrc/include" -LDFLAGS "-ldramsim3 -Wl,--whole-archive -lfesvr -Wl,--no-whole-archive -lz -lstdc++ -L$ROOT/result/lib -Wl,-rpath,$ROOT/result/lib")
mapfile -t DPI_MODELS < <(find "$RTL_DIR" -maxdepth 1 -name '*DPI.v' -print | sort)
VCS_CMD+=("$NETLIST" "$CELL_MODEL" "$BUILD/seq_mem_models.sv" "${SRAM_MODELS[@]}" "${DPI_MODELS[@]}" "$BUILD/GatePowerHarness.sv" "$RTL_DIR/SimTSI.cc" "$RTL_DIR/testchip_tsi.cc" "$RTL_DIR/testchip_htif.cc" "$ROOT/arch/src/csrc/src/monitor/ioe/BBSimDRAM.cc" "$ROOT/arch/src/csrc/src/monitor/ioe/mm.cc" "$ROOT/arch/src/csrc/src/monitor/ioe/mm_dramsim3.cc" "$ROOT/bbdev/api/steps/dc/scripts/gate_dpi.cc")
echo "[power sim] compiling gate-level simulator; log=$BUILD/compile.log"
"${VCS_CMD[@]}"
if [[ ! -x "$BUILD/simv" ]]; then
  echo "[power sim] VCS returned successfully but did not create $BUILD/simv" >&2
  exit 2
fi

echo "[power sim] running workload; log=$BUILD/sim.log"
# +elf loads the external DRAM backing store.  SimTSI/FESVR separately expects
# the ELF as its positional argument after +permissive-off.
(cd "$BUILD" && env -u LD_LIBRARY_PATH ./simv \
  +permissive +notimingcheck +batch +vcd \
  "+elf=$WORKLOAD" \
  "+dramsim_ini_dir=$ROOT/result/share/dramsim3/configs" \
  "+start-ns=${START_NS:-0}" \
  "+timeout-ns=${END_NS:-100000000}" \
  +permissive-off "$WORKLOAD" 2>&1 | tee sim.log)
if [[ ! -s "$BUILD/activity.vcd" ]]; then
  echo "[power sim] simulation completed without a non-empty $BUILD/activity.vcd" >&2
  exit 2
fi
cp "$BUILD/activity.vcd" "$ACTIVITY_FILE"
echo "[power sim] activity generated: $ACTIVITY_FILE"
