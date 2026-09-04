#!/usr/bin/env bash
set -euo pipefail

LC_ROOT="${LC_ROOT:-/data2/tools/lc/R-2020.09-SP5}"
LC_EXEC="$LC_ROOT/linux64/lc/bin/lc2_shell_exec"
LC_SHLIB="$LC_ROOT/linux64/lc/shlib"
COMPAT_GLIBC="${LC_COMPAT_GLIBC:-/usr/stone/software/dc/compat_glibc-2.31}"
COMPAT_LIB="${LC_COMPAT_LIB:-/usr/stone/software/dc/compat_lib}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../../../../.." && pwd)
NSSWITCH="$SCRIPT_DIR/nsswitch.compat"
HOST_SH=$(readlink -f /bin/sh)

for required in \
  "$LC_EXEC" \
  "$COMPAT_GLIBC/ld-linux-x86-64.so.2" \
  "$COMPAT_GLIBC/libc.so.6" \
  "$NSSWITCH" \
  /usr/bin/bwrap \
  /usr/bin/busybox \
  /usr/bin/patchelf; do
  if [[ ! -e "$required" ]]; then
    echo "missing LC compatibility dependency: $required" >&2
    exit 2
  fi
done

compat_dir=$(mktemp -d "${TMPDIR:-/tmp}/buckyball-lc-compat.XXXXXX")
cleanup() {
  rm -f "$compat_dir/lc2_shell_exec"
  rm -rf "$compat_dir/bin" "$compat_dir"
}
trap cleanup EXIT

# R-2020.09 encodes /lib64 in DT_RPATH, which selects glibc 2.35 and fails on
# its removed libpthread GLIBC_PRIVATE symbol. Patch only a disposable copy.
cp "$LC_EXEC" "$compat_dir/lc2_shell_exec"
chmod u+w "$compat_dir/lc2_shell_exec"
/usr/bin/patchelf \
  --set-interpreter "$COMPAT_GLIBC/ld-linux-x86-64.so.2" \
  "$compat_dir/lc2_shell_exec"
/usr/bin/patchelf --force-rpath \
  --set-rpath "$LC_SHLIB:$COMPAT_GLIBC:$COMPAT_LIB:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu" \
  "$compat_dir/lc2_shell_exec"

# LC launches a few diagnostic commands. Static BusyBox applets prevent its
# glibc-2.31 LD_LIBRARY_PATH from being inherited by glibc-2.35 host binaries.
mkdir "$compat_dir/bin"
for applet in date grep hostname ipcs lsb_release sh timeout uname; do
  ln -s /usr/bin/busybox "$compat_dir/bin/$applet"
done

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
    "LD_LIBRARY_PATH=$LC_SHLIB:$COMPAT_GLIBC:$COMPAT_LIB" \
    "SNPSLMD_LICENSE_FILE=${SNPSLMD_LICENSE_FILE:-26000@amax}" \
    "LM_LICENSE_FILE=${LM_LICENSE_FILE:-26000@amax}" \
    "$compat_dir/lc2_shell_exec" \
      -shell lc2_shell -r "$LC_ROOT" "$@"
status=$?
set -e
exit "$status"
