#!/usr/bin/env bash
set -euo pipefail

# VCS adds Ubuntu host include directories while running inside `nix develop`.
# Mixing those glibc headers with the Nix compiler headers breaks DPI builds.
unset C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH CPATH

# VCS also injects host library directories before the Nix libraries when it
# uses this wrapper as the linker.  Drop only those two injected arguments.
args=()
for arg in "$@"; do
  case "$arg" in
    -L/usr/lib/x86_64-linux-gnu|-L/lib/x86_64-linux-gnu) ;;
    *) args+=("$arg") ;;
  esac
done
exec "${RISCV:?RISCV is not set}/bin/g++" "${args[@]}"
