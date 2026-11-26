#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# copy-firmware.sh <x86_64|aarch64> <qemu-data-dir> <dest>
#
# Copies the firmware and option ROMs a headless pvm VM of that target can
# load, and the keymaps. QEMU installs blobs for every target; the rest are
# left out. A required file that is missing fails the copy.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

target=${1:?usage: copy-firmware.sh <x86_64|aarch64> <qemu-data-dir> <dest>}
src=${2:?}
dest=${3:?}
[ -d "$src" ] || die "QEMU data directory $src not found"
case "$target" in
  x86_64)
    patterns=("bios*.bin" "kvmvapic.bin" "linuxboot*.bin" "multiboot*.bin" "pvh.bin" "vgabios*.bin"
              "efi-*.rom" "pxe-*.rom" "edk2-x86_64*.fd" "edk2-i386-vars.fd")
    required=(bios-256k.bin kvmvapic.bin efi-virtio.rom vgabios-stdvga.bin)
    ;;
  aarch64)
    patterns=("edk2-aarch64-code.fd" "edk2-arm-vars.fd" "efi-*.rom" "pxe-*.rom")
    required=(edk2-aarch64-code.fd efi-virtio.rom)
    ;;
  *) die "unknown target $target" ;;
esac

mkdir -p "$dest"
shopt -s nullglob
for pat in "${patterns[@]}"; do
  for f in "$src"/$pat; do
    cp -L "$f" "$dest/"
  done
done
[ -d "$src/keymaps" ] && cp -RL "$src/keymaps" "$dest/"
for f in "${required[@]}"; do
  [ -s "$dest/$f" ] || die "required firmware $f is missing from $src"
done
