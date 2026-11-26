#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# apply-patches.sh <patch-dir> <source-dir> [patch...]
#
# Applies each patch in order with no fuzz. Every patch must name the
# upstream commit it comes from in an "Upstream: <40-hex sha>" line: this
# repository carries only changes that are already in QEMU.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

pdir=${1:?usage: apply-patches.sh <patch-dir> <source-dir> [patch...]}
src=${2:?}
shift 2
for p in "$@"; do
  f="$pdir/$p"
  [ -f "$f" ] || die "patch $f is missing"
  grep -Eq '^Upstream: [0-9a-f]{40}$' "$f" || die "$p has no 'Upstream: <commit>' line"
  patch -p1 --forward --fuzz=0 --batch --no-backup-if-mismatch -d "$src" < "$f" || die "$p does not apply cleanly"
  echo "applied $p"
done
