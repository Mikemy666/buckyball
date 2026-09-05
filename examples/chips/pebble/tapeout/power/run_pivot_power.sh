#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: run_pivot_power.sh [--skip-build] [--sram-cdk DIR] [--workload NAME]
                          [--start-ns NS --end-ns NS]
                          [--resume-analysis-dir DIR]

Run the Pebble PIVOT DC -> gate-level VCS -> PrimeTime PX power flow.
This script must run in an environment that provides dc_shell, vcs, and
pt_shell. By default it installs the chip config and builds the C tests first.
Use --resume-analysis-dir to reuse a completed DC run and execute only its
gate-level VCS activity generation and PrimeTime PX analysis.
EOF
}

skip_build=0
sram_cdk=""
workload=""
start_ns=""
end_ns=""
resume_analysis_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=1; shift ;;
    --sram-cdk) sram_cdk="${2:?--sram-cdk requires a directory}"; shift 2 ;;
    --workload) workload="${2:?--workload requires a built ELF name}"; shift 2 ;;
    --start-ns) start_ns="${2:?--start-ns requires a value}"; shift 2 ;;
    --end-ns) end_ns="${2:?--end-ns requires a value}"; shift 2 ;;
    --resume-analysis-dir) resume_analysis_dir="${2:?--resume-analysis-dir requires a directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -n "$start_ns" || -n "$end_ns" ]]; then
  if [[ -z "$start_ns" || -z "$end_ns" ]]; then
    echo "--start-ns and --end-ns must be supplied together" >&2
    exit 2
  fi
fi

ROOT=$(cd "$(dirname "$0")/../../../../.." && pwd)
BBDEV="$ROOT/bbdev/bbdev"
SOC_FRAMEWORK="$ROOT/thirdparty/soc-framework"
CDK_PATCH="$ROOT/examples/chips/pebble/tapeout/power/patches/soc-framework-s018sp-cdk-env.patch"
BBDEV_POWER_PATCH="$ROOT/examples/chips/pebble/tapeout/power/patches/bbdev-dc-power-terminal-result.patch"

# Host EDA installation used by the PIVOT branch. Keep caller-provided values,
# but make the checked host installation usable from inside `nix develop`.
DC_HOME="${DC_HOME:-/data0/tools/Synopsys/dc/syn/W-2024.09-SP1}"
VCS_HOME="${VCS_HOME:-/data0/tools/Synopsys/vcs/vcs/W-2024.09-SP1}"
PT_HOME="${PT_HOME:-/data0/tools/Synopsys/ptpx/prime/W-2024.09-SP1}"
export DC_HOME VCS_HOME PT_HOME
export SNPSLMD_LICENSE_FILE="${PIVOT_SNPS_LICENSE:-26000@amax}"
# The local license file still names the inactive 27000 service. Point generic
# FlexNet clients at the same live server for the complete DC/VCS/PTPX flow.
export LM_LICENSE_FILE="$SNPSLMD_LICENSE_FILE"
export PATH="$ROOT/examples/chips/pebble/tapeout/power/pt-shell-bin:$DC_HOME/bin:$VCS_HOME/bin:$PT_HOME/bin:$PATH"

# Motia workers use a local WebSocket. Do not send it through a configured
# corporate/Codex HTTP proxy.
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost"
export no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost"

if [[ -n "$sram_cdk" ]]; then
  export S018SP_CDK="$sram_cdk"
elif [[ -z "${S018SP_CDK:-}" && -n "${SMIC180_ROOT:-}" ]]; then
  export S018SP_CDK="$SMIC180_ROOT/SRAM/S018SP_v0p1pc_CDK"
fi
if [[ -z "${S018SP_CDK:-}" ]]; then
  default_cdk=/data2/smic180/SRAM/S018SP_v0p1pc_CDK
  if [[ -f "$default_cdk/S018SP.jar" ]]; then
    export S018SP_CDK="$default_cdk"
  else
    echo "missing SMIC180 SRAM compiler; pass --sram-cdk DIR or export S018SP_CDK" >&2
    echo "DIR must contain S018SP.jar and the accompanying S018SP CDK files" >&2
    exit 2
  fi
fi
if [[ ! -d "$S018SP_CDK" || ! -f "$S018SP_CDK/S018SP.jar" ]]; then
  echo "invalid S018SP_CDK (S018SP.jar not found): $S018SP_CDK" >&2
  exit 2
fi

