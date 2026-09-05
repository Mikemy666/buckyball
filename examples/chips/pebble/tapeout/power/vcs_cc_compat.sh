#!/usr/bin/env bash
set -euo pipefail

# See vcs_cpp_compat.sh.  VCS compiles its generated DPI glue as C, so that
# path needs the same host/Nix header isolation as user C++ sources.
unset C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH CPATH
exec "${RISCV:?RISCV is not set}/bin/gcc" "$@"
