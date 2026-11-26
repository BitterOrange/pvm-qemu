#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# prepare-source.sh <tag> <upstream-dir> <work-dir>
#
# Extracts the verified tarball into <work-dir>/qemu-<version> and applies
# the tag's patches with no fuzz. Prints the source directory.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

tag=${1:?usage: prepare-source.sh <tag> <upstream-dir> <work-dir>}
upstream=${2:?}
work=${3:?}
load_release "$tag"
"$PVMQ_ROOT/script/verify-upstream.sh" --offline "$tag" "$upstream" >&2

mkdir -p "$work"
src="$work/qemu-$QEMU_VERSION"
[ ! -e "$src" ] || die "$src already exists"
tar -xJf "$upstream/qemu-$QEMU_VERSION.tar.xz" -C "$work"
[ -d "$src" ] || die "the tarball did not contain qemu-$QEMU_VERSION/"
"$PVMQ_ROOT/script/apply-patches.sh" "$PVMQ_ROOT/patches/$tag" "$src" $PATCHES >&2
echo "$src"