# soc-framework is an independently versioned submodule. Its pinned revision
# hard-codes the original bb-runner CDK path, so apply the parent-owned,
# temporary compatibility patch for this run and restore the checkout on exit.
cdk_patch_applied=0
bbdev_patch_applied=0
restore_soc_framework() {
  if (( bbdev_patch_applied )); then
    git -C "$ROOT/bbdev" apply --reverse "$BBDEV_POWER_PATCH" || \
      echo "warning: could not restore the bbdev DC power workflow patch" >&2
  fi
  if (( cdk_patch_applied )); then
    git -C "$SOC_FRAMEWORK" apply --reverse "$CDK_PATCH" || \
      echo "warning: could not restore the soc-framework compatibility patch" >&2
  fi
}
trap restore_soc_framework EXIT
if ! grep -q 'os\.environ\["S018SP_CDK"\]' "$SOC_FRAMEWORK/ip/smic180/compiler.py"; then
  if ! git -C "$SOC_FRAMEWORK" apply --check "$CDK_PATCH"; then
    echo "cannot apply S018SP_CDK compatibility patch to soc-framework" >&2
    exit 2
  fi
  git -C "$SOC_FRAMEWORK" apply "$CDK_PATCH"
  cdk_patch_applied=1
fi

# The pinned bbdev reports success after the intermediate DC and simulation
# stages. Script mode then tears down its workers and kills the just-enqueued
# VCS/PT process. Only PrimeTime may publish the terminal success result.
if ! grep -q 'await ctx.enqueue.*topic.*dc.sim.*return' "$ROOT/bbdev/api/steps/dc/01_area_event.step.py"; then
  if ! git -C "$ROOT/bbdev" apply --check "$BBDEV_POWER_PATCH"; then
    echo "cannot apply bbdev DC power terminal-result patch" >&2
    exit 2
  fi
  git -C "$ROOT/bbdev" apply "$BBDEV_POWER_PATCH"
  bbdev_patch_applied=1
fi

missing=0
for tool in dc_shell vcs pt_shell; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required Synopsys executable on PATH: $tool" >&2
    missing=1
  fi
done
if (( missing )); then
  echo "source the host EDA environment, then enter the project Nix shell and retry" >&2
  exit 2
fi

branch=$(git -C "$ROOT" branch --show-current)
if [[ "$branch" != "pivot" ]]; then
  echo "refusing to measure a non-PIVOT checkout (current branch: ${branch:-detached})" >&2
  exit 2
fi

if [[ -n "$resume_analysis_dir" ]]; then
  resume_analysis_dir=$(realpath "$resume_analysis_dir")
  run_env="$resume_analysis_dir/activity/run.env"
  area_run_config="$resume_analysis_dir/run.tcl"
  if [[ ! -f "$run_env" || ! -f "$area_run_config" ]]; then
    echo "invalid resume analysis directory (run.env or run.tcl missing): $resume_analysis_dir" >&2
    exit 2
  fi
  echo "[power resume] reusing completed DC analysis: $resume_analysis_dir"
  bash "$ROOT/examples/chips/pebble/tapeout/power/power_sim.sh" "$run_env"
  # shellcheck disable=SC1090
  source "$run_env"
  PYTHONPATH="$ROOT/bbdev/api/steps/dc/scripts" python3 - \
    "$ROOT" "$resume_analysis_dir" "$START_NS" "$END_NS" "$ACTIVITY_STRIP_PATH" <<'PY'
import sys
from tapeout import get_tapeout_contract, write_run_tcl

root, analysis_dir, start_ns, end_ns, strip_path = sys.argv[1:]
contract = get_tapeout_contract(root, "pebble", "DigitalTop")
write_run_tcl(
    f"{analysis_dir}/power-run.tcl",
    {
        "top": "DigitalTop",
        "netlist": f"{analysis_dir}/outputs/DigitalTop.v",
        "sdc": f"{analysis_dir}/outputs/DigitalTop.sdc",
        "activity": f"{analysis_dir}/activity/activity.vcd",
        "activity_format": "vcd",
        "report_dir": f"{analysis_dir}/power-reports",
        "strip_path": strip_path,
        "start_ns": start_ns,
        "end_ns": end_ns,
        "target_library": contract.target_library,
        "synthetic_library": contract.synthetic_library,
        "link_library": contract.link_library,
        "max_cores": contract.max_cores,
    },
)
PY
  set -o pipefail
  pt_shell -f "$ROOT/examples/chips/pebble/tapeout/power/power.tcl" \
    -x "set RUN_CONFIG {$resume_analysis_dir/power-run.tcl}" \
    2>&1 | tee "$resume_analysis_dir/pt_shell.log"
  echo "[power resume] reports: $resume_analysis_dir/power-reports"
  exit 0
fi

if (( ! skip_build )); then
  "$BBDEV" config --install
  "$BBDEV" compiler --build '--chip pebble'
  "$BBDEV" workload --build '--chip pebble --ctest'
fi

power_args="--chip pebble"
if [[ -n "$workload" ]]; then
  power_args+=" --workload $workload"
fi
if [[ -n "$start_ns" ]]; then
  power_args+=" --start-ns $start_ns --end-ns $end_ns"
fi

"$BBDEV" dc --power "$power_args"
