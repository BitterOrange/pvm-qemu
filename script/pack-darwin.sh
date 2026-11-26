#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# pack-darwin.sh <prefix> <dest>
#
# Turns a QEMU installed under <prefix> into a relocatable tree at <dest>
# (normally .../aarch64): the two executables, the Homebrew dylibs they load
# (rewritten to @executable_path/../lib), and the aarch64 firmware. Every
# Mach-O is then signed ad hoc, and qemu-system-aarch64 last with only the
# hypervisor entitlement. There is no other signing identity. Each copied
# library's original path is written to <dest>.origins, and the highest
# LC_BUILD_VERSION minos to <dest>.minos.
#
# Derived from pvm's script/qemu/pack-runtime.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

prefix=${1:?usage: pack-darwin.sh <prefix> <dest>}
dest=${2:?}
[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "pack-darwin.sh runs on darwin/arm64 only"
[ -x "$prefix/bin/qemu-system-aarch64" ] || die "$prefix/bin/qemu-system-aarch64 not found"
[ ! -e "$dest" ] || die "$dest already exists"

mkdir -p "$dest/bin" "$dest/lib" "$dest/share/qemu"
cp "$prefix/bin/qemu-system-aarch64" "$prefix/bin/qemu-img" "$dest/bin/"
chmod 0755 "$dest/bin/"*
# Drop debug symbols before the paths are rewritten and everything is signed.
strip -S "$dest/bin/qemu-system-aarch64" "$dest/bin/qemu-img"
"$PVMQ_ROOT/script/copy-firmware.sh" aarch64 "$prefix/share/qemu" "$dest/share/qemu"

# Copy the closure of non-system dylibs. QEMU itself links no dylib of its
# own, so every one of them comes from Homebrew.
origins="$dest.origins"
: > "$origins"
nonsystem() { otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/|@executable_path/)' || true; }
queue=("$dest"/bin/*)
while [ ${#queue[@]} -gt 0 ]; do
  cur=${queue[0]}
  queue=("${queue[@]:1}")
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*) ;;
      *) die "$(basename "$cur") loads $dep, which is neither a system library nor from Homebrew" ;;
    esac
    name=$(basename "$dep")
    [ "$name" = "$(basename "$cur")" ] && continue
    [ -f "$dest/lib/$name" ] && continue
    cp "$dep" "$dest/lib/$name"
    chmod 0644 "$dest/lib/$name"
    printf '%s\t%s\n' "lib/$name" "$(readlink -f "$dep")" >> "$origins"
    queue+=("$dest/lib/$name")
  done < <(nonsystem "$cur")
done

for f in "$dest"/bin/* "$dest"/lib/*.dylib; do
  [ -f "$f" ] || continue
  while IFS= read -r dep; do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$f"
  done < <(nonsystem "$f")
  case "$f" in
    *.dylib) install_name_tool -id "@executable_path/../lib/$(basename "$f")" "$f" ;;
  esac
  # Every reference now names its file under @executable_path, so search
  # paths (some Homebrew dylibs carry one) could only reach outside the tree.
  while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$f"
  done < <(otool -l "$f" | awk '$1 == "cmd" && $2 == "LC_RPATH" {r = 1; next} r && $1 == "path" {print $2; r = 0}')
done

# The rewrites invalidate every signature. Sign the libraries and qemu-img
# first, then the emulator with the entitlement macOS requires for HVF.
for f in "$dest"/lib/*.dylib "$dest/bin/qemu-img"; do
  [ -f "$f" ] || continue
  codesign --force --sign - "$f"
done
codesign --force --sign - --entitlements "$PVMQ_ROOT/script/hv-entitlements.plist" "$dest/bin/qemu-system-aarch64"

minos=0
for f in "$dest"/bin/* "$dest"/lib/*.dylib; do
  [ -f "$f" ] || continue
  v=$(otool -l "$f" | awk '/LC_BUILD_VERSION/ {b = 1} b && $1 == "minos" {print $2; exit}')
  [ -n "$v" ] || continue
  minos=$(printf '%s\n%s\n' "$minos" "$v" | sort -V | tail -1)
done
echo "$minos" > "$dest.minos"

"$dest/bin/qemu-system-aarch64" --version >/dev/null
"$dest/bin/qemu-img" --version >/dev/null
echo "packed $(wc -l < "$origins" | tr -d ' ') libraries into $dest (minos $minos)"
