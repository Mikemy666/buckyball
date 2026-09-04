#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: run_pivot_power.sh [--skip-build] [--workload NAME]
                          [--start-ns NS --end-ns NS]

Run the Pebble PIVOT DC -> gate-level VCS -> PrimeTime PX power flow.
This script must run in an environment that provides dc_shell, vcs, and
pt_shell. By default it installs the chip config and builds the C tests first.
EOF
}

skip_build=0
workload=""
start_ns=""
end_ns=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=1; shift ;;
    --workload) workload="${2:?--workload requires a built ELF name}"; shift 2 ;;
    --start-ns) start_ns="${2:?--start-ns requires a value}"; shift 2 ;;
    --end-ns) end_ns="${2:?--end-ns requires a value}"; shift 2 ;;
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

# Motia workers use a local WebSocket. Do not send it through a configured
# corporate/Codex HTTP proxy.
export NO_PROXY="${NO_PROXY:+${NO_PROXY},}127.0.0.1,localhost"
export no_proxy="${no_proxy:+${no_proxy},}127.0.0.1,localhost"

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
