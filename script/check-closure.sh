#!/usr/bin/env bash
# check-closure.sh <host> <tree>
#
# Fails if any shipped executable or library loads something that is
# neither shipped in the tree nor part of the operating system, so a build
# never works only because the build machine happened to have a library.
#
#   darwin-arm64   otool -L: only @executable_path/../lib/<shipped>,
#                  /usr/lib and /System; no LC_RPATH; valid signatures and
#                  the hypervisor entitlement on qemu-system-aarch64
#   linux-amd64    readelf: every NEEDED is in lib/, RUNPATH is
#                  $ORIGIN/../lib, and the loader is shipped
#   windows-amd64  objdump: every imported DLL is in bin/ or a Windows
#                  system DLL (windows-system-dlls.txt)
set -euo pipefail
. "$(dirname "$0")/lib.sh"

host=${1:?usage: check-closure.sh <host> <tree>}
tree=${2:?}
bad=0
fail() { echo "closure: $*" >&2; bad=1; }

case "$host" in
  darwin-arm64)
    for f in "$tree"/bin/* "$tree"/lib/*; do
      [ -f "$f" ] || continue
      file -b "$f" | grep -q Mach-O || continue
      rel=${f#"$tree"/}
      while read -r dep; do
        case "$dep" in
          /usr/lib/*|/System/*) ;;
          @executable_path/../lib/*) [ -f "$tree/lib/${dep#@executable_path/../lib/}" ] || fail "$rel loads $dep, which is not shipped" ;;
          *) fail "$rel loads $dep" ;;
        esac
      done < <(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -vx "@executable_path/../lib/$(basename "$f")")
      otool -l "$f" | grep -q LC_RPATH && fail "$rel has an LC_RPATH"
      codesign --verify --strict "$f" 2>/dev/null || fail "$rel has no valid signature"
    done
    codesign -d --entitlements :- "$tree/bin/qemu-system-aarch64" 2>/dev/null |
      grep -q '<key>com.apple.security.hypervisor</key><true' || fail "qemu-system-aarch64 lacks the hypervisor entitlement"
    ;;
  linux-amd64)
    loader=$(find "$tree/lib" -maxdepth 1 -name 'ld-linux-*.so.*' -print -quit)
    [ -n "$loader" ] || fail "no ELF loader in lib/"
    for f in "$tree"/bin/*.real "$tree"/lib/*.so*; do
      [ -f "$f" ] || continue
      rel=${f#"$tree"/}
      while read -r need; do
        [ -f "$tree/lib/$need" ] || fail "$rel needs $need, which is not shipped"
      done < <(readelf -d "$f" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]$/\1/p')
      case "$rel" in
        bin/*) readelf -d "$f" | grep -Eq '\((RUNPATH|RPATH)\).*\[\$ORIGIN/\.\./lib\]$' || fail "$rel does not have RUNPATH \$ORIGIN/../lib" ;;
      esac
    done
    for w in qemu-system-x86_64 qemu-img; do
      head -1 "$tree/bin/$w" | grep -qx '#!/bin/sh' || fail "bin/$w is not the sh wrapper"
    done
    ;;
  windows-amd64)
    objdump=$(command -v x86_64-w64-mingw32-objdump || command -v objdump) || die "objdump is required"
    for f in "$tree"/bin/*.exe "$tree"/bin/*.dll; do
      [ -f "$f" ] || continue
      rel=${f#"$tree"/}
      while read -r dll; do
        [ -n "$(find "$tree/bin" -maxdepth 1 -iname "$dll" -print -quit)" ] && continue
        [[ "${dll,,}" == api-ms-win-* ]] && continue
        grep -v '^#' "$PVMQ_ROOT/script/windows-system-dlls.txt" | grep -qixF "$dll" || fail "$rel imports $dll, which is neither shipped nor a Windows system DLL"
      done < <("$objdump" -p "$f" | awk '/DLL Name:/ {print $3}')
    done
    ;;
  *) die "unknown host $host" ;;
esac
[ "$bad" = 0 ] || die "the library closure of $tree is not self-contained"
echo "closure of $host tree is self-contained"
