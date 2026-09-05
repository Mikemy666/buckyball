#!/usr/bin/env bash
set -euo pipefail

# PrimeTime R-2020.09 is paired with the SRAM Library Compiler installed on
# this Ubuntu 20.04 host.  Run a disposable executable with the same glibc-2.31
# compatibility environment used by lc_shell_compat.sh.
PT_ROOT="${PT_COMPAT_ROOT:-/data2/tools/prime/R-2020.09-SP5-5}"
PT_EXEC="$PT_ROOT/linux64/syn/bin/pt_shell_exec"
PT_SHLIB="$PT_ROOT/linux64/pt/shlib"
PT_SHLIB2="$PT_ROOT/linux64/pt/shlib2"
LC_ROOT="${LC_ROOT:-/data2/tools/lc/R-2020.09-SP5}"
COMPAT_GLIBC="${PT_COMPAT_GLIBC:-/usr/stone/software/dc/compat_glibc-2.31}"
COMPAT_LIB="${PT_COMPAT_LIB:-/usr/stone/software/dc/compat_lib}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../../.." && pwd)
NSSWITCH="$SCRIPT_DIR/nsswitch.compat"
HOST_SH=$(readlink -f /bin/sh)

for required in \
  "$PT_EXEC" \
  "$COMPAT_GLIBC/ld-linux-x86-64.so.2" \
  "$COMPAT_GLIBC/libc.so.6" \
  "$NSSWITCH" \
  /usr/bin/bwrap \
  /usr/bin/busybox \
  /usr/bin/patchelf; do
  if [[ ! -e "$required" ]]; then
    echo "missing PrimeTime compatibility dependency: $required" >&2
    exit 2
  fi
done

compat_dir=$(mktemp -d "${TMPDIR:-/tmp}/buckyball-pt-compat.XXXXXX")
cleanup() {
  rm -f "$compat_dir/pt_shell_exec"
  rm -rf "$compat_dir/bin" "$compat_dir"
}
trap cleanup EXIT

cp "$PT_EXEC" "$compat_dir/pt_shell_exec"
chmod u+w "$compat_dir/pt_shell_exec"
/usr/bin/patchelf \
  --set-interpreter "$COMPAT_GLIBC/ld-linux-x86-64.so.2" \
  "$compat_dir/pt_shell_exec"
/usr/bin/patchelf --force-rpath \
  --set-rpath "$PT_SHLIB:$PT_SHLIB2:$COMPAT_GLIBC:$COMPAT_LIB:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
  "$compat_dir/pt_shell_exec"

mkdir "$compat_dir/bin"
for applet in date grep hostname ipcs lsb_release sh timeout uname; do
  ln -s /usr/bin/busybox "$compat_dir/bin/$applet"
done
ln -s "$SCRIPT_DIR/lc_shell_compat.sh" "$compat_dir/bin/lc_shell"

set +e
/usr/bin/bwrap \
  --die-with-parent \
  --ro-bind / / \
  --dev-bind /dev /dev \
  --proc /proc \
  --bind /tmp /tmp \
  --bind "$ROOT" "$ROOT" \
  --ro-bind "$NSSWITCH" /etc/nsswitch.conf \
  --ro-bind /usr/bin/busybox "$HOST_SH" \
  --chdir "$PWD" \
  /usr/bin/env \
    "PATH=$compat_dir/bin:$PATH" \
    "LD_LIBRARY_PATH=$PT_SHLIB:$PT_SHLIB2:$COMPAT_GLIBC:$COMPAT_LIB" \
    "SYNOPSYS_LC_ROOT=$LC_ROOT" \
    "SNPSLMD_LICENSE_FILE=${SNPSLMD_LICENSE_FILE:-26000@amax}" \
    "LM_LICENSE_FILE=${LM_LICENSE_FILE:-26000@amax}" \
    "$compat_dir/pt_shell_exec" -root_path "$PT_ROOT" "$@" \
    >"$compat_dir/pt_shell.log" 2>&1
status=$?
set -e
/usr/bin/busybox cat "$compat_dir/pt_shell.log"
if (( status == 0 )) && /usr/bin/grep -q '^Error:' "$compat_dir/pt_shell.log"; then
  echo "PrimeTime logged one or more errors despite returning exit status 0" >&2
  status=1
fi
exit "$status"
