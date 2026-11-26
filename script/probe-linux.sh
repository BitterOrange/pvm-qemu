#!/usr/bin/env bash
# probe-linux.sh <x86_64-tree> [hidden-dir...]
#
# Proves a Linux build is relocatable: copies the tree to another path and
# starts it in a private mount namespace in which every place a system QEMU
# keeps its data, modules or firmware, and any extra directories given
# (the build prefix), is hidden under an empty tmpfs. Then removes
# bios-256k.bin from the copy and requires the start to fail, which shows
# QEMU really could not find firmware anywhere outside the tree.
#
# Must run as root (mount namespaces), on the host rather than in an
# unprivileged container.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

tree=$(cd "${1:?usage: probe-linux.sh <x86_64-tree> [hidden-dir...]}" && pwd)
shift
[ "$(id -u)" = 0 ] || die "probe-linux.sh must run as root"
command -v unshare >/dev/null 2>&1 || die "unshare is required"
hide=(/usr/share/qemu /usr/share/seabios /usr/share/ipxe /usr/lib/ipxe /usr/lib/x86_64-linux-gnu/qemu /usr/libexec/qemu /usr/local/share/qemu "$@")

work=$(mktemp -d /var/tmp/pvmq-probe.XXXXXX)
trap 'rm -rf "$work"' EXIT
cp -a "$tree" "$work/x86_64"

isolated() {
  unshare --mount --propagation private bash -c '
    set -e
    smoke=$1; tree=$2; shift 2
    for d in "$@"; do
      if [ -d "$d" ]; then mount -t tmpfs -o ro tmpfs "$d"; fi
    done
    exec sh "$smoke" "$tree"
  ' _ "$PVMQ_ROOT/script/smoke-start.sh" "$1" "${hide[@]}"
}

isolated "$work/x86_64"
echo "ok: the copy starts with system QEMU data hidden"

rm "$work/x86_64/share/qemu/bios-256k.bin"
if isolated "$work/x86_64" >/dev/null 2>&1; then
  die "QEMU started without bios-256k.bin in the tree, so it found firmware outside it"
fi
echo "ok: without bios-256k.bin in the tree the start fails, so nothing outside the tree is used"
