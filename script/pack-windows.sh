#!/usr/bin/env bash
# pack-windows.sh <prefix> <dest>
#
# Turns a mingw-w64 QEMU installed under <prefix> into the tree at <dest>
# (normally .../x86_64) in the layout pvm uses on Windows: the executables
# and every DLL they load in bin/, and the firmware in bin/share. DLLs come
# from the mingw sysroot or the directories in PVMQ_DLL_DIRS (libraries this
# build compiled itself); anything else they import must be a Windows system
# DLL listed in windows-system-dlls.txt. Each copied DLL's sysroot path is
# written to <dest>.origins for the source collection.
#
# Replaces pvm's script/qemu/pack-windows-runtime.sh, which repacked the
# weilnetz installer.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

prefix=${1:?usage: pack-windows.sh <prefix> <dest>}
dest=${2:?}
sysroot=${MINGW_SYSROOT:-/usr/x86_64-w64-mingw32/sys-root/mingw}
objdump=$(command -v x86_64-w64-mingw32-objdump || command -v objdump) || die "objdump is required"
[ -d "$sysroot/bin" ] || die "mingw sysroot $sysroot not found"
[ ! -e "$dest" ] || die "$dest already exists"

img=$(find "$prefix" -type f -name qemu-img.exe -print -quit)
[ -n "$img" ] || die "qemu-img.exe not found under $prefix"
bindir=$(dirname "$img")
[ -f "$bindir/qemu-system-x86_64.exe" ] || die "qemu-system-x86_64.exe not found next to qemu-img.exe"
datadir=""
for d in "$bindir/share" "$bindir/../share/qemu" "$prefix/share/qemu" "$prefix/share"; do
  if [ -f "$d/bios-256k.bin" ]; then datadir=$d; break; fi
done
[ -n "$datadir" ] || die "QEMU firmware not found under $prefix"

mkdir -p "$dest/bin"
cp "$bindir/qemu-system-x86_64.exe" "$bindir/qemu-img.exe" "$dest/bin/"
"$PVMQ_ROOT/script/copy-firmware.sh" x86_64 "$datadir" "$dest/bin/share"

system_dll() { grep -qixF "$1" <(grep -v '^#' "$PVMQ_ROOT/script/windows-system-dlls.txt") || [[ "${1,,}" == api-ms-win-* ]]; }

origins="$dest.origins"
: > "$origins"
declare -A seen=()
queue=("$dest/bin/qemu-system-x86_64.exe" "$dest/bin/qemu-img.exe")
while [ ${#queue[@]} -gt 0 ]; do
  cur=${queue[0]}
  queue=("${queue[@]:1}")
  while IFS= read -r dll; do
    key=${dll,,}
    [ -z "${seen[$key]:-}" ] || continue
    seen[$key]=1
    found=""
    IFS=: read -r -a extra <<< "${PVMQ_DLL_DIRS:-}"
    for d in "$sysroot/bin" "${extra[@]}"; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      found=$(find "$d" -maxdepth 1 -type f -iname "$dll" -print -quit)
      [ -z "$found" ] || break
    done
    if [ -n "$found" ]; then
      cp "$found" "$dest/bin/$(basename "$found")"
      printf '%s\t%s\n' "bin/$(basename "$found")" "$(readlink -f "$found")" >> "$origins"
      queue+=("$dest/bin/$(basename "$found")")
    elif ! system_dll "$dll"; then
      die "$(basename "$cur") imports $dll, which is neither in the mingw sysroot nor a known Windows system DLL"
    fi
  done < <("$objdump" -p "$cur" | awk '/DLL Name:/ {print $3}')
done
chmod 0755 "$dest/bin/"*.exe "$dest/bin/"*.dll
echo "packed $(wc -l < "$origins") DLLs into $dest"
